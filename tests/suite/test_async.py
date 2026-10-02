from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone

import httpx

from .conftest import VerifierContext
from .helpers import (
    boto_client,
    build_random_settlement_spec,
    get_access_token,
    pg_connect,
    wait_until,
)


def _run_block(ctx: VerifierContext, block_id: str, fn) -> None:
    try:
        detail = fn()
        ctx.recorder.record(block_id, True, detail or "passed")
    except Exception as err:  # noqa: BLE001
        ctx.recorder.record(block_id, False, str(err))
        raise


def _ensure_tokens(ctx: VerifierContext) -> dict[str, str]:
    if not ctx.tokens:
        ctx.tokens = {
            "read": get_access_token(ctx.manifest, "read"),
            "write": get_access_token(ctx.manifest, "write"),
            "admin": get_access_token(ctx.manifest, "admin"),
        }
    return ctx.tokens


def test_backlog_accumulation_and_drain(ctx: VerifierContext) -> None:
    """Scored block: Backlog recovery (7 points) — async.backlog_recovery."""
    def _check() -> str:
        tokens = _ensure_tokens(ctx)
        m = ctx.manifest
        lam = boto_client("lambda", ctx.config)
        esm_uuid = m["messaging"]["event_source_mapping_uuid"]
        service_url = m["service_url"].rstrip("/")

        lam.update_event_source_mapping(UUID=esm_uuid, Enabled=False)
        try:
            specs = [build_random_settlement_spec(ctx.rng, step_count=4) for _ in range(5)]
            total_events = 0
            with httpx.Client(base_url=service_url, timeout=10.0) as client:
                for spec in specs:
                    sid = spec["settlementId"]
                    r_create = client.post(
                        "/v1/settlements",
                        headers={
                            "Authorization": f"Bearer {tokens['write']}",
                            "Idempotency-Key": f"idem-bg-create-{sid}",
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
                    assert r_create.status_code == 201
                    total_events += 1

                    for entry in spec["entries"]:
                        r_ev = client.post(
                            f"/v1/settlements/{sid}/entries",
                            headers={
                                "Authorization": f"Bearer {tokens['write']}",
                                "Idempotency-Key": f"idem-bg-entry-{entry['entryId']}",
                            },
                            json=entry,
                        )
                        assert r_ev.status_code == 202
                        total_events += 1

                unprojected = client.get(
                    f"/v1/settlements/{specs[0]['settlementId']}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
                assert unprojected.status_code == 404, "Expected 404 while projector ESM is disabled"
        finally:
            lam.update_event_source_mapping(UUID=esm_uuid, Enabled=True)

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            for spec in specs:
                sid = spec["settlementId"]
                expected_version = len(spec["entries"]) + 1

                def _drained() -> bool:
                    r = client.get(
                        f"/v1/settlements/{sid}",
                        headers={"Authorization": f"Bearer {tokens['read']}"},
                    )
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
        service_url = m["service_url"].rstrip("/")

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
        poison_body = json.dumps(
            {
                "schemaVersion": "1.0",
                "poisonMarker": poison_marker,
                "invalidEnvelope": True,
            }
        )
        sqs.send_message(QueueUrl=m["messaging"]["queue_url"], MessageBody=poison_body)

        spec = build_random_settlement_spec(ctx.rng, step_count=2)
        fresh_id = spec["settlementId"]
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r_c = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {tokens['write']}",
                    "Idempotency-Key": f"idem-dlq-create-{fresh_id}",
                },
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
                    headers={
                        "Authorization": f"Bearer {tokens['write']}",
                        "Idempotency-Key": f"idem-dlq-entry-{entry['entryId']}",
                    },
                    json=entry,
                )
                assert r_e.status_code == 202

            def _fresh_projected() -> bool:
                r = client.get(
                    f"/v1/settlements/{fresh_id}",
                    headers={"Authorization": f"Bearer {tokens['read']}"},
                )
                return r.status_code == 200 and r.json().get("version") == 3

            wait_until(_fresh_projected, timeout_sec=40.0, interval_sec=1.0, description="valid messages projected alongside poison message")

            r_dup = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": f"Bearer {tokens['read']}"},
            )
            assert r_dup.status_code == 200
            assert r_dup.json()["version"] == meta["expected_version"]

        def _poison_in_dlq() -> bool:
            resp = sqs.receive_message(
                QueueUrl=m["messaging"]["dlq_url"],
                MaxNumberOfMessages=10,
                WaitTimeSeconds=1,
            )
            for msg in resp.get("Messages", []):
                if poison_marker in msg.get("Body", ""):
                    return True
            return False

        wait_until(_poison_in_dlq, timeout_sec=45.0, interval_sec=1.5, description="poison message redriven to DLQ")
        ctx.committed_settlements[fresh_id] = {
            "spec": spec,
            "expected_version": 3,
            "last_status": spec["entries"][-1]["status"],
            "last_stage": spec["entries"][-1]["clearingStage"],
        }
        return "Duplicate SQS event ignored idempotently and poison message isolated to DLQ"

    _run_block(ctx, "async.duplicate_and_dlq", _check)
