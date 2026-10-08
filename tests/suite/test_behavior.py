from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import re
import uuid
from datetime import datetime, timezone

import httpx
import jsonschema

from .conftest import VerifierContext
from .helpers import (
    CONTRACTS_DIR,
    SUBMISSION_DIR,
    boto_client,
    build_random_settlement_spec,
    fetch_oauth_token,
    get_access_token,
    invoke_lambda_sync,
    pg_connect,
    resolve_service_url,
    run_script,
    valkey_connect,
    wait_until,
)


def _run_block(ctx: VerifierContext, block_id: str, fn, cap_on_fail: tuple[str, int] | None = None) -> None:
    try:
        detail = fn()
        ctx.recorder.record(block_id, True, detail or "passed")
    except Exception as err:  # noqa: BLE001
        ctx.recorder.record(block_id, False, str(err))
        if cap_on_fail is not None:
            ctx.recorder.add_cap(cap_on_fail[0], cap_on_fail[1])
        raise


def _ensure_tokens(ctx: VerifierContext, refresh: bool = False) -> dict[str, str]:
    if refresh or not ctx.tokens:
        ctx.tokens = {
            "read": get_access_token(ctx.manifest, "read"),
            "write": get_access_token(ctx.manifest, "write"),
            "admin": get_access_token(ctx.manifest, "admin"),
        }
    return ctx.tokens


def test_settlement_lifecycle_workflow(ctx: VerifierContext) -> None:
    """Scored block: Settlement workflow (9 points) — functional.workflow."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        service_url = resolve_service_url(ctx.manifest["service_url"], ctx.config)
        settlement_count = ctx.rng.randint(8, 10)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            for idx in range(settlement_count):
                step_override = 4 if idx == 0 else (3 if idx == 1 else None)
                spec = build_random_settlement_spec(ctx.rng, step_count=step_override)
                sid = spec["settlementId"]
                corr_id = f"corr-wf-{idx}-{uuid.uuid4().hex[:8]}"

                create_resp = client.post(
                    "/v1/settlements",
                    headers={
                        "Authorization": f"Bearer {tokens['write']}",
                        "Idempotency-Key": f"idem-create-{sid}",
                        "X-Correlation-Id": corr_id,
                    },
                    json={
                        "settlementId": sid,
                        "accountId": spec["accountId"],
                        "reference": spec["reference"],
                        "debitParty": spec["debitParty"],
                        "creditParty": spec["creditParty"],
                        "expectedVersion": 0,
                    },
                )
                assert create_resp.status_code == 201, f"Create failed: {create_resp.status_code} {create_resp.text}"
                cbody = create_resp.json()
                assert cbody["settlementId"] == sid and cbody["version"] == 1
                assert cbody["accepted"] is True and cbody["idempotentReplay"] is False

                for entry in spec["entries"]:
                    entry_resp = client.post(
                        f"/v1/settlements/{sid}/entries",
                        headers={
                            "Authorization": f"Bearer {tokens['write']}",
                            "Idempotency-Key": f"idem-entry-{entry['entryId']}",
                            "X-Correlation-Id": corr_id,
                        },
                        json=entry,
                    )
                    assert entry_resp.status_code == 202, f"Entry failed: {entry_resp.status_code} {entry_resp.text}"
                    ebody = entry_resp.json()
                    assert ebody["version"] == entry["expectedVersion"] + 1 and ebody["accepted"] is True

                expected_version = len(spec["entries"]) + 1
                last_entry = spec["entries"][-1]

                def _projected() -> dict | None:
                    r = client.get(f"/v1/settlements/{sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
                    if r.status_code != 200:
                        return None
                    data = r.json()
                    return data if data.get("version") == expected_version else None

                proj = wait_until(_projected, timeout_sec=35.0, interval_sec=0.8, description=f"projection v{expected_version}")
                assert proj["accountId"] == spec["accountId"] and proj["reference"] == spec["reference"]
                assert proj["debitParty"] == spec["debitParty"] and proj["creditParty"] == spec["creditParty"]
                assert proj["status"] == last_entry["status"] and proj["clearingStage"] == last_entry["clearingStage"]
                assert proj["entryCount"] == len(spec["entries"])

                tl_resp = client.get(f"/v1/settlements/{sid}/ledger", headers={"Authorization": f"Bearer {tokens['read']}"})
                assert tl_resp.status_code == 200
                tl = tl_resp.json()
                assert tl["settlementId"] == sid and tl["version"] == expected_version
                assert [e["version"] for e in tl["events"]] == list(range(1, expected_version + 1))

                ctx.committed_settlements[sid] = {
                    "spec": spec,
                    "expected_version": expected_version,
                    "last_status": last_entry["status"],
                    "last_stage": last_entry["clearingStage"],
                }

            same_party_sid = str(uuid.uuid4())
            bad_party_resp = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-same-party-{same_party_sid}",
                },
                json={
                    "settlementId": same_party_sid,
                    "accountId": "ACCT-DOM-CHECK",
                    "reference": "REF-DOM-CHECK",
                    "debitParty": "BANK-IDENTICAL",
                    "creditParty": "BANK-IDENTICAL",
                    "expectedVersion": 0,
                },
            )
            assert bad_party_resp.status_code == 400, (
                f"Expected 400 Bad Request when debitParty == creditParty, got {bad_party_resp.status_code}: {bad_party_resp.text}"
            )

            settled_sid, settled_meta = next(
                (k, v)
                for k, v in ctx.committed_settlements.items()
                if v["last_status"] in {"SETTLED", "RECONCILED"}
            )
            prior_status = settled_meta["last_status"]
            regress_entry_id = str(uuid.uuid4())
            regress_resp = client.post(
                f"/v1/settlements/{settled_sid}/entries",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-regress-{regress_entry_id}",
                },
                json={
                    "entryId": regress_entry_id,
                    "status": "VALIDATED",
                    "clearingStage": "ILLEGAL_STAGE_REGRESSION",
                    "memo": "Attempt illegal regression from SETTLED/RECONCILED back to VALIDATED",
                    "occurredAt": datetime.now(timezone.utc).isoformat(),
                    "expectedVersion": settled_meta["expected_version"],
                },
            )
            if regress_resp.status_code in {200, 201, 202}:
                settled_meta["expected_version"] += 1
                settled_meta["last_status"] = "VALIDATED"
                settled_meta["last_stage"] = "ILLEGAL_STAGE_REGRESSION"
            assert regress_resp.status_code == 400, (
                f"Expected 400 Bad Request when regressing {prior_status} settlement back to VALIDATED, "
                f"got {regress_resp.status_code}: {regress_resp.text}"
            )

            cleared_sid, cleared_meta = next(
                (k, v)
                for k, v in ctx.committed_settlements.items()
                if v["last_status"] == "CLEARED"
            )
            mid_regress_entry_id = str(uuid.uuid4())
            mid_regress_resp = client.post(
                f"/v1/settlements/{cleared_sid}/entries",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-mid-regress-{mid_regress_entry_id}",
                },
                json={
                    "entryId": mid_regress_entry_id,
                    "status": "RESERVED",
                    "clearingStage": "ILLEGAL_CLEARED_TO_RESERVED",
                    "memo": "Attempt illegal backward regression from CLEARED to RESERVED",
                    "occurredAt": datetime.now(timezone.utc).isoformat(),
                    "expectedVersion": cleared_meta["expected_version"],
                },
            )
            if mid_regress_resp.status_code in {200, 201, 202}:
                cleared_meta["expected_version"] += 1
                cleared_meta["last_status"] = "RESERVED"
                cleared_meta["last_stage"] = "ILLEGAL_CLEARED_TO_RESERVED"
            assert mid_regress_resp.status_code == 400, (
                f"Expected 400 Bad Request when regressing CLEARED settlement back to RESERVED, "
                f"got {mid_regress_resp.status_code}: {mid_regress_resp.text}"
            )

            reused_entry_id = cleared_meta["spec"]["entries"][0]["entryId"]
            dup_entry_resp = client.post(
                f"/v1/settlements/{cleared_sid}/entries",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-dup-entry-{uuid.uuid4()}",
                },
                json={
                    "entryId": reused_entry_id,
                    "status": "SETTLED",
                    "clearingStage": "ILLEGAL_DUPLICATE_ENTRY_ID",
                    "memo": "Attempt duplicate entryId within same settlement",
                    "occurredAt": datetime.now(timezone.utc).isoformat(),
                    "expectedVersion": cleared_meta["expected_version"],
                },
            )
            if dup_entry_resp.status_code in {200, 201, 202}:
                cleared_meta["expected_version"] += 1
                cleared_meta["last_status"] = "SETTLED"
                cleared_meta["last_stage"] = "ILLEGAL_DUPLICATE_ENTRY_ID"
            assert dup_entry_resp.status_code == 400, (
                f"Expected 400 Bad Request when reusing duplicate entryId {reused_entry_id} within settlement {cleared_sid}, "
                f"got {dup_entry_resp.status_code}: {dup_entry_resp.text}"
            )

        return f"Verified {settlement_count} randomized settlement lifecycles, party separation, unique entryId, and ordered stage progression checks"

    _run_block(ctx, "functional.workflow", _check, cap_on_fail=("accepted_write_loss", 49))


def test_projection_and_valkey_cache(ctx: VerifierContext) -> None:
    """Scored block: Projection and cache (7 points) — functional.cache."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        service_url = resolve_service_url(ctx.manifest["service_url"], ctx.config)
        settlement_id, meta = next(iter(ctx.committed_settlements.items()))
        rclient = valkey_connect(ctx.manifest, ctx.config)
        cache_key = f"clearledger:settlement:{settlement_id}"
        settlement_schema = {
            "type": "object",
            "required": [
                "settlementId",
                "accountId",
                "reference",
                "debitParty",
                "creditParty",
                "status",
                "clearingStage",
                "version",
                "entryCount",
                "updatedAt",
            ],
            "properties": {
                "settlementId": {"type": "string", "format": "uuid"},
                "accountId": {"type": "string"},
                "reference": {"type": "string"},
                "debitParty": {"type": "string"},
                "creditParty": {"type": "string"},
                "status": {
                    "type": "string",
                    "enum": [
                        "INITIATED",
                        "VALIDATED",
                        "RESERVED",
                        "CLEARED",
                        "SETTLED",
                        "RECONCILED",
                        "DISPUTED",
                    ],
                },
                "clearingStage": {"type": "string"},
                "lastEntryId": {"type": ["string", "null"], "format": "uuid"},
                "lastMemo": {"type": ["string", "null"]},
                "version": {"type": "integer", "minimum": 1},
                "entryCount": {"type": "integer", "minimum": 0},
                "updatedAt": {"type": "string", "format": "date-time"},
            },
        }
        rclient.delete(cache_key)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r1 = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r1.status_code == 200 and r1.headers.get("X-ClearLedger-Source") == "projection"
            cached_raw = rclient.get(cache_key)
            assert cached_raw is not None
            ttl_val = int(rclient.ttl(cache_key))
            assert 0 < ttl_val <= 90, f"Expected Valkey cache TTL in (0, 90], got {ttl_val}"
            cached_obj = json.loads(cached_raw)
            jsonschema.validate(instance=cached_obj, schema=settlement_schema)
            assert cached_obj == r1.json(), "Cached Valkey projection payload must match GET /v1/settlements/{id} response"

            r2 = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r2.status_code == 200 and r2.headers.get("X-ClearLedger-Source") == "cache"

            next_expected = meta["expected_version"]
            new_entry_id = str(uuid.uuid4())
            e_resp = client.post(
                f"/v1/settlements/{settlement_id}/entries",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-cache-inv-{new_entry_id}",
                },
                json={
                    "entryId": new_entry_id,
                    "status": "RECONCILED",
                    "clearingStage": "CACHE_REFRESH_STAGE",
                    "memo": "Cache invalidation verification",
                    "occurredAt": datetime.now(timezone.utc).isoformat(),
                    "expectedVersion": next_expected,
                },
            )
            assert e_resp.status_code == 202
            target_version = next_expected + 1

            def _fresh() -> bool:
                rclient.delete(cache_key)
                resp = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
                return resp.status_code == 200 and resp.json().get("version") == target_version

            wait_until(_fresh, timeout_sec=30.0, interval_sec=0.8, description="updated projection after cache invalidation")
            meta["spec"]["entries"].append(
                {
                    "entryId": new_entry_id,
                    "status": "RECONCILED",
                    "clearingStage": "CACHE_REFRESH_STAGE",
                    "memo": "Cache invalidation verification",
                    "expectedVersion": next_expected,
                }
            )
            meta["expected_version"] = target_version
            meta["last_status"] = "RECONCILED"
            meta["last_stage"] = "CACHE_REFRESH_STAGE"

        return "Verified projection miss -> Valkey cache populate (TTL & schema) -> cache hit -> write invalidation"

    _run_block(ctx, "functional.cache", _check)


def test_idempotency_and_optimistic_concurrency(ctx: VerifierContext) -> None:
    """Scored block: Idempotency and concurrency (8 points) — functional.idempotency_concurrency."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        service_url = resolve_service_url(ctx.manifest["service_url"], ctx.config)
        spec = build_random_settlement_spec(ctx.rng, step_count=3)
        sid = spec["settlementId"]
        idem_create = f"idem-replay-{sid}"
        replays = ctx.rng.randint(5, 8)

        create_payload = {
            "settlementId": sid,
            "accountId": spec["accountId"],
            "reference": spec["reference"],
            "debitParty": spec["debitParty"],
            "creditParty": spec["creditParty"],
            "expectedVersion": 0,
        }

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            first = client.post(
                "/v1/settlements",
                headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": idem_create},
                json=create_payload,
            )
            assert first.status_code == 201
            first_event_id = first.json()["eventId"]

            for _ in range(replays):
                rep = client.post(
                    "/v1/settlements",
                    headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": idem_create},
                    json=create_payload,
                )
                assert rep.status_code == 200
                rbody = rep.json()
                assert rbody["eventId"] == first_event_id and rbody["idempotentReplay"] is True

            mismatch = client.post(
                "/v1/settlements",
                headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": idem_create},
                json=dict(create_payload, debitParty="MUTATEDBANK"),
            )
            assert mismatch.status_code == 409

            e1 = spec["entries"][0]
            r_e1 = client.post(
                f"/v1/settlements/{sid}/entries",
                headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-e1-{e1['entryId']}"},
                json=e1,
            )
            assert r_e1.status_code == 202 and r_e1.json()["version"] == 2

            r_stale = client.post(
                f"/v1/settlements/{sid}/entries",
                headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-stale-{uuid.uuid4()}"},
                json=dict(spec["entries"][1], expectedVersion=1),
            )
            assert r_stale.status_code == 409

        # Concurrent idempotent replay race on expectedVersion=2 -> v3
        e2 = spec["entries"][1]
        idem_e2 = f"idem-e2-race-{e2['entryId']}"

        def _post_same_idem(_: int) -> tuple[int, dict]:
            with httpx.Client(base_url=service_url, timeout=10.0) as c:
                r = c.post(
                    f"/v1/settlements/{sid}/entries",
                    headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": idem_e2},
                    json=e2,
                )
                return r.status_code, r.json()

        with ThreadPoolExecutor(max_workers=6) as pool:
            idem_results = list(pool.map(_post_same_idem, range(6)))

        assert all(code in {200, 202} for code, _ in idem_results), (
            f"Concurrent idempotent replay returned unexpected status: {idem_results}"
        )
        e2_event_ids = {body["eventId"] for _, body in idem_results}
        assert len(e2_event_ids) == 1, f"Concurrent idempotent requests produced multiple eventIds: {e2_event_ids}"
        assert all(body["version"] == 3 for _, body in idem_results)

        # Concurrent competing writes racing on expectedVersion=3 -> v4
        base_e3 = spec["entries"][2]
        competing_entries = [
            dict(
                base_e3,
                entryId=str(uuid.uuid4()),
                clearingStage=f"CONCURRENT_RACE_{idx}",
                memo=f"Concurrent contender {idx}",
                expectedVersion=3,
            )
            for idx in range(5)
        ]

        def _post_competing(entry_payload: dict) -> tuple[int, dict]:
            with httpx.Client(base_url=service_url, timeout=10.0) as c:
                r = c.post(
                    f"/v1/settlements/{sid}/entries",
                    headers={
                        "Authorization": f"Bearer {tokens['write']}",
                        "Idempotency-Key": f"idem-race-v4-{entry_payload['entryId']}",
                    },
                    json=entry_payload,
                )
                return r.status_code, r.json()

        with ThreadPoolExecutor(max_workers=5) as pool:
            race_results = list(pool.map(_post_competing, competing_entries))

        winners = [(code, body, pay) for (code, body), pay in zip(race_results, competing_entries) if code == 202]
        conflicts = [code for code, _ in race_results if code == 409]
        assert len(winners) == 1 and len(conflicts) == 4, (
            f"Expected exactly 1 winner (202) and 4 conflicts (409) in concurrent version race, got {[c for c, _ in race_results]}"
        )
        winning_entry = winners[0][2]
        assert winners[0][1]["version"] == 4

        with pg_connect(ctx.manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.events WHERE settlement_id = %s", (sid,))
                assert cur.fetchone()[0] == 4

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            def _v4_projected() -> bool:
                r = client.get(f"/v1/settlements/{sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
                return r.status_code == 200 and r.json().get("version") == 4

            wait_until(_v4_projected, timeout_sec=35.0, interval_sec=0.8, description="concurrent winner v4 projected")

        ctx.committed_settlements[sid] = {
            "spec": spec,
            "expected_version": 4,
            "last_status": winning_entry["status"],
            "last_stage": winning_entry["clearingStage"],
        }
        return f"Verified {replays} sequential + 6 concurrent idempotent replays, payload mismatch 409, and 5-way optimistic concurrency race"

    _run_block(ctx, "functional.idempotency_concurrency", _check)


def test_backlog_accumulation_and_drain(ctx: VerifierContext) -> None:
    """Scored block: Backlog recovery (7 points) — async.backlog_recovery."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        lam = boto_client("lambda", ctx.config)
        esm_uuid = m["messaging"]["event_source_mapping_uuid"]
        service_url = resolve_service_url(m["service_url"], ctx.config)

        lam.update_event_source_mapping(UUID=esm_uuid, Enabled=False)
        wait_until(
            lambda: lam.get_event_source_mapping(UUID=esm_uuid).get("State") in {"Disabled", "Disabling"},
            timeout_sec=15.0,
            interval_sec=0.5,
            description="ESM disabled",
        )
        try:
            specs = [build_random_settlement_spec(ctx.rng, step_count=4) for _ in range(5)]
            total_events = 0
            with httpx.Client(base_url=service_url, timeout=10.0) as client:
                for spec in specs:
                    sid = spec["settlementId"]
                    r_create = client.post(
                        "/v1/settlements",
                        headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-bg-create-{sid}"},
                        json={
                            "settlementId": sid,
                            "accountId": spec["accountId"],
                            "reference": spec["reference"],
                            "debitParty": spec["debitParty"],
                            "creditParty": spec["creditParty"],
                            "expectedVersion": 0,
                        },
                    )
                    assert r_create.status_code == 201
                    total_events += 1
                    for entry in spec["entries"]:
                        r_ev = client.post(
                            f"/v1/settlements/{sid}/entries",
                            headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-bg-entry-{entry['entryId']}"},
                            json=entry,
                        )
                        assert r_ev.status_code == 202
                        total_events += 1

                unprojected = client.get(
                    f"/v1/settlements/{specs[-1]['settlementId']}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
                assert unprojected.status_code == 404
        finally:
            lam.update_event_source_mapping(UUID=esm_uuid, Enabled=True)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            for spec in specs:
                sid = spec["settlementId"]
                expected_version = len(spec["entries"]) + 1

                def _drained() -> bool:
                    r = client.get(f"/v1/settlements/{sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
                    return r.status_code == 200 and r.json().get("version") == expected_version

                wait_until(_drained, timeout_sec=60.0, interval_sec=1.0, description=f"backlog drain for {sid}")
                ctx.committed_settlements[sid] = {
                    "spec": spec,
                    "expected_version": expected_version,
                    "last_status": spec["entries"][-1]["status"],
                    "last_stage": spec["entries"][-1]["clearingStage"],
                }

        return f"Queued and drained {total_events} events across {len(specs)} settlements"

    _run_block(ctx, "async.backlog_recovery", _check)


def test_duplicate_delivery_and_dlq_isolation(ctx: VerifierContext) -> None:
    """Scored block: Duplicate, out-of-order, concurrent, and invalid messages (6 points) — async.duplicate_and_dlq."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        sqs = boto_client("sqs", ctx.config)
        ddb = boto_client("dynamodb", ctx.config)
        rclient = valkey_connect(m, ctx.config)
        service_url = resolve_service_url(m["service_url"], ctx.config)
        projector_fn = m["workers"]["projector"]["function_name"]

        settlement_id, meta = next(iter(ctx.committed_settlements.items()))
        with pg_connect(m, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT payload FROM clearledger.events WHERE settlement_id = %s ORDER BY aggregate_version ASC",
                    (settlement_id,),
                )
                rows = cur.fetchall()
                assert len(rows) >= 2
                oldest_envelope = rows[0][0] if isinstance(rows[0][0], str) else json.dumps(rows[0][0])
                latest_envelope = rows[-1][0] if isinstance(rows[-1][0], str) else json.dumps(rows[-1][0])

        # Re-deliver both the latest event (duplicate) and v1 (stale out-of-order event) over SQS
        sqs.send_message(QueueUrl=m["messaging"]["queue_url"], MessageBody=latest_envelope)
        sqs.send_message(QueueUrl=m["messaging"]["queue_url"], MessageBody=oldest_envelope)

        poison_marker = f"poison-{uuid.uuid4()}"
        poison_body = json.dumps({"schemaVersion": "1.0", "poisonMarker": poison_marker, "invalidEnvelope": True})
        sqs.send_message(QueueUrl=m["messaging"]["queue_url"], MessageBody=poison_body)

        spec = build_random_settlement_spec(ctx.rng, step_count=2)
        fresh_id = spec["settlementId"]
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r_c = client.post(
                "/v1/settlements",
                headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-dlq-create-{fresh_id}"},
                json={
                    "settlementId": fresh_id,
                    "accountId": spec["accountId"],
                    "reference": spec["reference"],
                    "debitParty": spec["debitParty"],
                    "creditParty": spec["creditParty"],
                    "expectedVersion": 0,
                },
            )
            assert r_c.status_code == 201
            for entry in spec["entries"]:
                r_e = client.post(
                    f"/v1/settlements/{fresh_id}/entries",
                    headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-dlq-entry-{entry['entryId']}"},
                    json=entry,
                )
                assert r_e.status_code == 202

            def _fresh_projected() -> bool:
                r = client.get(f"/v1/settlements/{fresh_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
                return r.status_code == 200 and r.json().get("version") == 3

            wait_until(_fresh_projected, timeout_sec=40.0, interval_sec=1.0, description="valid messages projected")

            # Verify duplicate + stale v1 SQS delivery did not regress settlement_id
            rclient.delete(f"clearledger:settlement:{settlement_id}")
            r_dup = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_dup.status_code == 200
            dup_body = r_dup.json()
            assert dup_body["version"] == meta["expected_version"], (
                f"Stale SQS delivery regressed version from {meta['expected_version']} to {dup_body['version']}"
            )
            assert dup_body["status"] == meta["last_status"] and dup_body["clearingStage"] == meta["last_stage"]

            # Deterministic out-of-order (v3 -> v1 -> v2) and concurrent projector race on fresh_id
            with pg_connect(m, ctx.config) as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT payload FROM clearledger.events WHERE settlement_id = %s ORDER BY aggregate_version ASC",
                        (fresh_id,),
                    )
                    fresh_rows = cur.fetchall()
                    assert len(fresh_rows) == 3
                    env_v1, env_v2, env_v3 = [
                        r[0] if isinstance(r[0], str) else json.dumps(r[0]) for r in fresh_rows
                    ]

            pk = f"SETTLEMENT#{fresh_id}"
            existing_items = ddb.query(
                TableName=m["projections"]["table_name"],
                KeyConditionExpression="PK = :pk",
                ExpressionAttributeValues={":pk": {"S": pk}},
            ).get("Items", [])
            for item in existing_items:
                ddb.delete_item(
                    TableName=m["projections"]["table_name"],
                    Key={"PK": item["PK"], "SK": item["SK"]},
                )
            rclient.delete(f"clearledger:settlement:{fresh_id}")

            # 1) Deliver v3 first, then v1, then v2 out of order
            for step_label, raw_env in (("v3", env_v3), ("v1", env_v1), ("v2", env_v2)):
                res = invoke_lambda_sync(
                    projector_fn,
                    {"Records": [{"messageId": f"ooo-{step_label}-{uuid.uuid4()}", "body": raw_env}]},
                )
                assert not res.get("batchItemFailures"), f"Out-of-order step {step_label} failed: {res}"

            rclient.delete(f"clearledger:settlement:{fresh_id}")
            r_ooo = client.get(f"/v1/settlements/{fresh_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_ooo.status_code == 200
            ooo_proj = r_ooo.json()
            assert ooo_proj["version"] == 3, f"Out-of-order v1/v2 overwrote v3 projection: {ooo_proj}"
            assert ooo_proj["status"] == spec["entries"][-1]["status"]
            assert ooo_proj["clearingStage"] == spec["entries"][-1]["clearingStage"]
            assert ooo_proj["entryCount"] == 2
            assert ooo_proj["accountId"] == spec["accountId"] and ooo_proj["reference"] == spec["reference"]
            assert ooo_proj["debitParty"] == spec["debitParty"] and ooo_proj["creditParty"] == spec["creditParty"]

            # 2) Concurrent projector Lambda invocations racing scrambled event batches
            scrambled_batches = [
                [env_v3, env_v1],
                [env_v2, env_v1],
                [env_v1, env_v2, env_v3],
                [env_v1],
                [env_v2],
                [env_v3, env_v2, env_v1],
            ]

            def _invoke_batch(batch: list[str]) -> dict:
                records = [{"messageId": f"race-{uuid.uuid4()}", "body": b} for b in batch]
                return invoke_lambda_sync(projector_fn, {"Records": records})

            with ThreadPoolExecutor(max_workers=6) as pool:
                batch_results = list(pool.map(_invoke_batch, scrambled_batches))
            assert all(not br.get("batchItemFailures") for br in batch_results), (
                f"Concurrent projector race had batch failures: {batch_results}"
            )

            rclient.delete(f"clearledger:settlement:{fresh_id}")
            r_race = client.get(f"/v1/settlements/{fresh_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_race.status_code == 200
            race_proj = r_race.json()
            assert race_proj["version"] == 3, f"Concurrent projector race regressed version: {race_proj}"
            assert race_proj["status"] == spec["entries"][-1]["status"]
            assert race_proj["clearingStage"] == spec["entries"][-1]["clearingStage"]

            r_tl = client.get(f"/v1/settlements/{fresh_id}/ledger", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_tl.status_code == 200
            assert [e["version"] for e in r_tl.json()["events"]] == [1, 2, 3]

        def _poison_in_dlq() -> bool:
            resp = sqs.receive_message(
                QueueUrl=m["messaging"]["dlq_url"],
                MaxNumberOfMessages=10,
                VisibilityTimeout=1,
                WaitTimeSeconds=1,
            )
            return any(poison_marker in msg.get("Body", "") for msg in resp.get("Messages", []))

        wait_until(_poison_in_dlq, timeout_sec=75.0, interval_sec=1.5, description="poison message redriven to DLQ")
        ctx.committed_settlements[fresh_id] = {
            "spec": spec,
            "expected_version": 3,
            "last_status": spec["entries"][-1]["status"],
            "last_stage": spec["entries"][-1]["clearingStage"],
        }
        return "Verified duplicate, out-of-order (v3->v1->v2), and concurrent SQS projection safety plus DLQ isolation"

    _run_block(ctx, "async.duplicate_and_dlq", _check)



def test_outbox_recovery_after_sqs_queue_deletion(ctx: VerifierContext) -> None:
    """Scored block: Outbox recovery (6 points) — recovery.outbox_recovery."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx, refresh=True)
        m = ctx.manifest
        sqs = boto_client("sqs", ctx.config)
        lam = boto_client("lambda", ctx.config)
        ddb = boto_client("dynamodb", ctx.config)
        s3 = boto_client("s3", ctx.config)
        rclient = valkey_connect(m, ctx.config)
        service_url = resolve_service_url(m["service_url"], ctx.config)

        invoke_lambda_sync(m["workers"]["outbox_relay"]["function_name"])
        invoke_lambda_sync(m["workers"]["audit_archiver"]["function_name"])

        # Simulate bidirectional projection/cache/archive corruption on already-published settlements:
        # 1) Inflated-version STATE corruption on corrupted_sid (version=99 blocks naive projector #version < :new_version)
        # 2) Missing EVENT#00000001 + in-place mutated EVENT#00000002 + phantom EVENT#00000099 on ledger_corrupted_sid
        #    (keeps total EVENT#* count equal to expected_version so count-only checks fail)
        # 3) Same-version / same-SK attribute + AccountIndex GSI + Valkey corruption on same_ver_sid
        #    (keeps STATE.version == expected_version and EVENT#00000001..N intact so version-only / SK-only checks fail)
        # 4) Orphan settlement partition in DynamoDB, Valkey, and S3 ledger-audit/ absent from PostgreSQL
        committed_items = list(ctx.committed_settlements.items())
        corrupted_sid, corrupted_meta = committed_items[0]
        ledger_corrupted_sid, ledger_corrupted_meta = committed_items[1]
        same_ver_sid, same_ver_meta = committed_items[2]
        cache_drift_sid, cache_drift_meta = committed_items[3]
        orphan_sid = str(uuid.uuid4())
        now_iso = datetime.now(timezone.utc).isoformat()

        ddb.put_item(
            TableName=m["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{corrupted_sid}"},
                "SK": {"S": "STATE"},
                "GSI1PK": {"S": f"ACCOUNT#{corrupted_meta['spec']['accountId']}"},
                "GSI1SK": {"S": f"UPDATED#{now_iso}#SETTLEMENT#{corrupted_sid}"},
                "settlement_id": {"S": corrupted_sid},
                "account_id": {"S": corrupted_meta["spec"]["accountId"]},
                "reference": {"S": corrupted_meta["spec"]["reference"]},
                "debit_party": {"S": corrupted_meta["spec"]["debitParty"]},
                "credit_party": {"S": corrupted_meta["spec"]["creditParty"]},
                "status": {"S": "DISPUTED"},
                "clearing_stage": {"S": "CORRUPTED_INFLATED_STATE"},
                "version": {"N": "99"},
                "entry_count": {"N": "98"},
                "updated_at": {"S": now_iso},
            },
        )
        ddb.delete_item(
            TableName=m["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{ledger_corrupted_sid}"}, "SK": {"S": "EVENT#00000001"}},
        )
        ddb.update_item(
            TableName=m["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{ledger_corrupted_sid}"}, "SK": {"S": "EVENT#00000002"}},
            UpdateExpression="SET clearing_stage = :cs, #st = :st",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={
                ":cs": {"S": "CORRUPTED_EVENT_STAGE"},
                ":st": {"S": "DISPUTED"},
            },
        )
        ddb.put_item(
            TableName=m["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{ledger_corrupted_sid}"},
                "SK": {"S": "EVENT#00000099"},
                "event_id": {"S": str(uuid.uuid4())},
                "settlement_id": {"S": ledger_corrupted_sid},
                "version": {"N": "99"},
                "event_type": {"S": "LedgerEntryRecorded"},
                "status": {"S": "DISPUTED"},
                "clearing_stage": {"S": "PHANTOM_EVENT_99"},
                "correlation_id": {"S": "corr-phantom-99"},
                "occurred_at": {"S": now_iso},
            },
        )
        ddb.update_item(
            TableName=m["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "STATE"}},
            UpdateExpression="SET last_memo = :lm, last_entry_id = :leid, updated_at = :ua, GSI1PK = :gpk, GSI1SK = :gsk",
            ExpressionAttributeValues={
                ":lm": {"S": "SILENT_SAME_VER_LAST_MEMO_DRIFT"},
                ":leid": {"S": "00000000-0000-0000-0000-000000000000"},
                ":ua": {"S": "1999-01-01T00:00:00Z"},
                ":gpk": {"S": "ACCOUNT#SILENT-DRIFT-GSI"},
                ":gsk": {"S": f"CORRUPTED#{same_ver_sid}"},
            },
        )
        ddb.update_item(
            TableName=m["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "EVENT#00000001"}},
            UpdateExpression="SET occurred_at = :oa, correlation_id = :cid, envelope = :env",
            ExpressionAttributeValues={
                ":oa": {"S": "1999-01-01T00:00:00Z"},
                ":cid": {"S": "corr-silent-drift-0001"},
                ":env": {"S": '{"corruptedEnvelope":true}'},
            },
        )
        ddb.update_item(
            TableName=m["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "EVENT#00000002"}},
            UpdateExpression="SET memo = :m, entry_id = :eid",
            ExpressionAttributeValues={
                ":m": {"S": "SILENT_SAME_VER_EVENT_MEMO_DRIFT"},
                ":eid": {"S": "00000000-0000-0000-0000-000000000000"},
            },
        )
        ddb.put_item(
            TableName=m["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{same_ver_sid}"},
                "SK": {"S": "META#STRAY"},
                "settlement_id": {"S": same_ver_sid},
                "note": {"S": "stray non-STATE/non-EVENT item in partition"},
            },
        )
        ddb.put_item(
            TableName=m["projections"]["table_name"],
            Item={
                "PK": {"S": "AUDIT#STRAY-PARTITION"},
                "SK": {"S": "META#01"},
                "note": {"S": "stray non-SETTLEMENT partition item"},
            },
        )
        ddb.put_item(
            TableName=m["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{orphan_sid}"},
                "SK": {"S": "STATE"},
                "GSI1PK": {"S": "ACCOUNT#ACCT-ORPHAN"},
                "GSI1SK": {"S": f"UPDATED#{now_iso}#SETTLEMENT#{orphan_sid}"},
                "settlement_id": {"S": orphan_sid},
                "account_id": {"S": "ACCT-ORPHAN"},
                "reference": {"S": "REF-ORPHAN"},
                "debit_party": {"S": "BANK-ORPHAN-A"},
                "credit_party": {"S": "BANK-ORPHAN-B"},
                "status": {"S": "INITIATED"},
                "clearing_stage": {"S": "ORPHAN_STATE"},
                "version": {"N": "1"},
                "entry_count": {"N": "0"},
                "updated_at": {"S": now_iso},
            },
        )
        ddb.put_item(
            TableName=m["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{orphan_sid}"},
                "SK": {"S": "EVENT#00000001"},
                "event_id": {"S": str(uuid.uuid4())},
                "settlement_id": {"S": orphan_sid},
                "version": {"N": "1"},
                "event_type": {"S": "SettlementInitiated"},
                "status": {"S": "INITIATED"},
                "clearing_stage": {"S": "ORPHAN_STATE"},
                "correlation_id": {"S": "corr-orphan"},
                "occurred_at": {"S": now_iso},
            },
        )
        rclient.set(
            f"clearledger:settlement:{corrupted_sid}",
            json.dumps(
                {
                    "settlementId": corrupted_sid,
                    "accountId": corrupted_meta["spec"]["accountId"],
                    "reference": corrupted_meta["spec"]["reference"],
                    "debitParty": corrupted_meta["spec"]["debitParty"],
                    "creditParty": corrupted_meta["spec"]["creditParty"],
                    "status": "DISPUTED",
                    "clearingStage": "STALE_POISONED_CACHE",
                    "version": 99,
                    "entryCount": 98,
                    "updatedAt": now_iso,
                }
            ),
        )
        rclient.set(
            f"clearledger:settlement:{cache_drift_sid}",
            json.dumps(
                {
                    "settlementId": cache_drift_sid,
                    "accountId": cache_drift_meta["spec"]["accountId"],
                    "reference": cache_drift_meta["spec"]["reference"],
                    "debitParty": cache_drift_meta["spec"]["debitParty"],
                    "creditParty": cache_drift_meta["spec"]["creditParty"],
                    "status": cache_drift_meta["last_status"],
                    "clearingStage": cache_drift_meta["last_stage"],
                    "lastEntryId": "00000000-0000-0000-0000-000000000000",
                    "lastMemo": "SILENT_CACHE_ONLY_MEMO_POISON",
                    "version": cache_drift_meta["expected_version"],
                    "entryCount": cache_drift_meta["expected_version"] - 1,
                    "updatedAt": "1999-01-01T00:00:00Z",
                }
            ),
            ex=80,
        )
        rclient.set(
            f"clearledger:settlement:{orphan_sid}",
            json.dumps(
                {
                    "settlementId": orphan_sid,
                    "accountId": "ACCT-ORPHAN",
                    "reference": "REF-ORPHAN",
                    "debitParty": "BANK-ORPHAN-A",
                    "creditParty": "BANK-ORPHAN-B",
                    "status": "INITIATED",
                    "clearingStage": "ORPHAN_CACHE",
                    "version": 1,
                    "entryCount": 0,
                    "updatedAt": now_iso,
                }
            ),
        )
        rclient.set("clearledger:lock:stray-marker", "poison-non-settlement-key")

        # Corrupt S3 audit archive inside ledger-audit/:
        # 1) Drop one archived event completely from S3 while keeping its remaining peer records in a valid-digest batch
        #    (so object-only S3 validation passes unless deploy.sh cross-checks every archived_at IS NOT NULL row against S3)
        # 2) Write an overlapping valid-digest single-event batch so valid_subset[0] is duplicated across two valid-digest S3 keys
        # 3) Write a reversed-sequence valid-digest batch (valid sha256 & min/max seq bounds, but descending line order)
        # 4) Write a forged-digest batch key and a tampered payload batch
        # 5) Write an orphan batch key
        existing_s3 = s3.list_objects_v2(Bucket=m["audit"]["bucket_name"], Prefix=m["audit"]["prefix"]).get("Contents", [])
        if existing_s3:
            target_key = existing_s3[0]["Key"]
            orig_lines = [
                ln
                for ln in s3.get_object(Bucket=m["audit"]["bucket_name"], Key=target_key)["Body"].read().decode().splitlines()
                if ln.strip()
            ]
            if len(orig_lines) >= 4:
                with pg_connect(m, ctx.config) as conn:
                    with conn.cursor() as cur:
                        cur.execute("SELECT event_id::text, seq FROM clearledger.outbox")
                        eid_to_seq = {r[0]: int(r[1]) for r in cur.fetchall()}
                # Drop the last line completely from S3 (while archived_at remains NOT NULL in PostgreSQL)
                _dropped_line = orig_lines.pop()
                forged_line = orig_lines.pop()
                valid_subset = orig_lines[:2]
                tampered_subset = orig_lines[2:]
                valid_raw = ("\n".join(valid_subset) + "\n").encode("utf-8")
                valid_s1 = eid_to_seq[json.loads(valid_subset[0])["eventId"]]
                valid_s2 = eid_to_seq[json.loads(valid_subset[-1])["eventId"]]
                valid_dig = hashlib.sha256(valid_raw).hexdigest()[:16]
                dup_raw = (valid_subset[0] + "\n").encode("utf-8")
                dup_dig = hashlib.sha256(dup_raw).hexdigest()[:16]
                rev_raw = ("\n".join(reversed(valid_subset)) + "\n").encode("utf-8")
                rev_dig = hashlib.sha256(rev_raw).hexdigest()[:16]
                s3.delete_object(Bucket=m["audit"]["bucket_name"], Key=target_key)
                s3.put_object(
                    Bucket=m["audit"]["bucket_name"],
                    Key=f"{m['audit']['prefix']}batch-{valid_s1:08d}-{valid_s2:08d}-{valid_dig}.ndjson",
                    Body=valid_raw,
                    ContentType="application/x-ndjson",
                )
                s3.put_object(
                    Bucket=m["audit"]["bucket_name"],
                    Key=f"{m['audit']['prefix']}batch-{valid_s1:08d}-{valid_s1:08d}-{dup_dig}.ndjson",
                    Body=dup_raw,
                    ContentType="application/x-ndjson",
                )
                s3.put_object(
                    Bucket=m["audit"]["bucket_name"],
                    Key=f"{m['audit']['prefix']}batch-{valid_s1:08d}-{valid_s2:08d}-{rev_dig}.ndjson",
                    Body=rev_raw,
                    ContentType="application/x-ndjson",
                )
                first_rec = json.loads(tampered_subset[0])
                first_rec.setdefault("data", {})["clearingStage"] = "TAMPERED_S3_AUDIT_STAGE"
                tampered_subset[0] = json.dumps(first_rec)
                s3.put_object(
                    Bucket=m["audit"]["bucket_name"],
                    Key=target_key,
                    Body=("\n".join(tampered_subset) + "\n").encode("utf-8"),
                    ContentType="application/x-ndjson",
                )
                s3.put_object(
                    Bucket=m["audit"]["bucket_name"],
                    Key=f"{m['audit']['prefix']}batch-00000001-00000001-0000000000000000.ndjson",
                    Body=(forged_line + "\n").encode("utf-8"),
                    ContentType="application/x-ndjson",
                )

        orphan_s3_env = {
            "schemaVersion": "1.0",
            "eventId": str(uuid.uuid4()),
            "eventType": "SettlementInitiated",
            "aggregateType": "settlement",
            "aggregateId": orphan_sid,
            "aggregateVersion": 1,
            "occurredAt": now_iso,
            "correlationId": "corr-orphan-s3",
            "idempotencyKey": "idem-orphan-s3-batch",
            "data": {
                "kind": "settlementInitiated",
                "accountId": "ACCT-ORPHAN",
                "reference": "REF-ORPHAN",
                "debitParty": "BANK-ORPHAN-A",
                "creditParty": "BANK-ORPHAN-B",
                "entryId": None,
                "status": "INITIATED",
                "clearingStage": "ORPHAN_S3_BATCH",
                "memo": None,
            },
        }
        s3.put_object(
            Bucket=m["audit"]["bucket_name"],
            Key=f"{m['audit']['prefix']}batch-99999901-99999901-orphan.ndjson",
            Body=(json.dumps(orphan_s3_env) + "\n").encode("utf-8"),
            ContentType="application/x-ndjson",
        )

        try:
            proj_cfg = lam.get_function_configuration(FunctionName=m["workers"]["projector"]["function_name"])
            drifted_proj_env = dict((proj_cfg.get("Environment") or {}).get("Variables") or {})
            drifted_proj_env["PROJECTION_TABLE"] = "drifted-missing-projection-table"
            lam.update_function_configuration(
                FunctionName=m["workers"]["projector"]["function_name"],
                Environment={"Variables": drifted_proj_env},
            )
            arch_cfg = lam.get_function_configuration(FunctionName=m["workers"]["audit_archiver"]["function_name"])
            drifted_arch_env = dict((arch_cfg.get("Environment") or {}).get("Variables") or {})
            drifted_arch_env["AUDIT_BUCKET"] = "drifted-missing-audit-bucket"
            lam.update_function_configuration(
                FunctionName=m["workers"]["audit_archiver"]["function_name"],
                Environment={"Variables": drifted_arch_env},
            )
        except Exception:  # noqa: BLE001
            pass

        try:
            scheduler = boto_client("scheduler", ctx.config)
            scheduler.delete_schedule(Name=m["schedules"]["outbox_schedule_name"])
        except Exception:  # noqa: BLE001
            pass

        try:
            lam.delete_event_source_mapping(UUID=m["messaging"]["event_source_mapping_uuid"])
        except Exception:  # noqa: BLE001
            pass
        sqs.delete_queue(QueueUrl=m["messaging"]["queue_url"])
        try:
            sqs.delete_queue(QueueUrl=m["messaging"]["dlq_url"])
        except Exception:  # noqa: BLE001
            pass

        spec = build_random_settlement_spec(ctx.rng, step_count=2)
        sid = spec["settlementId"]
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r_c = client.post(
                "/v1/settlements",
                headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-outage-create-{sid}"},
                json={
                    "settlementId": sid,
                    "accountId": spec["accountId"],
                    "reference": spec["reference"],
                    "debitParty": spec["debitParty"],
                    "creditParty": spec["creditParty"],
                    "expectedVersion": 0,
                },
            )
            assert r_c.status_code == 201

            for entry in spec["entries"]:
                r_e = client.post(
                    f"/v1/settlements/{sid}/entries",
                    headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-outage-entry-{entry['entryId']}"},
                    json=entry,
                )
                assert r_e.status_code == 202

            with pg_connect(m, ctx.config) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE settlement_id = %s AND published_at IS NULL", (sid,))
                    assert cur.fetchone()[0] == 3

            r_get = client.get(f"/v1/settlements/{sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_get.status_code == 404

        redeploy = run_script(SUBMISSION_DIR / "deploy.sh", timeout_sec=720)
        assert redeploy.returncode == 0, f"deploy.sh failed to restore deleted SQS queue: {redeploy.stderr[-800:]}"
        m = ctx.refresh_manifest()
        tokens = _ensure_tokens(ctx, refresh=True)
        service_url = resolve_service_url(m["service_url"], ctx.config)
        rclient = valkey_connect(m, ctx.config)

        esm = lam.get_event_source_mapping(UUID=m["messaging"]["event_source_mapping_uuid"])
        assert esm["EventSourceArn"] == m["messaging"]["queue_arn"]
        assert esm["State"] in {"Enabled", "Enabling", "Updating"}

        with pg_connect(m, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE published_at IS NULL")
                unpub = cur.fetchone()[0]
                assert unpub == 0, (
                    f"deploy.sh exited before draining unpublished outbox rows ({unpub} rows still have published_at IS NULL)"
                )
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE archived_at IS NULL")
                unarch = cur.fetchone()[0]
                assert unarch == 0, (
                    f"deploy.sh exited before archiving outbox rows ({unarch} rows still have archived_at IS NULL)"
                )
                cur.execute("SELECT seq, event_id::text, payload FROM clearledger.outbox")
                pg_outbox_map = {
                    ev_id: (int(seq), (json.loads(pay) if isinstance(pay, str) else pay))
                    for seq, ev_id, pay in cur.fetchall()
                }
                cur.execute(
                    "SELECT correlation_id, payload FROM clearledger.events WHERE settlement_id = %s AND aggregate_version = 1",
                    (same_ver_sid,),
                )
                sv_ev1_corr, sv_ev1_pay_raw = cur.fetchone()
                sv_ev1_pay = json.loads(sv_ev1_pay_raw) if isinstance(sv_ev1_pay_raw, str) else sv_ev1_pay_raw

        # Verify 1-to-1 S3 audit archive integrity, canonical key format, SHA-256 digest, and seq order against clearledger.outbox
        s3_records_by_eid: dict[str, dict] = {}
        total_s3_lines = 0
        key_pattern = re.compile(rf"^{re.escape(str(m['audit']['prefix']))}batch-(\d{{8}})-(\d{{8}})-([0-9a-f]{{16}})\.ndjson$")
        for obj in s3.list_objects_v2(Bucket=m["audit"]["bucket_name"]).get("Contents", []):
            key = obj["Key"]
            key_match = key_pattern.match(key)
            assert key_match is not None, (
                f"Expected S3 audit batch key {key} to match canonical format batch-<first_seq:08d>-<last_seq:08d>-<16_char_sha256_hex>.ndjson"
            )
            first_seq_str, last_seq_str, key_digest = key_match.groups()
            raw_bytes = s3.get_object(Bucket=m["audit"]["bucket_name"], Key=key)["Body"].read()
            actual_digest = hashlib.sha256(raw_bytes).hexdigest()[:16]
            assert actual_digest == key_digest, (
                f"Expected deploy.sh to purge/re-archive S3 batch {key} with mismatched SHA-256 digest (expected {actual_digest})"
            )
            body = raw_bytes.decode()
            batch_seqs: list[int] = []
            for line in body.splitlines():
                if line.strip():
                    total_s3_lines += 1
                    rec = json.loads(line)
                    ev_id = str(rec.get("eventId") or "")
                    assert ev_id in pg_outbox_map, (
                        f"Expected deploy.sh to purge orphan S3 audit record {ev_id} (aggregateId={rec.get('aggregateId')}) under {m['audit']['prefix']}"
                    )
                    assert ev_id not in s3_records_by_eid, (
                        f"Duplicate S3 audit record found for eventId {ev_id} under {m['audit']['prefix']}"
                    )
                    row_seq, auth_pay = pg_outbox_map[ev_id]
                    assert rec == auth_pay, (
                        f"Expected deploy.sh to heal tampered S3 audit record for eventId {ev_id}: got {rec.get('data')}, expected {auth_pay.get('data')}"
                    )
                    s3_records_by_eid[ev_id] = rec
                    batch_seqs.append(row_seq)
            assert batch_seqs == sorted(batch_seqs), (
                f"Expected S3 audit batch {key} records to be ordered by ascending clearledger.outbox.seq, got {batch_seqs}"
            )
            assert batch_seqs[0] == int(first_seq_str) and batch_seqs[-1] == int(last_seq_str), (
                f"Expected S3 audit batch {key} sequence bounds ({first_seq_str}..{last_seq_str}) to match outbox.seq range ({batch_seqs[0]}..{batch_seqs[-1]})"
            )
        assert total_s3_lines == len(pg_outbox_map) and set(s3_records_by_eid.keys()) == set(pg_outbox_map.keys()), (
            f"Expected S3 audit archive under {m['audit']['prefix']} to match clearledger.outbox 1-to-1 "
            f"(pg={len(pg_outbox_map)}, s3={total_s3_lines})"
        )

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            def _recovered() -> bool:
                r = client.get(f"/v1/settlements/{sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
                return r.status_code == 200 and r.json().get("version") == 3

            wait_until(_recovered, timeout_sec=25.0, interval_sec=1.0, description="outbox recovery projection v3")

            r_sid_ledger = client.get(f"/v1/settlements/{sid}/ledger", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_sid_ledger.status_code == 200
            assert [e["version"] for e in r_sid_ledger.json().get("events", [])] == [1, 2, 3]

            r_healed = client.get(f"/v1/settlements/{corrupted_sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_healed.status_code == 200, (
                f"Expected deploy.sh to reconcile corrupted DynamoDB STATE projection for {corrupted_sid}, got {r_healed.status_code}"
            )
            healed_body = r_healed.json()
            assert healed_body.get("version") == corrupted_meta["expected_version"], (
                f"deploy.sh did not reconcile inflated-version STATE projection/cache for {corrupted_sid}: "
                f"expected version {corrupted_meta['expected_version']}, got {healed_body}"
            )
            assert healed_body.get("status") == corrupted_meta["last_status"]
            assert healed_body.get("clearingStage") == corrupted_meta["last_stage"]

            r_ledger_healed = client.get(
                f"/v1/settlements/{ledger_corrupted_sid}/ledger",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r_ledger_healed.status_code == 200, (
                f"Expected deploy.sh to reconcile DynamoDB EVENT#* items for {ledger_corrupted_sid}, got {r_ledger_healed.status_code}"
            )
            ledger_events = r_ledger_healed.json().get("events", [])
            assert [e["version"] for e in ledger_events] == list(range(1, ledger_corrupted_meta["expected_version"] + 1)), (
                f"deploy.sh did not reconcile missing EVENT#00000001 and purge phantom EVENT#00000099 for {ledger_corrupted_sid}: "
                f"got versions {[e['version'] for e in ledger_events]}"
            )
            expected_v2_stage = ledger_corrupted_meta["spec"]["entries"][0]["clearingStage"]
            assert ledger_events[1].get("clearingStage") == expected_v2_stage, (
                f"deploy.sh did not repair in-place mutated EVENT#00000002 for {ledger_corrupted_sid}: "
                f"expected clearingStage {expected_v2_stage}, got {ledger_events[1]}"
            )

            r_same_ver = client.get(f"/v1/settlements/{same_ver_sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_same_ver.status_code == 200
            sv_body = r_same_ver.json()
            expected_sv_last_entry = same_ver_meta["spec"]["entries"][-1]
            assert (
                sv_body.get("status") == same_ver_meta["last_status"]
                and sv_body.get("clearingStage") == same_ver_meta["last_stage"]
                and sv_body.get("lastEntryId") == expected_sv_last_entry["entryId"]
                and sv_body.get("lastMemo") == expected_sv_last_entry["memo"]
                and not str(sv_body.get("updatedAt", "")).startswith("1999-")
            ), (
                f"deploy.sh did not reconcile same-version corrupted STATE (lastEntryId/lastMemo/updatedAt) for {same_ver_sid}: got {sv_body}"
            )
            r_sv_ledger = client.get(f"/v1/settlements/{same_ver_sid}/ledger", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_sv_ledger.status_code == 200
            sv_events = r_sv_ledger.json().get("events", [])
            expected_sv_v2 = same_ver_meta["spec"]["entries"][0]
            assert (
                len(sv_events) >= 2
                and not str(sv_events[0].get("occurredAt", "")).startswith("1999-")
                and sv_events[1].get("entryId") == expected_sv_v2["entryId"]
                and sv_events[1].get("memo") == expected_sv_v2["memo"]
            ), (
                f"deploy.sh did not reconcile same-version mutated EVENT#00000001..2 (occurredAt/entryId/memo) for {same_ver_sid}: got {sv_events[:2]}"
            )
            sv_ev1_ddb = ddb.get_item(
                TableName=m["projections"]["table_name"],
                Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "EVENT#00000001"}},
                ConsistentRead=True,
            ).get("Item") or {}
            assert (sv_ev1_ddb.get("correlation_id") or {}).get("S") == sv_ev1_corr, (
                f"Expected deploy.sh to heal EVENT#00000001 correlation_id on {same_ver_sid}"
            )
            assert json.loads((sv_ev1_ddb.get("envelope") or {}).get("S", "{}")) == sv_ev1_pay, (
                f"Expected deploy.sh to heal EVENT#00000001 envelope JSON on {same_ver_sid}"
            )
            stray_item = ddb.get_item(
                TableName=m["projections"]["table_name"],
                Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "META#STRAY"}},
                ConsistentRead=True,
            ).get("Item")
            assert stray_item is None, (
                f"Expected deploy.sh to purge stray non-STATE/non-EVENT item SK=META#STRAY under SETTLEMENT#{same_ver_sid}"
            )
            stray_part = ddb.get_item(
                TableName=m["projections"]["table_name"],
                Key={"PK": {"S": "AUDIT#STRAY-PARTITION"}, "SK": {"S": "META#01"}},
                ConsistentRead=True,
            ).get("Item")
            assert stray_part is None, (
                "Expected deploy.sh to purge stray non-SETTLEMENT partition item PK=AUDIT#STRAY-PARTITION"
            )
            assert rclient.get("clearledger:lock:stray-marker") is None, (
                "Expected deploy.sh to purge stray Valkey key clearledger:lock:stray-marker"
            )

            gsi_q = ddb.query(
                TableName=m["projections"]["table_name"],
                IndexName=m["projections"]["gsi_name"],
                KeyConditionExpression="GSI1PK = :gpk AND GSI1SK = :gsk",
                ExpressionAttributeValues={
                    ":gpk": {"S": f"ACCOUNT#{same_ver_meta['spec']['accountId']}"},
                    ":gsk": {"S": f"SETTLEMENT#{same_ver_sid}"},
                },
            ).get("Items", [])
            assert len(gsi_q) == 1, (
                f"Expected deploy.sh to heal AccountIndex GSI attributes (GSI1PK/GSI1SK) for {same_ver_sid}, found {gsi_q}"
            )

            r_cache_drift = client.get(
                f"/v1/settlements/{cache_drift_sid}",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r_cache_drift.status_code == 200
            cd_body = r_cache_drift.json()
            expected_cd_last_entry = cache_drift_meta["spec"]["entries"][-1]
            assert (
                cd_body.get("lastEntryId") == expected_cd_last_entry["entryId"]
                and cd_body.get("lastMemo") == expected_cd_last_entry["memo"]
                and not str(cd_body.get("updatedAt", "")).startswith("1999-")
            ), (
                f"Expected deploy.sh to evict/reconcile Valkey cache entry with poisoned lastEntryId/lastMemo/updatedAt for {cache_drift_sid}, got {cd_body}"
            )

            r_orphan_state = client.get(f"/v1/settlements/{orphan_sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_orphan_state.status_code == 404, (
                f"Expected deploy.sh to purge orphan DynamoDB/Valkey settlement {orphan_sid} absent from PostgreSQL, got {r_orphan_state.status_code}"
            )
            r_orphan_ledger = client.get(f"/v1/settlements/{orphan_sid}/ledger", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_orphan_ledger.status_code == 404, (
                f"Expected deploy.sh to purge orphan DynamoDB EVENT#* items for {orphan_sid}, got {r_orphan_ledger.status_code}"
            )
            assert rclient.get(f"clearledger:settlement:{orphan_sid}") is None, (
                f"Expected deploy.sh to purge orphan Valkey key clearledger:settlement:{orphan_sid}"
            )

        ctx.committed_settlements[sid] = {
            "spec": spec,
            "expected_version": 3,
            "last_status": spec["entries"][-1]["status"],
            "last_stage": spec["entries"][-1]["clearingStage"],
        }
        return "Accepted writes during SQS queue outage and verified full deploy.sh outbox/projection/GSI/cache/S3 1-to-1 reconciliation"

    _run_block(ctx, "recovery.outbox_recovery", _check, cap_on_fail=("accepted_write_loss", 49))


def test_projection_rebuild_from_event_log(ctx: VerifierContext) -> None:
    """Scored block: Projection rebuild (5 points) — recovery.projection_rebuild."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx, refresh=True)
        m = ctx.manifest
        ddb = boto_client("dynamodb", ctx.config)
        rclient = valkey_connect(m, ctx.config)
        service_url = resolve_service_url(m["service_url"], ctx.config)

        settlement_id, meta = next(iter(ctx.committed_settlements.items()))
        expected_version = meta["expected_version"]
        pk = f"SETTLEMENT#{settlement_id}"

        q = ddb.query(
            TableName=m["projections"]["table_name"],
            KeyConditionExpression="PK = :pk",
            ExpressionAttributeValues={":pk": {"S": pk}},
        )
        for item in q.get("Items", []):
            ddb.delete_item(TableName=m["projections"]["table_name"], Key={"PK": item["PK"], "SK": item["SK"]})
        rclient.delete(f"clearledger:settlement:{settlement_id}")

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r_missing = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_missing.status_code == 404

            r_rebuild = client.post(
                f"/v1/admin/projections/{settlement_id}/rebuild",
                headers={"Authorization": f"Bearer {tokens['admin']}", "X-Correlation-Id": f"corr-rebuild-{uuid.uuid4().hex[:8]}"},
            )
            assert r_rebuild.status_code == 202 and r_rebuild.json()["requeued"] == expected_version

            def _rebuilt() -> bool:
                r = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
                return r.status_code == 200 and r.json().get("version") == expected_version

            wait_until(_rebuilt, timeout_sec=40.0, interval_sec=1.0, description="rebuilt projection in DynamoDB")

            r_tl = client.get(f"/v1/settlements/{settlement_id}/ledger", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_tl.status_code == 200 and r_tl.json()["version"] == expected_version

        return f"Rebuilt corrupted DynamoDB projection for settlement {settlement_id} (v{expected_version})"

    _run_block(ctx, "recovery.projection_rebuild", _check)


def test_ecs_task_failure_replacement(ctx: VerifierContext) -> None:
    """Scored block: ECS task replacement (5 points) — recovery.ecs_task_replacement."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx, refresh=True)
        m = ctx.manifest
        ecs = boto_client("ecs", ctx.config)
        service_url = resolve_service_url(m["service_url"], ctx.config)

        def _two_tasks_running() -> list[str] | None:
            arns = ecs.list_tasks(
                cluster=m["compute"]["cluster_name"],
                serviceName=m["compute"]["service_name"],
                desiredStatus="RUNNING",
            ).get("taskArns", [])
            return arns if len(arns) >= 2 else None

        before_tasks = wait_until(
            _two_tasks_running,
            timeout_sec=45.0,
            interval_sec=1.5,
            description=">=2 running ECS tasks before stop_task drill",
        )
        ecs.stop_task(cluster=m["compute"]["cluster_name"], task=before_tasks[0], reason="Verifier fault drill")

        settlement_id = next(iter(ctx.committed_settlements.keys()))
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            wait_until(
                lambda: client.get("/health/ready").status_code == 200,
                timeout_sec=30.0,
                interval_sec=0.5,
                description="API health ready during ECS task replacement",
            )
            wait_until(
                lambda: client.get(
                    f"/v1/settlements/{settlement_id}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                ).status_code == 200,
                timeout_sec=30.0,
                interval_sec=0.5,
                description="API settlement read during ECS task replacement",
            )

        def _replacement_running() -> bool:
            current = ecs.list_tasks(
                cluster=m["compute"]["cluster_name"],
                serviceName=m["compute"]["service_name"],
                desiredStatus="RUNNING",
            )["taskArns"]
            return len(current) >= 2

        wait_until(_replacement_running, timeout_sec=60.0, interval_sec=1.5, description="ECS replacement task RUNNING")
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            wait_until(
                lambda: all(client.get("/health/ready").status_code == 200 for _ in range(2)),
                timeout_sec=30.0,
                interval_sec=1.0,
                description="all ECS tasks healthy behind ALB after replacement",
            )
        return "Stopped running ECS task and verified uninterrupted service + task replacement"

    _run_block(ctx, "recovery.ecs_task_replacement", _check)


def test_rds_reboot_recovery(ctx: VerifierContext) -> None:
    """Scored block: RDS reboot recovery (4 points) — recovery.rds_reboot."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx, refresh=True)
        m = ctx.manifest
        rds = boto_client("rds", ctx.config)
        service_url = resolve_service_url(m["service_url"], ctx.config)

        raw_db_id = m["database"]["instance_id"]
        arn_db_id = m["database"]["instance_arn"].rsplit(":", 1)[-1]
        all_dbs = rds.describe_db_instances().get("DBInstances", [])
        db_id = next(
            (
                d["DBInstanceIdentifier"]
                for d in all_dbs
                if d.get("DBInstanceIdentifier") in {raw_db_id, arn_db_id}
                or d.get("DbiResourceId") == raw_db_id
                or d.get("DBInstanceArn") == m["database"]["instance_arn"]
            ),
            arn_db_id or raw_db_id,
        )
        rds.reboot_db_instance(DBInstanceIdentifier=db_id)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            def _db_ready() -> bool:
                for _ in range(2):
                    r = client.get("/health/ready")
                    if r.status_code != 200 or r.json().get("checks", {}).get("postgres") != "UP":
                        return False
                return True

            wait_until(_db_ready, timeout_sec=60.0, interval_sec=1.5, description="RDS ready after reboot")

            with pg_connect(m, ctx.config) as conn:
                with conn.cursor() as cur:
                    for sid, meta in ctx.committed_settlements.items():
                        cur.execute("SELECT version FROM clearledger.settlements WHERE settlement_id = %s", (sid,))
                        row = cur.fetchone()
                        assert row is not None and row[0] == meta["expected_version"]

            spec = build_random_settlement_spec(ctx.rng, step_count=1)
            new_sid = spec["settlementId"]
            r_c = client.post(
                "/v1/settlements",
                headers={"Authorization": f"Bearer {tokens['write']}", "Idempotency-Key": f"idem-post-reboot-{new_sid}"},
                json={
                    "settlementId": new_sid,
                    "accountId": spec["accountId"],
                    "reference": spec["reference"],
                    "debitParty": spec["debitParty"],
                    "creditParty": spec["creditParty"],
                    "expectedVersion": 0,
                },
            )
            assert r_c.status_code == 201

            def _post_reboot_projected() -> bool:
                r = client.get(
                    f"/v1/settlements/{new_sid}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
                return r.status_code == 200 and r.json().get("version") == 1

            wait_until(
                _post_reboot_projected,
                timeout_sec=35.0,
                interval_sec=1.0,
                description="post-reboot settlement projection",
            )
            ctx.committed_settlements[new_sid] = {
                "spec": spec,
                "expected_version": 1,
                "last_status": "INITIATED",
                "last_stage": f"INITIATED@{spec['debitParty']}",
            }

        return f"RDS reboot preserved all {len(ctx.committed_settlements)} committed settlements"

    _run_block(ctx, "recovery.rds_reboot", _check, cap_on_fail=("accepted_write_loss", 49))


def test_authorization_audit_and_observability(ctx: VerifierContext) -> None:
    """Scored block: Authorization, audit and logs (3 points) — security.auth_audit_logs."""
    def _check() -> str:
        m = ctx.manifest
        service_url = resolve_service_url(m["service_url"], ctx.config)
        read_tok = get_access_token(m, "read")
        write_tok = get_access_token(m, "write")
        admin_tok = get_access_token(m, "admin")
        settlement_id = next(iter(ctx.committed_settlements.keys()))

        bad_status, bad_body = fetch_oauth_token(
            m,
            "read",
            secret_override="wrong-secret-value",
            client_id_override="invalid-nonexistent-client-id",
        )
        if bad_status == 200 and "access_token" in bad_body:
            with httpx.Client(base_url=service_url, timeout=10.0) as client:
                r_bad = client.get(
                    f"/v1/settlements/{settlement_id}",
                    headers={"Authorization": f"Bearer {bad_body['access_token']}"},
                )
                assert r_bad.status_code in {401, 403}
        else:
            assert bad_status in {400, 401, 403}

        wrong_scope_status, wrong_scope_body = fetch_oauth_token(m, "read", scope_override="clearledger/admin")
        if wrong_scope_status == 200 and "access_token" in wrong_scope_body:
            with httpx.Client(base_url=service_url, timeout=10.0) as client:
                probe = client.post(
                    f"/v1/admin/projections/{settlement_id}/rebuild",
                    headers={"Authorization": f"Bearer {wrong_scope_body['access_token']}"},
                )
                if probe.status_code < 400:
                    ctx.recorder.add_cap("auth_escalation", 49)
                    raise AssertionError("Read client obtained token accepted on admin endpoint")

        corr_marker = f"corr-sec-{uuid.uuid4().hex[:10]}"

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            if client.get(f"/v1/settlements/{settlement_id}").status_code != 401:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError("Unauthenticated GET must return 401")
            if client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": "Bearer forged.invalid.token"}).status_code != 401:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError("Forged token must return 401")

            sample_post = {
                "settlementId": str(uuid.uuid4()),
                "accountId": "acct-9999",
                "reference": "CLR-999999",
                "debitParty": "CITIUS33",
                "creditParty": "CHASUS33",
                "expectedVersion": 0,
            }
            checks = [
                client.post("/v1/settlements", headers={"Authorization": f"Bearer {read_tok}", "Idempotency-Key": f"idem-f1-{uuid.uuid4()}"}, json=sample_post).status_code,
                client.post(f"/v1/admin/projections/{settlement_id}/rebuild", headers={"Authorization": f"Bearer {read_tok}"}).status_code,
                client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {write_tok}"}).status_code,
                client.post(f"/v1/admin/projections/{settlement_id}/rebuild", headers={"Authorization": f"Bearer {write_tok}"}).status_code,
                client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {admin_tok}"}).status_code,
                client.post("/v1/settlements", headers={"Authorization": f"Bearer {admin_tok}", "Idempotency-Key": f"idem-f2-{uuid.uuid4()}"}, json=dict(sample_post, settlementId=str(uuid.uuid4()))).status_code,
            ]
            if any(code != 403 for code in checks):
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Scope isolation matrix violated: {checks}")

            audit_sid = str(uuid.uuid4())
            r_audit_create = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {write_tok}",
                    "Idempotency-Key": f"idem-audit-{audit_sid}",
                    "X-Correlation-Id": corr_marker,
                },
                json={
                    "settlementId": audit_sid,
                    "accountId": "acct-7777",
                    "reference": "CLR-777777",
                    "debitParty": "CITIUS33",
                    "creditParty": "CHASUS33",
                    "expectedVersion": 0,
                },
            )
            assert r_audit_create.status_code == 201
            ctx.committed_settlements[audit_sid] = {
                "spec": {"settlementId": audit_sid},
                "expected_version": 1,
                "last_status": "INITIATED",
                "last_stage": "INITIATED@CITIUS33",
            }

        invoke_lambda_sync(m["workers"]["outbox_relay"]["function_name"])
        invoke_lambda_sync(m["workers"]["audit_archiver"]["function_name"])

        s3 = boto_client("s3", ctx.config)
        event_schema = json.loads((CONTRACTS_DIR / "schemas" / "events.schema.json").read_text())

        objects = wait_until(
            lambda: s3.list_objects_v2(Bucket=m["audit"]["bucket_name"], Prefix=m["audit"]["prefix"]).get("Contents", []),
            timeout_sec=30.0,
            interval_sec=1.0,
            description="S3 audit archive objects",
        )
        validated_records = 0
        for obj in objects:
            body = s3.get_object(Bucket=m["audit"]["bucket_name"], Key=obj["Key"])["Body"].read().decode()
            for line in body.splitlines():
                if line.strip():
                    jsonschema.validate(instance=json.loads(line), schema=event_schema)
                    validated_records += 1
        assert validated_records >= 10

        with pg_connect(m, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE archived_at IS NOT NULL")
                assert cur.fetchone()[0] >= 10

        logs = boto_client("logs", ctx.config)
        secrets_to_scrub = [
            ctx.config["db_password"],
            m["auth"]["clients"]["read"]["client_secret"],
            m["auth"]["clients"]["write"]["client_secret"],
            m["auth"]["clients"]["admin"]["client_secret"],
        ]

        def _fetch_group_messages(lg_name: str) -> list[str]:
            msgs: list[str] = []
            next_token: str | None = None
            for _ in range(10):
                kwargs: dict = {"logGroupName": lg_name, "limit": 1000}
                if next_token:
                    kwargs["nextToken"] = next_token
                resp = logs.filter_log_events(**kwargs)
                for ev in resp.get("events", []):
                    msgs.append(ev.get("message", ""))
                next_token = resp.get("nextToken")
                if not next_token:
                    break
            streams = logs.describe_log_streams(logGroupName=lg_name).get("logStreams", [])
            for st in streams:
                sname = st.get("logStreamName")
                if sname:
                    st_events = logs.get_log_events(
                        logGroupName=lg_name,
                        logStreamName=sname,
                        startFromHead=False,
                        limit=500,
                    ).get("events", [])
                    for ev in st_events:
                        msgs.append(ev.get("message", ""))
            return msgs

        def _verify_logs_and_corr() -> bool:
            found_corr = False
            for lg_key, lg_name in m["logs"].items():
                messages = _fetch_group_messages(lg_name)
                assert messages, f"Expected structured log events in {lg_name} ({lg_key})"
                for msg in messages:
                    for secret in secrets_to_scrub:
                        if secret and len(secret) >= 4 and secret in msg:
                            ctx.recorder.add_cap("auth_escalation", 49)
                            raise AssertionError(f"Secret value leaked in CloudWatch log group {lg_name}")
                    if corr_marker in msg:
                        found_corr = True
            return found_corr

        wait_until(
            _verify_logs_and_corr,
            timeout_sec=15.0,
            interval_sec=1.0,
            description=f"Correlation ID {corr_marker} in CloudWatch logs",
        )

        return f"Verified strict scope isolation, {validated_records} S3 audit records, and secret-free structured logs"

    _run_block(ctx, "security.auth_audit_logs", _check)

