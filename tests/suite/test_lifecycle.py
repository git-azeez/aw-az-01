from __future__ import annotations

from datetime import datetime, timezone
import json
import uuid

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


def test_reapply_idempotence(ctx: VerifierContext) -> None:
    """Scored block: Stable deployment (7 points) — lifecycle.reapply_idempotence."""
    def _check() -> str:
        before_manifest = ctx.manifest
        before_db_endpoint = before_manifest["database"]["endpoint"]
        before_table_arn = before_manifest["projections"]["table_arn"]
        before_bucket = before_manifest["audit"]["bucket_name"]
        sqs = boto_client("sqs", ctx.config)
        lam = boto_client("lambda", ctx.config)
        scheduler = boto_client("scheduler", ctx.config)
        ddb = boto_client("dynamodb", ctx.config)
        s3 = boto_client("s3", ctx.config)
        rclient = valkey_connect(before_manifest, ctx.config)

        committed_items = list(ctx.committed_settlements.items())
        sample_sid, sample_meta = committed_items[0]
        ledger_sid, ledger_meta = committed_items[1]
        s3_loss_sid, s3_loss_meta = committed_items[2]
        orphan_sid = str(uuid.uuid4())
        now_iso = datetime.now(timezone.utc).isoformat()

        with pg_connect(before_manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.settlements")
                before_count = cur.fetchone()[0]
                cur.execute(
                    """
                    UPDATE clearledger.outbox
                    SET published_at = NULL, archived_at = NULL
                    WHERE settlement_id = %s AND aggregate_version = %s
                    """,
                    (sample_sid, sample_meta["expected_version"]),
                )
            conn.commit()

        # Remove S3 archive batches containing (sample_sid, expected_version) AND (s3_loss_sid, expected_version)
        # Note: for s3_loss_sid, clearledger.outbox.archived_at remains NOT NULL in PostgreSQL, so deploy.sh must
        # genuinely inspect S3 ledger-audit/ against clearledger.outbox to detect and heal the missing S3 audit record!
        for obj in s3.list_objects_v2(Bucket=before_bucket, Prefix="ledger-audit/").get("Contents", []):
            body = s3.get_object(Bucket=before_bucket, Key=obj["Key"])["Body"].read().decode()
            for line in body.splitlines():
                if line.strip():
                    rec = json.loads(line)
                    agg_id = rec.get("aggregateId")
                    agg_ver = int(rec.get("aggregateVersion", 0))
                    if (agg_id == sample_sid and agg_ver == sample_meta["expected_version"]) or (
                        agg_id == s3_loss_sid and agg_ver == s3_loss_meta["expected_version"]
                    ):
                        s3.delete_object(Bucket=before_bucket, Key=obj["Key"])
                        break

        # Plant a stray S3 object outside ledger-audit/ that deploy.sh must purge
        s3.put_object(
            Bucket=before_bucket,
            Key="drifted-audit/stray-unscoped-batch.ndjson",
            Body=b'{"stray":true}\n',
            ContentType="application/x-ndjson",
        )

        # 1. Control-plane drift across SQS, DLQ, EventBridge Scheduler, and Lambda worker environments
        sqs.set_queue_attributes(
            QueueUrl=before_manifest["messaging"]["queue_url"],
            Attributes={"VisibilityTimeout": "19"},
        )
        sqs.set_queue_attributes(
            QueueUrl=before_manifest["messaging"]["dlq_url"],
            Attributes={"MessageRetentionPeriod": "86400"},
        )

        outbox_sched_name = before_manifest["schedules"]["outbox_schedule_name"]
        sched_cur = scheduler.get_schedule(Name=outbox_sched_name)
        scheduler.update_schedule(
            Name=outbox_sched_name,
            ScheduleExpression=sched_cur["ScheduleExpression"],
            FlexibleTimeWindow=sched_cur["FlexibleTimeWindow"],
            Target=sched_cur["Target"],
            State="DISABLED",
        )

        relay_fn = before_manifest["workers"]["outbox_relay"]["function_name"]
        relay_cfg = lam.get_function_configuration(FunctionName=relay_fn)
        relay_env = dict((relay_cfg.get("Environment") or {}).get("Variables") or {})
        relay_env["OUTBOX_BATCH_SIZE"] = "5"
        lam.update_function_configuration(
            FunctionName=relay_fn,
            Environment={"Variables": relay_env},
        )

        archiver_fn = before_manifest["workers"]["audit_archiver"]["function_name"]
        archiver_cfg = lam.get_function_configuration(FunctionName=archiver_fn)
        archiver_env = dict((archiver_cfg.get("Environment") or {}).get("Variables") or {})
        archiver_env["AUDIT_PREFIX"] = "drifted-audit/"
        lam.update_function_configuration(
            FunctionName=archiver_fn,
            Environment={"Variables": archiver_env},
        )

        # 2. Data-plane drift:
        # - Inflated-version STATE corruption on sample_sid + poisoned Valkey cache
        # - Missing EVENT#00000001 + in-place mutated EVENT#00000002 + phantom EVENT#00000099 on ledger_sid
        # - Orphan settlement partition in DynamoDB and Valkey absent from PostgreSQL
        ddb.put_item(
            TableName=before_manifest["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{sample_sid}"},
                "SK": {"S": "STATE"},
                "GSI1PK": {"S": f"ACCOUNT#{sample_meta['spec']['accountId']}"},
                "GSI1SK": {"S": f"UPDATED#{now_iso}#SETTLEMENT#{sample_sid}"},
                "settlement_id": {"S": sample_sid},
                "account_id": {"S": sample_meta["spec"]["accountId"]},
                "reference": {"S": sample_meta["spec"]["reference"]},
                "debit_party": {"S": sample_meta["spec"]["debitParty"]},
                "credit_party": {"S": sample_meta["spec"]["creditParty"]},
                "status": {"S": "DISPUTED"},
                "clearing_stage": {"S": "DRIFTED_INFLATED_STATE"},
                "version": {"N": "99"},
                "entry_count": {"N": "98"},
                "updated_at": {"S": now_iso},
            },
        )
        ddb.delete_item(
            TableName=before_manifest["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{ledger_sid}"}, "SK": {"S": "EVENT#00000001"}},
        )
        ddb.update_item(
            TableName=before_manifest["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{ledger_sid}"}, "SK": {"S": "EVENT#00000002"}},
            UpdateExpression="SET clearing_stage = :cs, #st = :st",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={
                ":cs": {"S": "DRIFTED_EVENT_STAGE"},
                ":st": {"S": "DISPUTED"},
            },
        )
        ddb.put_item(
            TableName=before_manifest["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{ledger_sid}"},
                "SK": {"S": "EVENT#00000099"},
                "event_id": {"S": str(uuid.uuid4())},
                "settlement_id": {"S": ledger_sid},
                "version": {"N": "99"},
                "event_type": {"S": "LedgerEntryRecorded"},
                "status": {"S": "DISPUTED"},
                "clearing_stage": {"S": "PHANTOM_EVENT_99"},
                "correlation_id": {"S": "corr-phantom-99"},
                "occurred_at": {"S": now_iso},
            },
        )
        ddb.put_item(
            TableName=before_manifest["projections"]["table_name"],
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
        rclient.set(
            f"clearledger:settlement:{sample_sid}",
            json.dumps(
                {
                    "settlementId": sample_sid,
                    "accountId": sample_meta["spec"]["accountId"],
                    "reference": sample_meta["spec"]["reference"],
                    "debitParty": sample_meta["spec"]["debitParty"],
                    "creditParty": sample_meta["spec"]["creditParty"],
                    "status": "DISPUTED",
                    "clearingStage": "DRIFTED_CACHE_STAGE",
                    "version": 99,
                    "entryCount": 98,
                    "updatedAt": now_iso,
                }
            ),
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
        dlq_attrs = sqs.get_queue_attributes(
            QueueUrl=after_manifest["messaging"]["dlq_url"],
            AttributeNames=["All"],
        )["Attributes"]
        assert int(dlq_attrs.get("MessageRetentionPeriod", 0)) == 1209600, (
            f"Expected deploy.sh to reconcile drifted DLQ MessageRetentionPeriod back to 1209600, got {dlq_attrs.get('MessageRetentionPeriod')}"
        )

        sched_after = scheduler.get_schedule(Name=after_manifest["schedules"]["outbox_schedule_name"])
        assert sched_after.get("State") == "ENABLED", (
            f"Expected deploy.sh to re-enable drifted EventBridge schedule, got {sched_after.get('State')}"
        )

        relay_after = lam.get_function_configuration(
            FunctionName=after_manifest["workers"]["outbox_relay"]["function_name"]
        )
        assert ((relay_after.get("Environment") or {}).get("Variables") or {}).get("OUTBOX_BATCH_SIZE") == "50", (
            "Expected deploy.sh to restore drifted outbox_relay OUTBOX_BATCH_SIZE=50"
        )
        archiver_after = lam.get_function_configuration(
            FunctionName=after_manifest["workers"]["audit_archiver"]["function_name"]
        )
        assert ((archiver_after.get("Environment") or {}).get("Variables") or {}).get("AUDIT_PREFIX") == "ledger-audit/", (
            "Expected deploy.sh to restore drifted audit_archiver AUDIT_PREFIX=ledger-audit/"
        )

        with pg_connect(after_manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.settlements")
                after_count = cur.fetchone()[0]
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE published_at IS NULL")
                unpub_count = cur.fetchone()[0]
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE archived_at IS NULL")
                unarch_count = cur.fetchone()[0]
        assert after_count == before_count, f"Settlement count changed after re-apply: {before_count} -> {after_count}"
        assert unpub_count == 0, f"deploy.sh left {unpub_count} unpublished outbox rows after re-apply"
        assert unarch_count == 0, f"deploy.sh left {unarch_count} unarchived outbox rows after re-apply"

        all_bucket_objs = s3.list_objects_v2(Bucket=after_manifest["audit"]["bucket_name"]).get("Contents", [])
        stray_keys = [o["Key"] for o in all_bucket_objs if not o["Key"].startswith("ledger-audit/")]
        assert not stray_keys, (
            f"Expected deploy.sh to purge stray S3 objects outside ledger-audit/, found: {stray_keys}"
        )

        found_rearchived_sample = False
        found_rearchived_s3_loss = False
        for obj in s3.list_objects_v2(Bucket=after_manifest["audit"]["bucket_name"], Prefix="ledger-audit/").get("Contents", []):
            body = s3.get_object(Bucket=after_manifest["audit"]["bucket_name"], Key=obj["Key"])["Body"].read().decode()
            for line in body.splitlines():
                if line.strip():
                    rec = json.loads(line)
                    agg_id = rec.get("aggregateId")
                    agg_ver = int(rec.get("aggregateVersion", 0))
                    if agg_id == sample_sid and agg_ver == sample_meta["expected_version"]:
                        found_rearchived_sample = True
                    if agg_id == s3_loss_sid and agg_ver == s3_loss_meta["expected_version"]:
                        found_rearchived_s3_loss = True
        assert found_rearchived_sample, (
            f"Expected deploy.sh to re-archive unarchived outbox row ({sample_sid} v{sample_meta['expected_version']}) "
            f"into S3 under restored prefix ledger-audit/"
        )
        assert found_rearchived_s3_loss, (
            f"Expected deploy.sh to detect and re-archive missing S3 audit record ({s3_loss_sid} v{s3_loss_meta['expected_version']}) "
            f"whose S3 batch was deleted while archived_at remained NOT NULL in PostgreSQL"
        )

        read_tok = get_access_token(after_manifest, "read")
        service_url = resolve_service_url(after_manifest["service_url"], ctx.config)
        rclient = valkey_connect(after_manifest, ctx.config)
        with httpx.Client(base_url=service_url, timeout=10.0) as client:
            resp = client.get(
                f"/v1/settlements/{sample_sid}",
                headers={"Authorization": f"Bearer {read_tok}"},
            )
            assert resp.status_code == 200, (
                f"Expected deploy.sh to heal corrupted DynamoDB STATE projection for {sample_sid}, got {resp.status_code}"
            )
            body = resp.json()
            assert body["version"] == sample_meta["expected_version"], (
                f"Expected healed version {sample_meta['expected_version']} for {sample_sid}, got {body}"
            )
            assert body["status"] == sample_meta["last_status"]
            assert body["clearingStage"] == sample_meta["last_stage"]

            r_ledger = client.get(
                f"/v1/settlements/{ledger_sid}/ledger",
                headers={"Authorization": f"Bearer {read_tok}"},
            )
            assert r_ledger.status_code == 200, (
                f"Expected deploy.sh to heal DynamoDB EVENT#* items for {ledger_sid}, got {r_ledger.status_code}"
            )
            ledger_events = r_ledger.json().get("events", [])
            assert [e["version"] for e in ledger_events] == list(range(1, ledger_meta["expected_version"] + 1)), (
                f"Expected healed ledger events 1..{ledger_meta['expected_version']} for {ledger_sid}, got {[e['version'] for e in ledger_events]}"
            )
            expected_v2_stage = ledger_meta["spec"]["entries"][0]["clearingStage"]
            assert ledger_events[1].get("clearingStage") == expected_v2_stage, (
                f"Expected deploy.sh to repair in-place mutated EVENT#00000002 for {ledger_sid}: "
                f"expected {expected_v2_stage}, got {ledger_events[1]}"
            )

            r_orphan = client.get(
                f"/v1/settlements/{orphan_sid}",
                headers={"Authorization": f"Bearer {read_tok}"},
            )
            assert r_orphan.status_code == 404, (
                f"Expected deploy.sh to purge orphan DynamoDB/Valkey settlement {orphan_sid}, got {r_orphan.status_code}"
            )
            assert rclient.get(f"clearledger:settlement:{orphan_sid}") is None, (
                f"Expected deploy.sh to purge orphan Valkey key clearledger:settlement:{orphan_sid}"
            )

        return (
            f"Re-applied deploy.sh cleanly, reconciled multi-service control-plane & bidirectional data-plane drift, "
            f"and preserved all {after_count} settlements"
        )

    _run_block(ctx, "lifecycle.reapply_idempotence", _check)


def test_destroy_clean(ctx: VerifierContext) -> None:
    """Scored block: Clean destroy (8 points) — lifecycle.clean_destroy."""
    def _check() -> str:
        m = ctx.manifest
        prefix = m["resource_prefix"]
        iam = boto_client("iam", ctx.config)
        sqs = boto_client("sqs", ctx.config)
        logs = boto_client("logs", ctx.config)
        scheduler = boto_client("scheduler", ctx.config)
        kms = boto_client("kms", ctx.config)

        # Simulate out-of-band operational artifacts scoped to resource_prefix before teardown:
        # 1) Unmanaged inline policy on a deployment IAM role
        proj_role_name = m["iam"]["projector_role_arn"].rsplit("/", 1)[-1]
        iam.put_role_policy(
            RoleName=proj_role_name,
            PolicyName=f"{prefix}-ops-diagnostic-inline",
            PolicyDocument=json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": ["sqs:GetQueueAttributes"],
                            "Resource": m["messaging"]["queue_arn"],
                        }
                    ],
                }
            ),
        )
        # 2) Out-of-band customer-managed IAM policy attached to a deployment IAM role
        task_role_name = m["iam"]["ecs_task_role_arn"].rsplit("/", 1)[-1]
        managed_pol = iam.create_policy(
            PolicyName=f"{prefix}-ops-managed-policy",
            PolicyDocument=json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": ["sqs:GetQueueUrl"],
                            "Resource": m["messaging"]["queue_arn"],
                        }
                    ],
                }
            ),
        )["Policy"]
        iam.attach_role_policy(RoleName=task_role_name, PolicyArn=managed_pol["Arn"])

        # 3) Out-of-band prefix-scoped IAM role with inline policy
        ops_role_name = f"{prefix}-ops-breakglass-role"
        iam.create_role(
            RoleName=ops_role_name,
            AssumeRolePolicyDocument=json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {"Service": "lambda.amazonaws.com"},
                            "Action": "sts:AssumeRole",
                        }
                    ],
                }
            ),
            Tags=[
                {"Key": "ClearLedgerDeployment", "Value": prefix},
                {"Key": "Environment", "Value": m.get("environment", "eval")},
                {"Key": "Service", "Value": "clearledger"},
            ],
        )
        iam.put_role_policy(
            RoleName=ops_role_name,
            PolicyName=f"{prefix}-ops-breakglass-inline",
            PolicyDocument=json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": ["sqs:GetQueueAttributes"],
                            "Resource": m["messaging"]["queue_arn"],
                        }
                    ],
                }
            ),
        )

        # 4) Out-of-band prefix-scoped SQS queue, CloudWatch log group, EventBridge schedule, and KMS alias
        sqs.create_queue(
            QueueName=f"{prefix}-ops-dlq",
            tags={
                "ClearLedgerDeployment": prefix,
                "Environment": m.get("environment", "eval"),
                "Service": "clearledger",
                "ManagedBy": "ops-runbook",
            },
        )
        ops_log_group = f"/clearledger/{prefix}/ops-audit"
        try:
            logs.create_log_group(
                logGroupName=ops_log_group,
                tags={
                    "ClearLedgerDeployment": prefix,
                    "Environment": m.get("environment", "eval"),
                    "Service": "clearledger",
                },
            )
        except Exception:  # noqa: BLE001
            pass
        try:
            scheduler.create_schedule(
                Name=f"{prefix}-ops-canary-schedule",
                ScheduleExpression="rate(5 minutes)",
                FlexibleTimeWindow={"Mode": "OFF"},
                Target={
                    "Arn": m["workers"]["outbox_relay"]["function_arn"],
                    "RoleArn": m["iam"]["scheduler_role_arn"],
                    "Input": json.dumps({"source": "ops-canary"}),
                },
                State="ENABLED",
            )
        except Exception:  # noqa: BLE001
            pass
        try:
            kms.create_alias(
                AliasName=f"alias/{prefix}-ops-alias",
                TargetKeyId=m["kms"]["messaging_arn"],
            )
        except Exception:  # noqa: BLE001
            pass

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

        return "destroy.sh removed all deployment and prefix-scoped operational resources while preserving all baseline resources"

    _run_block(ctx, "lifecycle.clean_destroy", _check, cap_on_fail=("cleanup_leak", 79))

