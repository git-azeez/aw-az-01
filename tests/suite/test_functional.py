from __future__ import annotations

import uuid
from datetime import datetime, timezone

import httpx

from .conftest import VerifierContext
from .helpers import (
    build_random_settlement_spec,
    get_access_token,
    pg_connect,
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


def _ensure_tokens(ctx: VerifierContext) -> dict[str, str]:
    if not ctx.tokens:
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
        service_url = ctx.manifest["service_url"].rstrip("/")
        settlement_count = ctx.rng.randint(8, 10)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            for idx in range(settlement_count):
                spec = build_random_settlement_spec(ctx.rng)
                settlement_id = spec["settlementId"]
                corr_id = f"corr-wf-{idx}-{uuid.uuid4().hex[:8]}"

                create_resp = client.post(
                    "/v1/settlements",
                    headers={
                        "Authorization": f"Bearer {tokens['write']}",
                        "Idempotency-Key": f"idem-create-{settlement_id}",
                        "X-Correlation-Id": corr_id,
                    },
                    json={
                        "settlementId": settlement_id,
                        "accountId": spec["accountId"],
                        "reference": spec["reference"],
                        "debitParty": spec["debitParty"],
                        "creditParty": spec["creditParty"],
                        "expectedVersion": 0,
                    },
                )
                assert create_resp.status_code == 201, f"Create failed: {create_resp.status_code} {create_resp.text}"
                cbody = create_resp.json()
                assert cbody["settlementId"] == settlement_id
                assert cbody["version"] == 1
                assert cbody["accepted"] is True
                assert cbody["idempotentReplay"] is False

                for entry in spec["entries"]:
                    entry_resp = client.post(
                        f"/v1/settlements/{settlement_id}/entries",
                        headers={
                            "Authorization": f"Bearer {tokens['write']}",
                            "Idempotency-Key": f"idem-entry-{entry['entryId']}",
                            "X-Correlation-Id": corr_id,
                        },
                        json=entry,
                    )
                    assert entry_resp.status_code == 202, f"Entry failed: {entry_resp.status_code} {entry_resp.text}"
                    ebody = entry_resp.json()
                    assert ebody["version"] == entry["expectedVersion"] + 1
                    assert ebody["accepted"] is True

                expected_version = len(spec["entries"]) + 1
                last_entry = spec["entries"][-1]

                def _projected() -> dict | None:
                    r = client.get(
                        f"/v1/settlements/{settlement_id}",
                        headers={"Authorization": f"Bearer {tokens['read']}"},
                    )
                    if r.status_code != 200:
                        return None
                    data = r.json()
                    return data if data.get("version") == expected_version else None

                proj = wait_until(
                    _projected,
                    timeout_sec=35.0,
                    interval_sec=0.8,
                    description=f"settlement {settlement_id} projection v{expected_version}",
                )
                assert proj["accountId"] == spec["accountId"]
                assert proj["reference"] == spec["reference"]
                assert proj["debitParty"] == spec["debitParty"]
                assert proj["creditParty"] == spec["creditParty"]
                assert proj["status"] == last_entry["status"]
                assert proj["clearingStage"] == last_entry["clearingStage"]
                assert proj["entryCount"] == len(spec["entries"])

                tl_resp = client.get(
                    f"/v1/settlements/{settlement_id}/ledger",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
                assert tl_resp.status_code == 200
                tl = tl_resp.json()
                assert tl["settlementId"] == settlement_id
                assert tl["version"] == expected_version
                versions = [e["version"] for e in tl["events"]]
                assert versions == list(range(1, expected_version + 1))

                ctx.committed_settlements[settlement_id] = {
                    "spec": spec,
                    "expected_version": expected_version,
                    "last_status": last_entry["status"],
                    "last_stage": last_entry["clearingStage"],
                }

        return f"Verified {settlement_count} randomized settlement lifecycles end-to-end"

    _run_block(ctx, "functional.workflow", _check, cap_on_fail=("accepted_write_loss", 49))


def test_projection_and_valkey_cache(ctx: VerifierContext) -> None:
    """Scored block: Projection and cache (7 points) — functional.cache."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        service_url = ctx.manifest["service_url"].rstrip("/")
        settlement_id, meta = next(iter(ctx.committed_settlements.items()))
        rclient = valkey_connect(ctx.manifest)
        cache_key = f"clearledger:settlement:{settlement_id}"
        rclient.delete(cache_key)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r1 = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r1.status_code == 200
            assert r1.headers.get("X-ClearLedger-Source") == "projection"
            assert rclient.get(cache_key) is not None

            r2 = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r2.status_code == 200
            assert r2.headers.get("X-ClearLedger-Source") == "cache"

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
                resp = client.get(
                    f"/v1/settlements/{settlement_id}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
                return resp.status_code == 200 and resp.json().get("version") == target_version

            wait_until(_fresh, timeout_sec=30.0, interval_sec=0.8, description="updated projection after cache invalidation")
            meta["expected_version"] = target_version
            meta["last_status"] = "RECONCILED"
            meta["last_stage"] = "CACHE_REFRESH_STAGE"

        return "Verified projection miss -> Valkey cache populate -> cache hit -> write invalidation"

    _run_block(ctx, "functional.cache", _check)


def test_idempotency_and_optimistic_concurrency(ctx: VerifierContext) -> None:
    """Scored block: Idempotency and concurrency (8 points) — functional.idempotency_concurrency."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        service_url = ctx.manifest["service_url"].rstrip("/")
        spec = build_random_settlement_spec(ctx.rng, step_count=2)
        settlement_id = spec["settlementId"]
        idem_create = f"idem-replay-{settlement_id}"
        replays = ctx.rng.randint(5, 8)

        create_payload = {
            "settlementId": settlement_id,
            "accountId": spec["accountId"],
            "reference": spec["reference"],
            "debitParty": spec["debitParty"],
            "creditParty": spec["creditParty"],
            "expectedVersion": 0,
        }

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            first = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": idem_create,
                },
                json=create_payload,
            )
            assert first.status_code == 201
            first_event_id = first.json()["eventId"]

            for _ in range(replays):
                rep = client.post(
                    "/v1/settlements",
                    headers={
                        "Authorization": f"Bearer {tokens['write']}",
                        "Idempotency-Key": idem_create,
                    },
                    json=create_payload,
                )
                assert rep.status_code == 200
                rbody = rep.json()
                assert rbody["eventId"] == first_event_id
                assert rbody["idempotentReplay"] is True

            mutated_payload = dict(create_payload, debitParty="MUTATEDBANK")
            mismatch = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": idem_create,
                },
                json=mutated_payload,
            )
            assert mismatch.status_code == 409

            e1 = spec["entries"][0]
            r_e1 = client.post(
                f"/v1/settlements/{settlement_id}/entries",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-e1-{e1['entryId']}",
                },
                json=e1,
            )
            assert r_e1.status_code == 202
            assert r_e1.json()["version"] == 2

            stale_entry = dict(spec["entries"][1], expectedVersion=1)
            r_stale = client.post(
                f"/v1/settlements/{settlement_id}/entries",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-stale-{uuid.uuid4()}",
                },
                json=stale_entry,
            )
            assert r_stale.status_code == 409

        with pg_connect(ctx.manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COUNT(*) FROM clearledger.events WHERE settlement_id = %s",
                    (settlement_id,),
                )
                count = cur.fetchone()[0]
                assert count == 2, f"Expected exactly 2 committed events, found {count}"

        ctx.committed_settlements[settlement_id] = {
            "spec": spec,
            "expected_version": 2,
            "last_status": e1["status"],
            "last_stage": e1["clearingStage"],
        }
        return f"Verified {replays} idempotent replays, payload mismatch 409, and stale version 409"

    _run_block(ctx, "functional.idempotency_concurrency", _check)
