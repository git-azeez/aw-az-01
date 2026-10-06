from __future__ import annotations

import httpx

from .conftest import VerifierContext
from .helpers import (
    STATE_PATH,
    SUBMISSION_DIR,
    boto_client,
    diff_inventory,
    get_access_token,
    load_tfstate,
    pg_connect,
    resolve_service_url,
    run_script,
    snapshot_inventory,
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


def test_reapply_idempotence(ctx: VerifierContext) -> None:
    """Scored block: Stable deployment (7 points) — lifecycle.reapply_idempotence."""
    def _check() -> str:
        before_manifest = ctx.manifest
        before_db_endpoint = before_manifest["database"]["endpoint"]
        before_table_arn = before_manifest["projections"]["table_arn"]
        before_bucket = before_manifest["audit"]["bucket_name"]
        sqs = boto_client("sqs", ctx.config)

        with pg_connect(before_manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.settlements")
                before_count = cur.fetchone()[0]

        sqs.set_queue_attributes(
            QueueUrl=before_manifest["messaging"]["queue_url"],
            Attributes={"VisibilityTimeout": "19"},
        )

        proc = run_script(SUBMISSION_DIR / "deploy.sh", timeout_sec=720)
        assert proc.returncode == 0, f"Second deploy.sh failed: {proc.stderr[-800:]}"

        after_manifest = ctx.refresh_manifest()
        assert after_manifest["database"]["endpoint"] == before_db_endpoint
        assert after_manifest["projections"]["table_arn"] == before_table_arn
        assert after_manifest["audit"]["bucket_name"] == before_bucket

        q_attrs = sqs.get_queue_attributes(
            QueueUrl=after_manifest["messaging"]["queue_url"],
            AttributeNames=["All"],
        )["Attributes"]
        assert int(q_attrs.get("VisibilityTimeout", 0)) == 3, (
            f"Expected deploy.sh to reconcile drifted SQS VisibilityTimeout back to 3, got {q_attrs.get('VisibilityTimeout')}"
        )

        with pg_connect(after_manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.settlements")
                after_count = cur.fetchone()[0]
        assert after_count == before_count, f"Settlement count changed after re-apply: {before_count} -> {after_count}"

        read_tok = get_access_token(after_manifest, "read")
        sample_sid, sample_meta = next(iter(ctx.committed_settlements.items()))
        service_url = resolve_service_url(after_manifest["service_url"], ctx.config)
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            resp = client.get(
                f"/v1/settlements/{sample_sid}",
                headers={"Authorization": f"Bearer {read_tok}"},
            )
            assert resp.status_code == 200
            assert resp.json()["version"] == sample_meta["expected_version"]

        return f"Re-applied deploy.sh cleanly, reconciled SQS drift, and preserved all {after_count} settlements"

    _run_block(ctx, "lifecycle.reapply_idempotence", _check)


def test_destroy_clean(ctx: VerifierContext) -> None:
    """Scored block: Clean destroy (8 points) — lifecycle.clean_destroy."""
    def _check() -> str:
        destroy_sh = SUBMISSION_DIR / "destroy.sh"
        result = run_script(destroy_sh, timeout_sec=900)
        if result.returncode != 0:
            ctx.recorder.add_cap("cleanup_leak", 79)
            raise AssertionError(
                f"destroy.sh failed with rc={result.returncode}:\nSTDOUT:\n{result.stdout[-800:]}\nSTDERR:\n{result.stderr[-800:]}"
            )

        def _cleaned() -> dict[str, dict[str, list[str]]] | None:
            post_inv = snapshot_inventory(ctx.config)
            diff = diff_inventory(ctx.pre_deploy_inventory, post_inv)
            if not diff["additions"] and not diff["removals"]:
                return diff
            return None

        try:
            wait_until(_cleaned, timeout_sec=30.0, interval_sec=1.5, description="clean post-destroy inventory")
        except Exception:  # noqa: BLE001
            pass

        post_inv = snapshot_inventory(ctx.config)
        final = diff_inventory(ctx.pre_deploy_inventory, post_inv)

        baseline = ctx.baseline
        assert baseline["s3_bucket"] in post_inv["s3_buckets"], "Baseline S3 bucket was deleted by destroy.sh"
        assert baseline["sqs_queue_url"] in post_inv["sqs_queues"], "Baseline SQS queue was deleted by destroy.sh"
        assert baseline["dynamodb_table_name"] in post_inv["dynamodb_tables"], "Baseline DynamoDB table was deleted"
        assert baseline["iam_role_name"] in post_inv["iam_roles"], "Baseline IAM role was deleted"
        assert baseline["log_group_name"] in post_inv["log_groups"], "Baseline CloudWatch log group was deleted"
        assert baseline["vpc_id"] in post_inv["vpcs"], "Baseline VPC was deleted"

        kms = boto_client("kms", ctx.config)
        base_key = kms.describe_key(KeyId=baseline["kms_key_arn"])["KeyMetadata"]
        assert base_key["KeyState"] == "Enabled", "Baseline KMS key was disabled or scheduled for deletion"

        if STATE_PATH.is_file():
            remaining_state_res = [
                r for r in load_tfstate().get("resources", []) if r.get("mode") == "managed"
            ]
            if remaining_state_res:
                ctx.recorder.add_cap("cleanup_leak", 79)
                raise AssertionError(
                    f"terraform.tfstate still contains {len(remaining_state_res)} managed resources after destroy.sh"
                )

        if final["additions"] or final["removals"]:
            ctx.recorder.add_cap("cleanup_leak", 79)
            raise AssertionError(
                f"Post-destroy inventory mismatch: leaked={final['additions']}, removed_baseline={final['removals']}"
            )

        return "destroy.sh removed all deployment resources and preserved all baseline resources"

    _run_block(ctx, "lifecycle.clean_destroy", _check, cap_on_fail=("cleanup_leak", 79))

