from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import re
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
        logs = boto_client("logs", ctx.config)
        ddb = boto_client("dynamodb", ctx.config)
        s3 = boto_client("s3", ctx.config)
        iam = boto_client("iam", ctx.config)
        ec2 = boto_client("ec2", ctx.config)
        rclient = valkey_connect(before_manifest, ctx.config)

        committed_items = list(ctx.committed_settlements.items())
        sample_sid, sample_meta = committed_items[0]
        ledger_sid, ledger_meta = committed_items[1]
        s3_loss_sid, s3_loss_meta = committed_items[2]
        same_ver_sid, same_ver_meta = committed_items[3]
        cache_drift_sid, cache_drift_meta = committed_items[4]
        orphan_sid = str(uuid.uuid4())
        now_iso = datetime.now(timezone.utc).isoformat()

        with pg_connect(before_manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.settlements")
                before_count = cur.fetchone()[0]
                cur.execute("SET LOCAL session_replication_role = 'replica'")
                cur.execute(
                    """
                    UPDATE clearledger.outbox
                    SET published_at = NULL, archived_at = NULL
                    WHERE settlement_id = %s AND aggregate_version = %s
                    """,
                    (sample_sid, sample_meta["expected_version"]),
                )
                cur.execute("SET LOCAL session_replication_role = 'origin'")
            conn.commit()

        # Corrupt S3 audit archive for s3_loss_sid in-place (while archived_at remains NOT NULL in PostgreSQL),
        # drop one archived event completely while keeping a valid-digest subset batch, write an overlapping valid-digest
        # single-event batch, and write a forged-digest batch key.
        # Note: we do NOT delete sample_sid's existing S3 batch here, so if deploy.sh merely runs audit_archiver
        # without deduplicating S3 batches against unarchived PostgreSQL rows, sample_sid will be duplicated in S3!
        with pg_connect(before_manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT event_id::text, seq FROM clearledger.outbox")
                eid_to_seq = {r[0]: int(r[1]) for r in cur.fetchall()}
                cur.execute(
                    "SELECT payload FROM clearledger.events WHERE settlement_id = %s AND aggregate_version = 1",
                    (same_ver_sid,),
                )
                sv_v1_row = cur.fetchone()
                expected_sv_v1_env = (
                    json.loads(sv_v1_row[0]) if isinstance(sv_v1_row[0], str) else sv_v1_row[0]
                )

        for obj in s3.list_objects_v2(Bucket=before_bucket, Prefix="ledger-audit/").get("Contents", []):
            body = s3.get_object(Bucket=before_bucket, Key=obj["Key"])["Body"].read().decode()
            lines = [ln for ln in body.splitlines() if ln.strip()]
            tampered = False
            for idx, line in enumerate(lines):
                rec = json.loads(line)
                agg_id = rec.get("aggregateId")
                agg_ver = int(rec.get("aggregateVersion", 0))
                if agg_id == s3_loss_sid and agg_ver == s3_loss_meta["expected_version"]:
                    rec.setdefault("data", {})["clearingStage"] = "TAMPERED_S3_REAPPLY_STAGE"
                    lines[idx] = json.dumps(rec)
                    tampered = True
            if tampered:
                if len(lines) >= 4:
                    _dropped_line = lines.pop()
                    forged_line = lines.pop()
                    valid_subset = [ln for ln in lines[:2] if json.loads(ln).get("aggregateId") != sample_sid]
                    if valid_subset:
                        valid_raw = ("\n".join(valid_subset) + "\n").encode("utf-8")
                        valid_s1 = eid_to_seq[json.loads(valid_subset[0])["eventId"]]
                        valid_s2 = eid_to_seq[json.loads(valid_subset[-1])["eventId"]]
                        valid_dig = hashlib.sha256(valid_raw).hexdigest()[:16]
                        dup_raw = (valid_subset[0] + "\n").encode("utf-8")
                        dup_dig = hashlib.sha256(dup_raw).hexdigest()[:16]
                        s3.put_object(
                            Bucket=before_bucket,
                            Key=f"ledger-audit/batch-{valid_s1:08d}-{valid_s2:08d}-{valid_dig}.ndjson",
                            Body=valid_raw,
                            ContentType="application/x-ndjson",
                        )
                        s3.put_object(
                            Bucket=before_bucket,
                            Key=f"ledger-audit/batch-{valid_s1:08d}-{valid_s1:08d}-{dup_dig}.ndjson",
                            Body=dup_raw,
                            ContentType="application/x-ndjson",
                        )
                        if len(valid_subset) == 2 and valid_s1 < valid_s2:
                            rev_raw = ("\n".join(reversed(valid_subset)) + "\n").encode("utf-8")
                            rev_dig = hashlib.sha256(rev_raw).hexdigest()[:16]
                            s3.put_object(
                                Bucket=before_bucket,
                                Key=f"ledger-audit/batch-{valid_s1:08d}-{valid_s2:08d}-{rev_dig}.ndjson",
                                Body=rev_raw,
                                ContentType="application/x-ndjson",
                            )
                else:
                    forged_line = lines.pop() if len(lines) >= 2 and json.loads(lines[-1]).get("aggregateId") != s3_loss_sid else lines[0]
                s3.put_object(
                    Bucket=before_bucket,
                    Key=obj["Key"],
                    Body=("\n".join(lines) + "\n").encode("utf-8"),
                    ContentType="application/x-ndjson",
                )
                s3.put_object(
                    Bucket=before_bucket,
                    Key="ledger-audit/batch-00000001-00000001-0000000000000000.ndjson",
                    Body=(forged_line + "\n").encode("utf-8"),
                    ContentType="application/x-ndjson",
                )
                break

        # Plant both a stray S3 object outside ledger-audit/ AND an orphan S3 batch inside ledger-audit/
        s3.put_object(
            Bucket=before_bucket,
            Key="drifted-audit/stray-unscoped-batch.ndjson",
            Body=b'{"stray":true}\n',
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
            "correlationId": "corr-orphan-reapply",
            "idempotencyKey": "idem-orphan-reapply",
            "data": {
                "kind": "settlementInitiated",
                "accountId": "ACCT-ORPHAN",
                "reference": "REF-ORPHAN",
                "debitParty": "BANK-ORPHAN-A",
                "creditParty": "BANK-ORPHAN-B",
                "entryId": None,
                "status": "INITIATED",
                "clearingStage": "ORPHAN_S3_REAPPLY",
                "memo": None,
            },
        }
        s3.put_object(
            Bucket=before_bucket,
            Key="ledger-audit/batch-99999902-99999902-orphan.ndjson",
            Body=(json.dumps(orphan_s3_env) + "\n").encode("utf-8"),
            ContentType="application/x-ndjson",
        )

        # 1. Control-plane drift across SQS, DLQ, EventBridge Scheduler, CloudWatch Logs, Lambda worker environments,
        #    out-of-band IAM role policies, and security group egress rules
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

        archive_sched_name = before_manifest["schedules"]["archive_schedule_name"]
        arch_sched_cur = scheduler.get_schedule(Name=archive_sched_name)
        scheduler.update_schedule(
            Name=archive_sched_name,
            ScheduleExpression="rate(30 minutes)",
            FlexibleTimeWindow=arch_sched_cur["FlexibleTimeWindow"],
            Target=arch_sched_cur["Target"],
            State="DISABLED",
        )

        logs.put_retention_policy(
            logGroupName=before_manifest["logs"]["api_log_group"],
            retentionInDays=7,
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

        prefix = before_manifest["resource_prefix"]
        task_role_name = before_manifest["iam"]["ecs_task_role_arn"].rsplit("/", 1)[-1]
        iam.put_role_policy(
            RoleName=task_role_name,
            PolicyName="drifted-ops-s3-bypass",
            PolicyDocument=json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": ["s3:*"],
                            "Resource": "*",
                        }
                    ],
                }
            ),
        )
        proj_role_name = before_manifest["iam"]["projector_role_arn"].rsplit("/", 1)[-1]
        drifted_managed_pol = iam.create_policy(
            PolicyName=f"{prefix}-drifted-projector-policy",
            PolicyDocument=json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": ["dynamodb:*"],
                            "Resource": "*",
                        }
                    ],
                }
            ),
        )["Policy"]
        iam.attach_role_policy(RoleName=proj_role_name, PolicyArn=drifted_managed_pol["Arn"])

        rds_sg_id = before_manifest["network"]["security_group_ids"]["rds"]
        try:
            ec2.authorize_security_group_egress(
                GroupId=rds_sg_id,
                IpPermissions=[
                    {
                        "IpProtocol": "tcp",
                        "FromPort": 443,
                        "ToPort": 443,
                        "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
                    }
                ],
            )
        except Exception:  # noqa: BLE001
            pass

        # 2. Data-plane drift:
        # - Inflated-version STATE corruption on sample_sid + poisoned Valkey cache
        # - Missing EVENT#00000001 + in-place mutated EVENT#00000002 + phantom EVENT#00000099 on ledger_sid
        # - Same-version / same-SK attribute (last_memo, last_entry_id, updated_at, occurred_at, entry_id, memo, GSI) + stray SK item on same_ver_sid
        # - Valkey-only cache poison (lastEntryId/lastMemo/updatedAt with valid TTL=80s) on cache_drift_sid (whose DynamoDB items remain valid)
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
        ddb.update_item(
            TableName=before_manifest["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "STATE"}},
            UpdateExpression="SET last_memo = :lm, last_entry_id = :leid, updated_at = :ua, GSI1PK = :gpk, GSI1SK = :gsk",
            ExpressionAttributeValues={
                ":lm": {"S": "DRIFTED_SAME_VER_LAST_MEMO"},
                ":leid": {"S": "00000000-0000-0000-0000-000000000000"},
                ":ua": {"S": "1999-01-01T00:00:00Z"},
                ":gpk": {"S": "ACCOUNT#DRIFTED-GSI"},
                ":gsk": {"S": f"CORRUPTED#{same_ver_sid}"},
            },
        )
        ddb.update_item(
            TableName=before_manifest["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "EVENT#00000001"}},
            UpdateExpression="SET occurred_at = :oa, correlation_id = :cid, envelope = :env",
            ExpressionAttributeValues={
                ":oa": {"S": "1999-01-01T00:00:00Z"},
                ":cid": {"S": "corr-drifted-same-ver"},
                ":env": {"S": json.dumps({"corruptedEnvelope": True, "aggregateId": same_ver_sid})},
            },
        )
        ddb.update_item(
            TableName=before_manifest["projections"]["table_name"],
            Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "EVENT#00000002"}},
            UpdateExpression="SET memo = :m, entry_id = :eid",
            ExpressionAttributeValues={
                ":m": {"S": "DRIFTED_SAME_VER_EVENT_MEMO"},
                ":eid": {"S": "00000000-0000-0000-0000-000000000000"},
            },
        )
        ddb.put_item(
            TableName=before_manifest["projections"]["table_name"],
            Item={
                "PK": {"S": f"SETTLEMENT#{same_ver_sid}"},
                "SK": {"S": "META#STRAY"},
                "settlement_id": {"S": same_ver_sid},
                "note": {"S": "stray non-STATE/non-EVENT item in partition"},
            },
        )
        ddb.put_item(
            TableName=before_manifest["projections"]["table_name"],
            Item={
                "PK": {"S": "AUDIT#STRAY-PARTITION"},
                "SK": {"S": "META#01"},
                "note": {"S": "stray non-SETTLEMENT partition item"},
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
                    "lastMemo": "DRIFTED_CACHE_ONLY_MEMO_POISON",
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
        rclient.set("clearledger:lock:stray-marker", "poison-lock-value", ex=300)

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
        arch_sched_after = scheduler.get_schedule(Name=after_manifest["schedules"]["archive_schedule_name"])
        assert arch_sched_after.get("State") == "ENABLED" and arch_sched_after.get("ScheduleExpression") == "rate(5 minutes)", (
            f"Expected deploy.sh to restore drifted archive EventBridge schedule to ENABLED / rate(5 minutes), got {arch_sched_after}"
        )

        api_lg_after = logs.describe_log_groups(
            logGroupNamePrefix=after_manifest["logs"]["api_log_group"]
        ).get("logGroups", [])
        api_lg_match = [g for g in api_lg_after if g.get("logGroupName") == after_manifest["logs"]["api_log_group"]]
        assert api_lg_match and int(api_lg_match[0].get("retentionInDays") or 0) >= 14, (
            f"Expected deploy.sh to restore drifted api_log_group retentionInDays >= 14, got {api_lg_match}"
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

        task_inline_after = iam.list_role_policies(RoleName=task_role_name).get("PolicyNames", [])
        assert "drifted-ops-s3-bypass" not in task_inline_after, (
            f"Expected deploy.sh to remove out-of-band inline IAM policy drifted-ops-s3-bypass from {task_role_name}, found {task_inline_after}"
        )
        proj_attached_after = [
            p.get("PolicyName") for p in iam.list_attached_role_policies(RoleName=proj_role_name).get("AttachedPolicies", [])
        ]
        assert f"{prefix}-drifted-projector-policy" not in proj_attached_after, (
            f"Expected deploy.sh to detach out-of-band customer-managed IAM policy {prefix}-drifted-projector-policy from {proj_role_name}, found {proj_attached_after}"
        )
        rds_sg_after = ec2.describe_security_groups(GroupIds=[rds_sg_id])["SecurityGroups"][0]
        assert not (rds_sg_after.get("IpPermissionsEgress") or []), (
            f"Expected deploy.sh to revoke out-of-band egress rules on rds security group {rds_sg_id}, found {rds_sg_after.get('IpPermissionsEgress')}"
        )

        with pg_connect(after_manifest, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM clearledger.settlements")
                after_count = cur.fetchone()[0]
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE published_at IS NULL")
                unpub_count = cur.fetchone()[0]
                cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE archived_at IS NULL")
                unarch_count = cur.fetchone()[0]
                cur.execute("SELECT seq, event_id::text, payload FROM clearledger.outbox")
                pg_outbox_map = {
                    ev_id: (int(seq), (json.loads(pay) if isinstance(pay, str) else pay))
                    for seq, ev_id, pay in cur.fetchall()
                }
        assert after_count == before_count, f"Settlement count changed after re-apply: {before_count} -> {after_count}"
        assert unpub_count == 0, f"deploy.sh left {unpub_count} unpublished outbox rows after re-apply"
        assert unarch_count == 0, f"deploy.sh left {unarch_count} unarchived outbox rows after re-apply"

        all_bucket_objs = s3.list_objects_v2(Bucket=after_manifest["audit"]["bucket_name"]).get("Contents", [])
        stray_keys = [o["Key"] for o in all_bucket_objs if not o["Key"].startswith("ledger-audit/")]
        assert not stray_keys, (
            f"Expected deploy.sh to purge stray S3 objects outside ledger-audit/, found: {stray_keys}"
        )

        s3_records_by_eid: dict[str, dict] = {}
        total_s3_lines = 0
        key_pattern = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")
        for obj in all_bucket_objs:
            key = obj["Key"]
            key_match = key_pattern.match(key)
            assert key_match is not None, (
                f"Expected S3 audit batch key {key} to match canonical format ledger-audit/batch-<first_seq:08d>-<last_seq:08d>-<16_char_sha256_hex>.ndjson"
            )
            first_seq_str, last_seq_str, key_digest = key_match.groups()
            raw_bytes = s3.get_object(Bucket=after_manifest["audit"]["bucket_name"], Key=key)["Body"].read()
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
                        f"Expected deploy.sh to purge orphan S3 audit record {ev_id} under ledger-audit/"
                    )
                    assert ev_id not in s3_records_by_eid, (
                        f"Duplicate S3 audit record found for eventId {ev_id} under ledger-audit/"
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
            f"Expected S3 audit archive under ledger-audit/ to match clearledger.outbox 1-to-1 "
            f"(pg={len(pg_outbox_map)}, s3={total_s3_lines})"
        )
        ver_resp = s3.list_object_versions(Bucket=after_manifest["audit"]["bucket_name"])
        del_markers = ver_resp.get("DeleteMarkers", [])
        assert not del_markers, (
            f"Expected deploy.sh to purge all S3 DeleteMarkers from versioned audit bucket, found {len(del_markers)}: "
            f"{[(dm.get('Key'), dm.get('VersionId')) for dm in del_markers[:5]]}"
        )
        noncurrent_vers = [v for v in ver_resp.get("Versions", []) if not v.get("IsLatest")]
        assert not noncurrent_vers, (
            f"Expected deploy.sh to purge all noncurrent S3 object versions (IsLatest=false) from audit bucket, "
            f"found {len(noncurrent_vers)}: {[(v.get('Key'), v.get('VersionId')) for v in noncurrent_vers[:5]]}"
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

            r_same_ver = client.get(
                f"/v1/settlements/{same_ver_sid}",
                headers={"Authorization": f"Bearer {read_tok}"},
            )
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
                f"Expected deploy.sh to heal same-version drifted STATE (lastEntryId/lastMemo/updatedAt) for {same_ver_sid}, got {sv_body}"
            )
            r_sv_ledger = client.get(
                f"/v1/settlements/{same_ver_sid}/ledger",
                headers={"Authorization": f"Bearer {read_tok}"},
            )
            assert r_sv_ledger.status_code == 200
            sv_events = r_sv_ledger.json().get("events", [])
            expected_sv_v2 = same_ver_meta["spec"]["entries"][0]
            assert (
                len(sv_events) >= 2
                and not str(sv_events[0].get("occurredAt", "")).startswith("1999-")
                and sv_events[1].get("entryId") == expected_sv_v2["entryId"]
                and sv_events[1].get("memo") == expected_sv_v2["memo"]
            ), (
                f"Expected deploy.sh to heal same-version mutated EVENT#00000001..2 (occurredAt/entryId/memo) for {same_ver_sid}, got {sv_events[:2]}"
            )
            sv_v1_ddb = ddb.get_item(
                TableName=after_manifest["projections"]["table_name"],
                Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "EVENT#00000001"}},
                ConsistentRead=True,
            ).get("Item") or {}
            assert json.loads(sv_v1_ddb.get("envelope", {}).get("S", "{}")) == expected_sv_v1_env, (
                f"Expected deploy.sh to heal EVENT#00000001.envelope JSON attribute for {same_ver_sid}"
            )
            assert sv_v1_ddb.get("correlation_id", {}).get("S") != "corr-drifted-same-ver", (
                f"Expected deploy.sh to heal EVENT#00000001.correlation_id attribute for {same_ver_sid}"
            )
            stray_item = ddb.get_item(
                TableName=after_manifest["projections"]["table_name"],
                Key={"PK": {"S": f"SETTLEMENT#{same_ver_sid}"}, "SK": {"S": "META#STRAY"}},
                ConsistentRead=True,
            ).get("Item")
            assert stray_item is None, (
                f"Expected deploy.sh to purge stray non-STATE/non-EVENT item SK=META#STRAY under SETTLEMENT#{same_ver_sid}"
            )
            stray_part_item = ddb.get_item(
                TableName=after_manifest["projections"]["table_name"],
                Key={"PK": {"S": "AUDIT#STRAY-PARTITION"}, "SK": {"S": "META#01"}},
                ConsistentRead=True,
            ).get("Item")
            assert stray_part_item is None, (
                "Expected deploy.sh to purge stray non-SETTLEMENT partition item PK=AUDIT#STRAY-PARTITION"
            )
            gsi_q = ddb.query(
                TableName=after_manifest["projections"]["table_name"],
                IndexName=after_manifest["projections"]["gsi_name"],
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
                headers={"Authorization": f"Bearer {read_tok}"},
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
            assert rclient.get("clearledger:lock:stray-marker") is None, (
                "Expected deploy.sh to purge stray non-settlement Valkey key clearledger:lock:stray-marker"
            )

        return (
            f"Re-applied deploy.sh cleanly, reconciled multi-service control-plane & bidirectional data-plane/GSI/S3 drift, "
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
        s3 = boto_client("s3", ctx.config)
        ddb = boto_client("dynamodb", ctx.config)
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
        # 2) Out-of-band multi-version customer-managed IAM policy attached to a deployment IAM role
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
        try:
            iam.create_policy_version(
                PolicyArn=managed_pol["Arn"],
                PolicyDocument=json.dumps(
                    {
                        "Version": "2012-10-17",
                        "Statement": [
                            {
                                "Effect": "Allow",
                                "Action": ["sqs:GetQueueUrl", "sqs:GetQueueAttributes"],
                                "Resource": m["messaging"]["queue_arn"],
                            }
                        ],
                    }
                ),
                SetAsDefault=True,
            )
        except Exception:  # noqa: BLE001
            pass
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

        # 4) Out-of-band prefix-scoped SQS queue, versioned S3 bucket, DynamoDB table,
        #    CloudWatch log group, EventBridge schedule, KMS alias, and customer-managed KMS key
        sqs.create_queue(
            QueueName=f"{prefix}-ops-dlq",
            tags={
                "ClearLedgerDeployment": prefix,
                "Environment": m.get("environment", "eval"),
                "Service": "clearledger",
                "ManagedBy": "ops-runbook",
            },
        )
        ops_bucket_name = f"{prefix}-ops-quarantine"
        try:
            s3.create_bucket(Bucket=ops_bucket_name)
            s3.put_bucket_versioning(
                Bucket=ops_bucket_name,
                VersioningConfiguration={"Status": "Enabled"},
            )
            s3.put_object(
                Bucket=ops_bucket_name,
                Key="quarantine/diag-001.ndjson",
                Body=b'{"diag":1}\n',
                ContentType="application/x-ndjson",
            )
        except Exception:  # noqa: BLE001
            pass
        try:
            ddb.create_table(
                TableName=f"{prefix}-ops-scratch",
                AttributeDefinitions=[{"AttributeName": "PK", "AttributeType": "S"}],
                KeySchema=[{"AttributeName": "PK", "KeyType": "HASH"}],
                BillingMode="PAY_PER_REQUEST",
                Tags=[
                    {"Key": "ClearLedgerDeployment", "Value": prefix},
                    {"Key": "Environment", "Value": m.get("environment", "eval")},
                    {"Key": "Service", "Value": "clearledger"},
                ],
            )
        except Exception:  # noqa: BLE001
            pass
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
            ops_kms_key = kms.create_key(
                Description=f"{prefix} ops diagnostic key",
                Tags=[
                    {"TagKey": "ClearLedgerDeployment", "TagValue": prefix},
                    {"TagKey": "Environment", "TagValue": m.get("environment", "eval")},
                    {"TagKey": "Service", "TagValue": "clearledger"},
                ],
            )["KeyMetadata"]["KeyId"]
            kms.create_alias(
                AliasName=f"alias/{prefix}-ops-alias",
                TargetKeyId=ops_kms_key,
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

