from __future__ import annotations

import uuid

import httpx

from .conftest import VerifierContext
from .helpers import (
    SUBMISSION_DIR,
    boto_client,
    build_random_settlement_spec,
    get_access_token,
    invoke_lambda_sync,
    pg_connect,
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


def _ensure_tokens(ctx: VerifierContext) -> dict[str, str]:
    ctx.tokens = {
        "read": get_access_token(ctx.manifest, "read"),
        "write": get_access_token(ctx.manifest, "write"),
        "admin": get_access_token(ctx.manifest, "admin"),
    }
    return ctx.tokens


def test_outbox_recovery_after_sqs_queue_deletion(ctx: VerifierContext) -> None:
    """Scored block: Outbox recovery (6 points) — recovery.outbox_recovery."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        sqs = boto_client("sqs", ctx.config)
        service_url = m["service_url"].rstrip("/")

        sqs.delete_queue(QueueUrl=m["messaging"]["queue_url"])

        spec = build_random_settlement_spec(ctx.rng, step_count=2)
        sid = spec["settlementId"]
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r_c = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-outage-create-{sid}",
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
            assert r_c.status_code == 201, f"Write should succeed via outbox even when SQS queue is deleted: {r_c.text}"

            for entry in spec["entries"]:
                r_e = client.post(
                    f"/v1/settlements/{sid}/entries",
                    headers={
                        "Authorization": f"Bearer {tokens['write']}",
                        "Idempotency-Key": f"idem-outage-entry-{entry['entryId']}",
                    },
                    json=entry,
                )
                assert r_e.status_code == 202

            with pg_connect(m, ctx.config) as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT COUNT(*) FROM clearledger.outbox WHERE settlement_id = %s AND published_at IS NULL",
                        (sid,),
                    )
                    unpub = cur.fetchone()[0]
                    assert unpub == 3, f"Expected 3 unpublished outbox rows during SQS outage, found {unpub}"

            r_get = client.get(
                f"/v1/settlements/{sid}",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r_get.status_code == 404

        redeploy = run_script(SUBMISSION_DIR / "deploy.sh", timeout_sec=720)
        assert redeploy.returncode == 0, f"deploy.sh failed to restore deleted SQS queue: {redeploy.stderr[-800:]}"
        m = ctx.refresh_manifest()
        tokens = _ensure_tokens(ctx)
        service_url = m["service_url"].rstrip("/")

        relay_res = invoke_lambda_sync(m["workers"]["outbox_relay"]["function_name"])
        assert int(relay_res.get("published", 0)) >= 3 or relay_res.get("failed", 0) == 0

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            def _recovered() -> bool:
                invoke_lambda_sync(m["workers"]["outbox_relay"]["function_name"])
                r = client.get(
                    f"/v1/settlements/{sid}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
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
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        ddb = boto_client("dynamodb", ctx.config)
        rclient = valkey_connect(m)
        service_url = m["service_url"].rstrip("/")

        settlement_id, meta = next(iter(ctx.committed_settlements.items()))
        expected_version = meta["expected_version"]
        pk = f"SETTLEMENT#{settlement_id}"

        q = ddb.query(
            TableName=m["projections"]["table_name"],
            KeyConditionExpression="PK = :pk",
            ExpressionAttributeValues={":pk": {"S": pk}},
        )
        for item in q.get("Items", []):
            ddb.delete_item(
                TableName=m["projections"]["table_name"],
                Key={"PK": item["PK"], "SK": item["SK"]},
            )
        rclient.delete(f"clearledger:settlement:{settlement_id}")

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r_missing = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r_missing.status_code == 404

            r_rebuild = client.post(
                f"/v1/admin/projections/{settlement_id}/rebuild",
                headers={
                    "Authorization": f"Bearer {tokens['admin']}",
                    "X-Correlation-Id": f"corr-rebuild-{uuid.uuid4().hex[:8]}",
                },
            )
            assert r_rebuild.status_code == 202
            assert r_rebuild.json()["requeued"] == expected_version

            def _rebuilt() -> bool:
                r = client.get(
                    f"/v1/settlements/{settlement_id}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
                return r.status_code == 200 and r.json().get("version") == expected_version

            wait_until(_rebuilt, timeout_sec=40.0, interval_sec=1.0, description="rebuilt projection in DynamoDB")

            r_tl = client.get(
                f"/v1/settlements/{settlement_id}/ledger",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r_tl.status_code == 200
            assert r_tl.json()["version"] == expected_version

        return f"Rebuilt corrupted DynamoDB projection for settlement {settlement_id} (v{expected_version})"

    _run_block(ctx, "recovery.projection_rebuild", _check)


def test_ecs_task_failure_replacement(ctx: VerifierContext) -> None:
    """Scored block: ECS task replacement (5 points) — recovery.ecs_task_replacement."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        ecs = boto_client("ecs", ctx.config)
        service_url = m["service_url"].rstrip("/")

        before_tasks = ecs.list_tasks(
            cluster=m["compute"]["cluster_name"],
            serviceName=m["compute"]["service_name"],
            desiredStatus="RUNNING",
        )["taskArns"]
        assert len(before_tasks) >= 2
        victim = before_tasks[0]

        ecs.stop_task(
            cluster=m["compute"]["cluster_name"],
            task=victim,
            reason="Verifier fault drill",
        )

        settlement_id = next(iter(ctx.committed_settlements.keys()))
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            def _service_available() -> bool:
                r = client.get("/health/ready")
                return r.status_code == 200

            wait_until(_service_available, timeout_sec=30.0, interval_sec=1.0, description="API readiness during ECS task replacement")

            r_read = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
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
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        rds = boto_client("rds", ctx.config)
        service_url = m["service_url"].rstrip("/")

        rds.reboot_db_instance(DBInstanceIdentifier=m["database"]["instance_id"])

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            def _db_ready() -> bool:
                r = client.get("/health/ready")
                return r.status_code == 200 and r.json().get("checks", {}).get("postgres") == "UP"

            wait_until(_db_ready, timeout_sec=60.0, interval_sec=1.5, description="RDS ready after reboot")

            with pg_connect(m, ctx.config) as conn:
                with conn.cursor() as cur:
                    for sid, meta in ctx.committed_settlements.items():
                        cur.execute(
                            "SELECT version FROM clearledger.settlements WHERE settlement_id = %s",
                            (sid,),
                        )
                        row = cur.fetchone()
                        assert row is not None and row[0] == meta["expected_version"], (
                            f"Settlement {sid} lost or corrupted after RDS reboot"
                        )

            spec = build_random_settlement_spec(ctx.rng, step_count=1)
            new_sid = spec["settlementId"]
            r_c = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-post-reboot-{new_sid}",
                },
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

            wait_until(_post_reboot_projected, timeout_sec=35.0, interval_sec=1.0, description="post-reboot settlement projection")
            ctx.committed_settlements[new_sid] = {
                "spec": spec,
                "expected_version": 1,
                "last_status": "INITIATED",
                "last_stage": f"INITIATED@{spec['debitParty']}",
            }

        return f"RDS reboot preserved all {len(ctx.committed_settlements)} committed settlements"

    _run_block(ctx, "recovery.rds_reboot", _check, cap_on_fail=("accepted_write_loss", 49))
