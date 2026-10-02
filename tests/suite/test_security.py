from __future__ import annotations

import json
import uuid

import httpx
import jsonschema

from .conftest import VerifierContext
from .helpers import (
    CONTRACTS_DIR,
    boto_client,
    fetch_oauth_token,
    get_access_token,
    invoke_lambda_sync,
    pg_connect,
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


def test_authorization_audit_and_observability(ctx: VerifierContext) -> None:
    """Scored block: Authorization, audit and logs (3 points) — security.auth_audit_logs."""
    def _check() -> str:
        m = ctx.manifest
        service_url = m["service_url"].rstrip("/")
        read_tok = get_access_token(m, "read")
        write_tok = get_access_token(m, "write")
        admin_tok = get_access_token(m, "admin")

        bad_status, _ = fetch_oauth_token(m, "read", secret_override="wrong-secret-value")
        assert bad_status in {400, 401, 403}, f"Expected bad client secret to fail, got {bad_status}"

        wrong_scope_status, wrong_scope_body = fetch_oauth_token(
            m, "read", scope_override="clearledger/admin"
        )
        if wrong_scope_status == 200 and "access_token" in wrong_scope_body:
            with httpx.Client(base_url=service_url, timeout=10.0) as client:
                sid_probe = next(iter(ctx.committed_settlements.keys()))
                probe = client.post(
                    f"/v1/admin/projections/{sid_probe}/rebuild",
                    headers={"Authorization": f"Bearer {wrong_scope_body['access_token']}"},
                )
                if probe.status_code < 400:
                    ctx.recorder.add_cap("auth_escalation", 49)
                    raise AssertionError("Read client obtained token accepted on admin endpoint")

        settlement_id = next(iter(ctx.committed_settlements.keys()))
        corr_marker = f"corr-sec-{uuid.uuid4().hex[:10]}"

        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            r_no_auth = client.get(f"/v1/settlements/{settlement_id}")
            if r_no_auth.status_code != 401:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Unauthenticated GET returned {r_no_auth.status_code}, expected 401")

            r_forged = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": "Bearer forged.invalid.token"},
            )
            if r_forged.status_code != 401:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Forged token returned {r_forged.status_code}, expected 401")

            r_read_on_write = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {read_tok}",
                    "Idempotency-Key": f"idem-forbid-{uuid.uuid4()}",
                },
                json={
                    "settlementId": str(uuid.uuid4()),
                    "accountId": "acct-9999",
                    "reference": "CLR-999999",
                    "debitParty": "CITIUS33",
                    "creditParty": "CHASUS33",
                    "expectedVersion": 0,
                },
            )
            if r_read_on_write.status_code != 403:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Read token on POST /v1/settlements returned {r_read_on_write.status_code}, expected 403")

            r_read_on_admin = client.post(
                f"/v1/admin/projections/{settlement_id}/rebuild",
                headers={"Authorization": f"Bearer {read_tok}"},
            )
            if r_read_on_admin.status_code != 403:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Read token on admin rebuild returned {r_read_on_admin.status_code}, expected 403")

            r_write_on_read = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": f"Bearer {write_tok}"},
            )
            if r_write_on_read.status_code != 403:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Write token on GET returned {r_write_on_read.status_code}, expected 403")

            r_write_on_admin = client.post(
                f"/v1/admin/projections/{settlement_id}/rebuild",
                headers={"Authorization": f"Bearer {write_tok}"},
            )
            if r_write_on_admin.status_code != 403:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Write token on admin rebuild returned {r_write_on_admin.status_code}, expected 403")

            r_admin_on_read = client.get(
                f"/v1/settlements/{settlement_id}",
                headers={"Authorization": f"Bearer {admin_tok}"},
            )
            if r_admin_on_read.status_code != 403:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Admin token on GET returned {r_admin_on_read.status_code}, expected 403")

            r_admin_on_write = client.post(
                "/v1/settlements",
                headers={
                    "Authorization": f"Bearer {admin_tok}",
                    "Idempotency-Key": f"idem-forbid-adm-{uuid.uuid4()}",
                },
                json={
                    "settlementId": str(uuid.uuid4()),
                    "accountId": "acct-9999",
                    "reference": "CLR-999999",
                    "debitParty": "CITIUS33",
                    "creditParty": "CHASUS33",
                    "expectedVersion": 0,
                },
            )
            if r_admin_on_write.status_code != 403:
                ctx.recorder.add_cap("auth_escalation", 49)
                raise AssertionError(f"Admin token on POST /v1/settlements returned {r_admin_on_write.status_code}, expected 403")

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
        arch_res = invoke_lambda_sync(m["workers"]["audit_archiver"]["function_name"])
        _ = arch_res

        s3 = boto_client("s3", ctx.config)
        event_schema = json.loads((CONTRACTS_DIR / "schemas" / "events.schema.json").read_text())

        def _has_audit_objects() -> list[dict]:
            objs = s3.list_objects_v2(
                Bucket=m["audit"]["bucket_name"],
                Prefix=m["audit"]["prefix"],
            ).get("Contents", [])
            return objs if objs else []

        objects = wait_until(_has_audit_objects, timeout_sec=30.0, interval_sec=1.0, description="S3 audit archive objects")
        validated_records = 0
        for obj in objects:
            body = s3.get_object(Bucket=m["audit"]["bucket_name"], Key=obj["Key"])["Body"].read().decode()
            for line in body.splitlines():
                if not line.strip():
                    continue
                record = json.loads(line)
                jsonschema.validate(instance=record, schema=event_schema)
                validated_records += 1
        assert validated_records >= 10, f"Expected >=10 archived event records in S3, found {validated_records}"

        with pg_connect(m, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE archived_at IS NOT NULL")
                archived_db = cur.fetchone()[0]
                assert archived_db >= 10

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
