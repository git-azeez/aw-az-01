from __future__ import annotations

import json
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
                spec = build_random_settlement_spec(ctx.rng)
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

        return f"Verified {settlement_count} randomized settlement lifecycles end-to-end"

    _run_block(ctx, "functional.workflow", _check, cap_on_fail=("accepted_write_loss", 49))


def test_projection_and_valkey_cache(ctx: VerifierContext) -> None:
    """Scored block: Projection and cache (7 points) — functional.cache."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        service_url = resolve_service_url(ctx.manifest["service_url"], ctx.config)
        settlement_id, meta = next(iter(ctx.committed_settlements.items()))
        rclient = valkey_connect(ctx.manifest, ctx.config)
        cache_key = f"clearledger:settlement:{settlement_id}"
        rclient.delete(cache_key)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r1 = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r1.status_code == 200 and r1.headers.get("X-ClearLedger-Source") == "projection"
            assert rclient.get(cache_key) is not None

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
            meta["expected_version"] = target_version
            meta["last_status"] = "RECONCILED"
            meta["last_stage"] = "CACHE_REFRESH_STAGE"

        return "Verified projection miss -> Valkey cache populate -> cache hit -> write invalidation"

    _run_block(ctx, "functional.cache", _check)


def test_idempotency_and_optimistic_concurrency(ctx: VerifierContext) -> None:
    """Scored block: Idempotency and concurrency (8 points) — functional.idempotency_concurrency."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        service_url = resolve_service_url(ctx.manifest["service_url"], ctx.config)
        spec = build_random_settlement_spec(ctx.rng, step_count=2)
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

        with pg_connect(ctx.manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.events WHERE settlement_id = %s", (sid,))
                assert cur.fetchone()[0] == 2

        ctx.committed_settlements[sid] = {
            "spec": spec,
            "expected_version": 2,
            "last_status": e1["status"],
            "last_stage": e1["clearingStage"],
        }
        return f"Verified {replays} idempotent replays, payload mismatch 409, and stale version 409"

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
    """Scored block: Duplicate and invalid messages (6 points) — async.duplicate_and_dlq."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        sqs = boto_client("sqs", ctx.config)
        service_url = resolve_service_url(m["service_url"], ctx.config)

        settlement_id, meta = next(iter(ctx.committed_settlements.items()))
        with pg_connect(m, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT payload FROM clearledger.events WHERE settlement_id = %s ORDER BY aggregate_version DESC LIMIT 1",
                    (settlement_id,),
                )
                row = cur.fetchone()
                assert row is not None
                latest_envelope = row[0] if isinstance(row[0], str) else json.dumps(row[0])

        sqs.send_message(QueueUrl=m["messaging"]["queue_url"], MessageBody=latest_envelope)

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

            r_dup = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_dup.status_code == 200 and r_dup.json()["version"] == meta["expected_version"]

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
        return "Duplicate SQS event ignored idempotently and poison message isolated to DLQ"

    _run_block(ctx, "async.duplicate_and_dlq", _check)


def test_outbox_recovery_after_sqs_queue_deletion(ctx: VerifierContext) -> None:
    """Scored block: Outbox recovery (6 points) — recovery.outbox_recovery."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx, refresh=True)
        m = ctx.manifest
        sqs = boto_client("sqs", ctx.config)
        service_url = resolve_service_url(m["service_url"], ctx.config)

        sqs.delete_queue(QueueUrl=m["messaging"]["queue_url"])

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

        relay_res = invoke_lambda_sync(m["workers"]["outbox_relay"]["function_name"])
        assert int(relay_res.get("published", 0)) >= 3 or relay_res.get("failed", 0) == 0

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            def _recovered() -> bool:
                invoke_lambda_sync(m["workers"]["outbox_relay"]["function_name"])
                r = client.get(f"/v1/settlements/{sid}", headers={"Authorization": f"Bearer {tokens['read']}"})
                return r.status_code == 200 and r.json().get("version") == 3

            wait_until(_recovered, timeout_sec=45.0, interval_sec=1.2, description="outbox recovery projection v3")

        ctx.committed_settlements[sid] = {
            "spec": spec,
            "expected_version": 3,
            "last_status": spec["entries"][-1]["status"],
            "last_stage": spec["entries"][-1]["clearingStage"],
        }
        return "Accepted writes during SQS queue outage and recovered via deploy.sh + outbox relay"

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

        before_tasks = ecs.list_tasks(
            cluster=m["compute"]["cluster_name"],
            serviceName=m["compute"]["service_name"],
            desiredStatus="RUNNING",
        )["taskArns"]
        assert len(before_tasks) >= 2
        ecs.stop_task(cluster=m["compute"]["cluster_name"], task=before_tasks[0], reason="Verifier fault drill")

        settlement_id = next(iter(ctx.committed_settlements.keys()))
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            wait_until(lambda: client.get("/health/ready").status_code == 200, timeout_sec=30.0, interval_sec=1.0)
            r_read = client.get(f"/v1/settlements/{settlement_id}", headers={"Authorization": f"Bearer {tokens['read']}"})
            assert r_read.status_code == 200

        def _replacement_running() -> bool:
            current = ecs.list_tasks(
                cluster=m["compute"]["cluster_name"],
                serviceName=m["compute"]["service_name"],
                desiredStatus="RUNNING",
            )["taskArns"]
            return len(current) >= 2

        wait_until(_replacement_running, timeout_sec=60.0, interval_sec=1.5, description="ECS replacement task RUNNING")
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
                r = client.get("/health/ready")
                return r.status_code == 200 and r.json().get("checks", {}).get("postgres") == "UP"

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

            wait_until(
                lambda: client.get(
                    f"/v1/settlements/{new_sid}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                ).json().get("version") == 1,
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
        found_corr = False
        for lg_key, lg_name in m["logs"].items():
            events = logs.filter_log_events(logGroupName=lg_name, limit=100).get("events", [])
            assert events, f"Expected structured log events in {lg_name} ({lg_key})"
            for ev in events:
                msg = ev.get("message", "")
                for secret in secrets_to_scrub:
                    if secret and len(secret) >= 4 and secret in msg:
                        ctx.recorder.add_cap("auth_escalation", 49)
                        raise AssertionError(f"Secret value leaked in CloudWatch log group {lg_name}")
                if corr_marker in msg:
                    found_corr = True
        assert found_corr, f"Correlation ID {corr_marker} not found in CloudWatch logs"

        return f"Verified strict scope isolation, {validated_records} S3 audit records, and secret-free structured logs"

    _run_block(ctx, "security.auth_audit_logs", _check)
