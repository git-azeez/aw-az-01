from __future__ import annotations

import json
import uuid
from typing import Any

import httpx

from .conftest import VerifierContext
from .helpers import boto_client, pg_connect, resolve_service_url, verify_iam_roles_and_policies, wait_until


def _run_block(ctx: VerifierContext, block_id: str, fn) -> None:
    try:
        detail = fn()
        ctx.recorder.record(block_id, True, detail or "passed")
    except Exception as err:  # noqa: BLE001
        ctx.recorder.record(block_id, False, str(err))
        raise


def test_live_compute_and_ingress(ctx: VerifierContext) -> None:
    """Scored block: Live ingress and compute (5 points) — live.compute_ingress."""
    def _check() -> str:
        m = ctx.manifest
        ec2 = boto_client("ec2", ctx.config)
        elbv2 = boto_client("elbv2", ctx.config)
        ecs = boto_client("ecs", ctx.config)

        vpcs = ec2.describe_vpcs(VpcIds=[m["network"]["vpc_id"]])["Vpcs"]
        assert len(vpcs) == 1 and vpcs[0]["State"] == "available"

        subnet_ids = m["network"]["public_subnet_ids"] + m["network"]["private_subnet_ids"]
        subnets = ec2.describe_subnets(SubnetIds=subnet_ids)["Subnets"]
        assert len(subnets) == 4
        azs = {s["AvailabilityZone"] for s in subnets}
        assert {"us-east-1a", "us-east-1b"}.issubset(azs)

        sg_ids = m["network"]["security_group_ids"]
        assert len({sg_ids["alb"], sg_ids["ecs"], sg_ids["rds"], sg_ids["valkey"]}) == 4, (
            f"Expected 4 distinct security group IDs for alb, ecs, rds, valkey; got {sg_ids}"
        )
        live_sgs = {
            sg["GroupId"]: sg
            for sg in ec2.describe_security_groups(GroupIds=list(sg_ids.values())).get("SecurityGroups", [])
        }
        for sg_key, sg_id in sg_ids.items():
            assert sg_id in live_sgs, f"Live security group {sg_key} ({sg_id}) not found in EC2"
            assert live_sgs[sg_id].get("VpcId") == m["network"]["vpc_id"], (
                f"Live security group {sg_key} ({sg_id}) VpcId does not match manifest VPC"
            )
            expected_in_port = {"alb": 80, "ecs": 8080, "rds": 5432, "valkey": 6379}[sg_key]
            for perm in live_sgs[sg_id].get("IpPermissions", []) or []:
                assert int(perm.get("FromPort", 0)) == expected_in_port and int(perm.get("ToPort", 0)) == expected_in_port, (
                    f"Live {sg_key} security group ({sg_id}) ingress port must be {expected_in_port}, got {perm}"
                )
                if sg_key in {"ecs", "rds", "valkey"}:
                    v4_cidrs = [r.get("CidrIp") for r in perm.get("IpRanges", []) or []]
                    v6_cidrs = [r.get("CidrIpv6") for r in perm.get("Ipv6Ranges", []) or []]
                    assert "0.0.0.0/0" not in v4_cidrs and "::/0" not in v6_cidrs, (
                        f"Live {sg_key} security group ({sg_id}) exposes ingress to 0.0.0.0/0 or ::/0"
                    )
            egress_perms = live_sgs[sg_id].get("IpPermissionsEgress", []) or []
            if sg_key in {"rds", "valkey"}:
                assert not egress_perms, (
                    f"Live {sg_key} security group ({sg_id}) must have no outbound egress rules, got {egress_perms}"
                )
            elif sg_key == "alb":
                for eperm in egress_perms:
                    ev4 = [r.get("CidrIp") for r in eperm.get("IpRanges", []) or []]
                    ev6 = [r.get("CidrIpv6") for r in eperm.get("Ipv6Ranges", []) or []]
                    assert "0.0.0.0/0" not in ev4 and "::/0" not in ev6, (
                        f"Live alb security group ({sg_id}) must restrict egress to ecs security group on port 8080, not 0.0.0.0/0 or ::/0: {eperm}"
                    )

        lbs = elbv2.describe_load_balancers(LoadBalancerArns=[m["ingress"]["alb_arn"]])["LoadBalancers"]
        assert len(lbs) == 1
        lb = lbs[0]
        assert lb["Type"] == "application"
        assert lb["Scheme"] == "internet-facing"

        listeners = elbv2.describe_listeners(LoadBalancerArn=m["ingress"]["alb_arn"])["Listeners"]
        assert any(int(l["Port"]) == 80 and l["Protocol"] == "HTTP" for l in listeners)

        tgs = elbv2.describe_target_groups(TargetGroupArns=[m["ingress"]["target_group_arn"]])["TargetGroups"]
        assert len(tgs) == 1
        assert int(tgs[0]["Port"]) == 8080
        assert tgs[0]["HealthCheckPath"] == "/health/ready"

        td_live = ecs.describe_task_definition(
            taskDefinition=m["compute"]["task_definition_arn"]
        )["taskDefinition"]
        assert td_live.get("executionRoleArn") == m["iam"]["ecs_execution_role_arn"], (
            f"Live ECS task definition executionRoleArn ({td_live.get('executionRoleArn')}) does not match manifest"
        )
        assert td_live.get("taskRoleArn") == m["iam"]["ecs_task_role_arn"], (
            f"Live ECS task definition taskRoleArn ({td_live.get('taskRoleArn')}) does not match manifest"
        )
        assert str(td_live.get("networkMode", "")).lower() == "awsvpc"
        live_cdefs = td_live.get("containerDefinitions") or []
        assert len(live_cdefs) == 1
        live_log_cfg = live_cdefs[0].get("logConfiguration") or {}
        if live_log_cfg:
            assert live_log_cfg.get("logDriver") == "awslogs", (
                f"Live ECS container definition must use logDriver='awslogs', got {live_log_cfg}"
            )
            assert (live_log_cfg.get("options") or {}).get("awslogs-group") == m["logs"]["api_log_group"], (
                f"Live ECS container awslogs-group must match {m['logs']['api_log_group']}"
            )

        clusters_desc = ecs.describe_clusters(
            clusters=[m["compute"]["cluster_name"]],
            include=["SETTINGS"],
        ).get("clusters", [])
        if clusters_desc and clusters_desc[0].get("settings"):
            assert any(
                s.get("name") == "containerInsights" and s.get("value") == "enabled"
                for s in clusters_desc[0]["settings"]
            ), f"Live ECS cluster settings must enable containerInsights, got {clusters_desc[0].get('settings')}"

        def _ecs_converged() -> tuple[dict[str, Any], list[str]] | None:
            svcs = ecs.describe_services(
                cluster=m["compute"]["cluster_name"],
                services=[m["compute"]["service_name"]],
            ).get("services", [])
            assert len(svcs) == 1, f"Expected 1 ECS service, found {len(svcs)}"
            svc_obj = svcs[0]
            assert int(svc_obj.get("desiredCount", 0)) >= 2, (
                f"Expected ECS desiredCount >= 2, got {svc_obj.get('desiredCount')}"
            )
            t_arns = ecs.list_tasks(
                cluster=m["compute"]["cluster_name"],
                serviceName=m["compute"]["service_name"],
                desiredStatus="RUNNING",
            ).get("taskArns", [])
            if len(t_arns) < 2:
                return None
            t_list = ecs.describe_tasks(cluster=m["compute"]["cluster_name"], tasks=t_arns).get("tasks", [])
            running_tasks = [t for t in t_list if t.get("lastStatus") == "RUNNING"]
            if len(running_tasks) < 2 or int(svc_obj.get("runningCount", 0)) < 2:
                return None
            return svc_obj, t_arns

        svc, task_arns = wait_until(
            _ecs_converged,
            timeout_sec=60.0,
            interval_sec=1.5,
            description="ECS service convergence to >=2 running tasks",
        )
        svc_subnets = set(
            (svc.get("networkConfiguration") or {}).get("awsvpcConfiguration", {}).get("subnets") or []
        )
        if svc_subnets:
            assert svc_subnets == set(m["network"]["private_subnet_ids"]), (
                f"Expected live ECS service subnets to match private_subnet_ids {m['network']['private_subnet_ids']}, found {svc_subnets}"
            )

        instances_seen = set()
        service_url = resolve_service_url(m["service_url"], ctx.config)
        with httpx.Client(timeout=5.0) as client:
            for _ in range(8):
                resp = client.get(f"{service_url}/health/ready")
                assert resp.status_code == 200
                body = resp.json()
                assert body["status"] == "UP"
                assert body["checks"]["postgres"] == "UP"
                assert body["checks"]["dynamodb"] == "UP"
                assert body["checks"]["sqs"] == "UP"
                assert body["checks"]["valkey"] == "UP"
                inst = resp.headers.get("X-ClearLedger-Instance") or body.get("instance")
                if inst:
                    instances_seen.add(inst)
        assert len(instances_seen) >= 1

        return f"ALB and {len(task_arns)} running ECS tasks with verified role bindings across subnets"

    _run_block(ctx, "live.compute_ingress", _check)


def test_live_data_and_event_graph(ctx: VerifierContext) -> None:
    """Scored block: Live data and event graph (5 points) — live.data_event_graph."""
    def _check() -> str:
        m = ctx.manifest
        rds = boto_client("rds", ctx.config)
        sqs = boto_client("sqs", ctx.config)
        lam = boto_client("lambda", ctx.config)
        ddb = boto_client("dynamodb", ctx.config)
        ec = boto_client("elasticache", ctx.config)
        s3 = boto_client("s3", ctx.config)
        scheduler = boto_client("scheduler", ctx.config)

        raw_db_id = m["database"]["instance_id"]
        arn_db_id = m["database"]["instance_arn"].rsplit(":", 1)[-1]
        all_dbs = rds.describe_db_instances().get("DBInstances", [])
        db_inst = next(
            (
                d
                for d in all_dbs
                if d.get("DBInstanceIdentifier") in {raw_db_id, arn_db_id}
                or d.get("DbiResourceId") == raw_db_id
                or d.get("DBInstanceArn") == m["database"]["instance_arn"]
            ),
            None,
        )
        assert db_inst is not None, f"RDS instance {raw_db_id} not found"
        assert db_inst["Engine"] == "postgres"
        assert db_inst.get("DBInstanceStatus") == "available"

        with pg_connect(m, ctx.config) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT table_name
                    FROM information_schema.tables
                    WHERE table_schema = 'clearledger'
                    """
                )
                found_tables = {row[0] for row in cur.fetchall()}
                expected_tables = {"settlements", "events", "outbox", "idempotency_keys"}
                assert expected_tables.issubset(found_tables), (
                    f"Missing required clearledger tables in PostgreSQL: expected {expected_tables}, found {found_tables}"
                )
                cur.execute(
                    """
                    SELECT indexname
                    FROM pg_indexes
                    WHERE schemaname = 'clearledger'
                    """
                )
                found_indexes = {row[0] for row in cur.fetchall()}
                expected_indexes = {
                    "idx_clearledger_outbox_unpublished",
                    "idx_clearledger_outbox_unarchived",
                    "idx_clearledger_events_settlement_version",
                }
                assert expected_indexes.issubset(found_indexes), (
                    f"Missing required clearledger indexes in PostgreSQL: expected {expected_indexes}, found {found_indexes}"
                )

                def _assert_pg_rejects(label: str, sql: str, params: tuple[Any, ...] = ()) -> None:
                    cur.execute("SAVEPOINT sp_constraint_probe")
                    try:
                        cur.execute(sql, params)
                    except Exception:
                        cur.execute("ROLLBACK TO SAVEPOINT sp_constraint_probe")
                        cur.execute("RELEASE SAVEPOINT sp_constraint_probe")
                        return
                    cur.execute("ROLLBACK TO SAVEPOINT sp_constraint_probe")
                    cur.execute("RELEASE SAVEPOINT sp_constraint_probe")
                    raise AssertionError(
                        f"PostgreSQL schema accepted an invalid row that violates domain constraint ({label})"
                    )

                cur.execute("SAVEPOINT sp_outer_probe")
                try:
                    probe_sid = str(uuid.uuid4())
                    settled_probe_sid = str(uuid.uuid4())
                    probe_eid = str(uuid.uuid4())
                    probe_eid_2 = str(uuid.uuid4())
                    probe_entry_2 = str(uuid.uuid4())
                    orphan_eid = str(uuid.uuid4())
                    probe_ts = "2026-01-01T00:00:00Z"
                    probe_ts_v2 = "2026-01-01T00:01:00Z"

                    def _make_event_payload(
                        eid: str,
                        sid: str,
                        ver: int,
                        etype: str = "SettlementInitiated",
                        corr: str = "corr-probe",
                        idem: str = "idem-probe-1",
                        status: str | None = None,
                        stage: str | None = None,
                        entry_id: str | None = None,
                        kind: str | None = None,
                        debit: str | None = "BANK-A",
                        credit: str | None = "BANK-B",
                        ref: str | None = "REF-PROBE",
                        memo: str | None = None,
                        occurred_at: str = probe_ts,
                        extra_top: dict[str, Any] | None = None,
                        extra_data: dict[str, Any] | None = None,
                    ) -> str:
                        eff_status = status or ("INITIATED" if ver == 1 else "CLEARED")
                        eff_stage = stage or ("INIT" if ver == 1 else "CLR-1")
                        eff_kind = kind or ("settlementInitiated" if ver == 1 else "ledgerEntryRecorded")
                        eff_entry_id = entry_id if ver > 1 else None
                        data_obj: dict[str, Any] = {
                            "kind": eff_kind,
                            "accountId": "ACCT-PROBE",
                            "entryId": eff_entry_id,
                            "status": eff_status,
                            "clearingStage": eff_stage,
                            "memo": memo,
                        }
                        if ref is not None:
                            data_obj["reference"] = ref
                        if debit is not None:
                            data_obj["debitParty"] = debit
                        if credit is not None:
                            data_obj["creditParty"] = credit
                        if extra_data:
                            data_obj.update(extra_data)
                        env_obj: dict[str, Any] = {
                            "schemaVersion": "1.0",
                            "eventId": eid,
                            "eventType": etype,
                            "aggregateType": "settlement",
                            "aggregateId": sid,
                            "aggregateVersion": ver,
                            "occurredAt": occurred_at,
                            "correlationId": corr,
                            "idempotencyKey": idem,
                            "data": data_obj,
                        }
                        if extra_top:
                            env_obj.update(extra_top)
                        return json.dumps(env_obj)

                    _assert_pg_rejects(
                        "settlements.debit_party <> credit_party",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-SAME', 'BANK-SAME', 'INITIATED', 'INIT', 1, 0)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "settlements.non-empty trimmed text fields",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count
                        ) VALUES (%s, '   ', 'REF-PROBE', 'BANK-A', 'BANK-B', 'INITIATED', 'INIT', 1, 0)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "settlements.max length bounds on text fields (account_id <= 64, last_memo <= 256)",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, last_memo, version, entry_count
                        ) VALUES (%s, %s, 'REF-PROBE', 'BANK-A', 'BANK-B', 'INITIATED', 'INIT', %s, 1, 0)
                        """,
                        (str(uuid.uuid4()), "A" * 70, "M" * 300),
                    )
                    _assert_pg_rejects(
                        "settlements.updated_at >= created_at",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count, created_at, updated_at
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'INITIATED', 'INIT', 1, 0,
                                  '2026-01-02T00:00:00Z'::timestamptz, '2026-01-01T00:00:00Z'::timestamptz)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "settlements.version = 1 requires updated_at = created_at",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count, created_at, updated_at
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'INITIATED', 'INIT', 1, 0,
                                  '2026-01-01T00:00:00Z'::timestamptz, '2026-01-01T00:01:00Z'::timestamptz)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "settlements.version >= 1",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'INITIATED', 'INIT', 0, 0)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "settlements.entry_count = version - 1",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, last_entry_id, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'VALIDATED', 'VAL', %s, 2, 0)
                        """,
                        (str(uuid.uuid4()), str(uuid.uuid4())),
                    )
                    _assert_pg_rejects(
                        "settlements.current_status enum check",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'BOGUS_STATUS', 'INIT', 1, 0)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "settlements.version = 1 requires current_status = INITIATED and last_entry_id IS NULL",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'VALIDATED', 'INIT', 1, 0)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "settlements.version > 1 requires last_entry_id IS NOT NULL and current_status <> INITIATED",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, last_entry_id, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'VALIDATED', 'VAL', NULL, 2, 1)
                        """,
                        (str(uuid.uuid4()),),
                    )

                    cur.execute(
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count, created_at, updated_at
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'INITIATED', 'INIT', 1, 0,
                                  '2026-01-01T00:00:00Z'::timestamptz, '2026-01-01T00:00:00Z'::timestamptz)
                        """,
                        (probe_sid,),
                    )
                    valid_evt_1 = _make_event_payload(
                        probe_eid, probe_sid, 1, "SettlementInitiated", status="INITIATED", stage="INIT", idem="idem-probe-1"
                    )
                    cur.execute(
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 1, 'SettlementInitiated', 'corr-probe', 'idem-probe-1', %s::timestamptz, %s::jsonb)
                        """,
                        (probe_eid, probe_sid, probe_ts, valid_evt_1),
                    )

                    cur.execute(
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, last_entry_id, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', 'BANK-A', 'BANK-B', 'SETTLED', 'STL-1', %s, 2, 1)
                        """,
                        (settled_probe_sid, str(uuid.uuid4())),
                    )

                    _assert_pg_rejects(
                        "settlements trigger: immutable header columns on UPDATE",
                        """
                        UPDATE clearledger.settlements
                        SET debit_party = 'BANK-MUTATED',
                            current_status = 'VALIDATED',
                            current_stage = 'VAL',
                            last_entry_id = %s,
                            version = 2,
                            entry_count = 1
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), probe_sid),
                    )
                    _assert_pg_rejects(
                        "settlements trigger: single-step version progression (NEW.version = OLD.version + 1)",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'VALIDATED',
                            current_stage = 'VAL',
                            last_entry_id = %s,
                            version = 3,
                            entry_count = 2
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), probe_sid),
                    )

                    # Advance probe_sid to version=2 (CLEARED) and insert matching v2 event
                    cur.execute(
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'CLEARED',
                            current_stage = 'CLR-1',
                            last_entry_id = %s,
                            version = 2,
                            entry_count = 1,
                            updated_at = '2026-01-01T00:01:00Z'::timestamptz
                        WHERE settlement_id = %s
                        """,
                        (probe_entry_2, probe_sid),
                    )
                    valid_evt_2 = _make_event_payload(
                        probe_eid_2,
                        probe_sid,
                        2,
                        "LedgerEntryRecorded",
                        status="CLEARED",
                        stage="CLR-1",
                        entry_id=probe_entry_2,
                        idem="idem-probe-2-ok",
                        occurred_at=probe_ts_v2,
                    )
                    cur.execute(
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 2, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-2-ok', %s::timestamptz, %s::jsonb)
                        """,
                        (probe_eid_2, probe_sid, probe_ts_v2, valid_evt_2),
                    )

                    _assert_pg_rejects(
                        "settlements trigger: NEW.updated_at >= OLD.updated_at",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'SETTLED',
                            current_stage = 'STL-TS',
                            last_entry_id = %s,
                            version = 3,
                            entry_count = 2,
                            updated_at = '2026-01-01T00:00:30Z'::timestamptz
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), probe_sid),
                    )
                    _assert_pg_rejects(
                        "settlements trigger: NEW.last_entry_id IS DISTINCT FROM OLD.last_entry_id",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'SETTLED',
                            current_stage = 'STL-SAME-ENTRY',
                            last_entry_id = %s,
                            version = 3,
                            entry_count = 2
                        WHERE settlement_id = %s
                        """,
                        (probe_entry_2, probe_sid),
                    )

                    # Verify per-settlement unique entryId across non-adjacent LedgerEntryRecorded events (v2 vs v4)
                    cur.execute("SAVEPOINT sp_dup_entry_probe")
                    try:
                        probe_entry_3 = str(uuid.uuid4())
                        probe_eid_3 = str(uuid.uuid4())
                        cur.execute(
                            """
                            UPDATE clearledger.settlements
                            SET current_status = 'CLEARED',
                                current_stage = 'CLR-2',
                                last_entry_id = %s,
                                version = 3,
                                entry_count = 2,
                                updated_at = '2026-01-01T00:01:00Z'::timestamptz
                            WHERE settlement_id = %s
                            """,
                            (probe_entry_3, probe_sid),
                        )
                        cur.execute(
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-3-ok', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                probe_eid_3,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    probe_eid_3,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="CLEARED",
                                    stage="CLR-2",
                                    entry_id=probe_entry_3,
                                    idem="idem-probe-3-ok",
                                    occurred_at=probe_ts_v2,
                                ),
                            ),
                        )
                        cur.execute(
                            """
                            UPDATE clearledger.settlements
                            SET current_status = 'SETTLED',
                                current_stage = 'STL-DUP',
                                last_entry_id = %s,
                                version = 4,
                                entry_count = 3,
                                updated_at = '2026-01-01T00:01:00Z'::timestamptz
                            WHERE settlement_id = %s
                            """,
                            (probe_entry_2, probe_sid),
                        )
                        dup_entry_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events trigger: per-settlement unique entryId across LedgerEntryRecorded events",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 4, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-dup-entry', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                dup_entry_eid,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    dup_entry_eid,
                                    probe_sid,
                                    4,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-DUP",
                                    entry_id=probe_entry_2,
                                    idem="idem-probe-dup-entry",
                                    occurred_at=probe_ts_v2,
                                ),
                            ),
                        )
                    finally:
                        cur.execute("ROLLBACK TO SAVEPOINT sp_dup_entry_probe")
                        cur.execute("RELEASE SAVEPOINT sp_dup_entry_probe")

                    cur.execute("SAVEPOINT sp_parent_hdr_probe")
                    try:
                        hdr_entry_3 = str(uuid.uuid4())
                        cur.execute(
                            """
                            UPDATE clearledger.settlements
                            SET current_status = 'SETTLED',
                                current_stage = 'STL-HDR',
                                last_entry_id = %s,
                                last_memo = 'Expected parent memo',
                                version = 3,
                                entry_count = 2,
                                updated_at = '2026-01-01T00:01:00Z'::timestamptz
                            WHERE settlement_id = %s
                            """,
                            (hdr_entry_3, probe_sid),
                        )
                        hdr_mismatch_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events trigger: event payload debitParty/creditParty/reference must match parent settlement",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-hdr-mismatch', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                hdr_mismatch_eid,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    hdr_mismatch_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    debit="BANK-TAMPERED",
                                    memo="Expected parent memo",
                                    idem="idem-probe-hdr-mismatch",
                                    occurred_at=probe_ts_v2,
                                ),
                            ),
                        )
                        missing_ref_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events.payload data.reference/debitParty/creditParty required on LedgerEntryRecorded",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-no-ref', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                missing_ref_eid,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    missing_ref_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    ref=None,
                                    memo="Expected parent memo",
                                    idem="idem-probe-no-ref",
                                    occurred_at=probe_ts_v2,
                                ),
                            ),
                        )
                        memo_mismatch_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events trigger: event payload data.memo must match parent settlement last_memo",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-memo-mismatch', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                memo_mismatch_eid,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    memo_mismatch_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    memo="Tampered event memo",
                                    idem="idem-probe-memo-mismatch",
                                    occurred_at=probe_ts_v2,
                                ),
                            ),
                        )
                        dup_idem_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events: UNIQUE (settlement_id, idempotency_key)",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-1', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                dup_idem_eid,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    dup_idem_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    memo="Expected parent memo",
                                    idem="idem-probe-1",
                                    occurred_at=probe_ts_v2,
                                ),
                            ),
                        )
                        ts_mismatch_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events: payload.occurredAt must equal occurred_at column",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-ts-mismatch',
                                      '2026-01-02T00:00:00Z'::timestamptz, %s::jsonb)
                            """,
                            (
                                ts_mismatch_eid,
                                probe_sid,
                                _make_event_payload(
                                    ts_mismatch_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    memo="Expected parent memo",
                                    idem="idem-probe-ts-mismatch",
                                    occurred_at=probe_ts_v2,
                                ),
                            ),
                        )
                        parent_ts_mismatch_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events trigger: occurred_at must equal parent settlement updated_at",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-parent-ts',
                                      '2026-01-01T00:05:00Z'::timestamptz, %s::jsonb)
                            """,
                            (
                                parent_ts_mismatch_eid,
                                probe_sid,
                                _make_event_payload(
                                    parent_ts_mismatch_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    memo="Expected parent memo",
                                    idem="idem-probe-parent-ts",
                                    occurred_at="2026-01-01T00:05:00Z",
                                ),
                            ),
                        )
                        extra_top_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events.payload additionalProperties: false on top-level envelope",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-extra-top', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                extra_top_eid,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    extra_top_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    memo="Expected parent memo",
                                    idem="idem-probe-extra-top",
                                    occurred_at=probe_ts_v2,
                                    extra_top={"unexpectedField": "forbidden"},
                                ),
                            ),
                        )
                        extra_data_eid = str(uuid.uuid4())
                        _assert_pg_rejects(
                            "events.payload additionalProperties: false on nested data object",
                            """
                            INSERT INTO clearledger.events (
                                event_id, settlement_id, aggregate_version, event_type,
                                correlation_id, idempotency_key, occurred_at, payload
                            ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-extra-data', %s::timestamptz, %s::jsonb)
                            """,
                            (
                                extra_data_eid,
                                probe_sid,
                                probe_ts_v2,
                                _make_event_payload(
                                    extra_data_eid,
                                    probe_sid,
                                    3,
                                    "LedgerEntryRecorded",
                                    status="SETTLED",
                                    stage="STL-HDR",
                                    entry_id=hdr_entry_3,
                                    memo="Expected parent memo",
                                    idem="idem-probe-extra-data",
                                    occurred_at=probe_ts_v2,
                                    extra_data={"unexpectedDataField": "forbidden"},
                                ),
                            ),
                        )
                    finally:
                        cur.execute("ROLLBACK TO SAVEPOINT sp_parent_hdr_probe")
                        cur.execute("RELEASE SAVEPOINT sp_parent_hdr_probe")

                    _assert_pg_rejects(
                        "settlements trigger: CLEARED cannot regress backward to RESERVED or VALIDATED",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'RESERVED',
                            current_stage = 'REGRESSED-RSV',
                            last_entry_id = %s,
                            version = 3,
                            entry_count = 2
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), probe_sid),
                    )
                    _assert_pg_rejects(
                        "settlements trigger: SETTLED cannot regress to VALIDATED or CLEARED",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'CLEARED',
                            current_stage = 'REGRESSED',
                            last_entry_id = %s,
                            version = 3,
                            entry_count = 2
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), settled_probe_sid),
                    )
                    cur.execute(
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'DISPUTED',
                            current_stage = 'DISP-1',
                            last_entry_id = %s,
                            version = 3,
                            entry_count = 2
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), settled_probe_sid),
                    )
                    _assert_pg_rejects(
                        "settlements trigger: DISPUTED can only remain DISPUTED or resolve to RECONCILED",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'CLEARED',
                            current_stage = 'REGRESSED-FROM-DISP',
                            last_entry_id = %s,
                            version = 4,
                            entry_count = 3
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), settled_probe_sid),
                    )
                    cur.execute(
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'RECONCILED',
                            current_stage = 'RECON-2',
                            last_entry_id = %s,
                            version = 4,
                            entry_count = 3
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), settled_probe_sid),
                    )
                    _assert_pg_rejects(
                        "settlements trigger: RECONCILED is terminal and cannot transition to DISPUTED or SETTLED",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'DISPUTED',
                            current_stage = 'REGRESSED-DISP',
                            last_entry_id = %s,
                            version = 5,
                            entry_count = 4
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), settled_probe_sid),
                    )
                    _assert_pg_rejects(
                        "settlements trigger: RECONCILED is strictly terminal and rejects even same-status RECONCILED -> RECONCILED updates",
                        """
                        UPDATE clearledger.settlements
                        SET current_status = 'RECONCILED',
                            current_stage = 'RECON-REPEAT',
                            last_entry_id = %s,
                            version = 5,
                            entry_count = 4
                        WHERE settlement_id = %s
                        """,
                        (str(uuid.uuid4()), settled_probe_sid),
                    )

                    bad_ver_eid = str(uuid.uuid4())
                    _assert_pg_rejects(
                        "events.aggregate_version >= 1",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 0, 'SettlementInitiated', 'corr-probe', 'idem-probe-0', %s::timestamptz, %s::jsonb)
                        """,
                        (bad_ver_eid, probe_sid, probe_ts, _make_event_payload(bad_ver_eid, probe_sid, 0, "SettlementInitiated")),
                    )
                    bad_type_eid = str(uuid.uuid4())
                    _assert_pg_rejects(
                        "events.event_type enum check",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 3, 'BogusEventType', 'corr-probe', 'idem-probe-bogus', %s::timestamptz, %s::jsonb)
                        """,
                        (
                            bad_type_eid,
                            probe_sid,
                            probe_ts_v2,
                            _make_event_payload(
                                bad_type_eid,
                                probe_sid,
                                3,
                                "BogusEventType",
                                entry_id=str(uuid.uuid4()),
                                idem="idem-probe-bogus",
                                occurred_at=probe_ts_v2,
                            ),
                        ),
                    )
                    bad_si_eid = str(uuid.uuid4())
                    _assert_pg_rejects(
                        "events.SettlementInitiated requires aggregate_version = 1",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 3, 'SettlementInitiated', 'corr-probe', 'idem-probe-si3', %s::timestamptz, %s::jsonb)
                        """,
                        (
                            bad_si_eid,
                            probe_sid,
                            probe_ts_v2,
                            _make_event_payload(
                                bad_si_eid, probe_sid, 3, "SettlementInitiated", idem="idem-probe-si3", occurred_at=probe_ts_v2
                            ),
                        ),
                    )
                    bad_le_eid = str(uuid.uuid4())
                    _assert_pg_rejects(
                        "events.LedgerEntryRecorded requires aggregate_version >= 2",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 1, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-le1', %s::timestamptz, %s::jsonb)
                        """,
                        (
                            bad_le_eid,
                            settled_probe_sid,
                            probe_ts,
                            _make_event_payload(
                                bad_le_eid,
                                settled_probe_sid,
                                1,
                                "LedgerEntryRecorded",
                                status="SETTLED",
                                stage="STL-1",
                                entry_id=str(uuid.uuid4()),
                                idem="idem-probe-le1",
                            ),
                        ),
                    )
                    bad_json_eid = str(uuid.uuid4())
                    _assert_pg_rejects(
                        "events.payload JSONB envelope coherence with columns",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-bad-json', %s::timestamptz, %s::jsonb)
                        """,
                        (
                            bad_json_eid,
                            probe_sid,
                            probe_ts_v2,
                            _make_event_payload(
                                bad_json_eid,
                                probe_sid,
                                3,
                                "LedgerEntryRecorded",
                                corr="mismatched-corr",
                                entry_id=str(uuid.uuid4()),
                                idem="idem-probe-bad-json",
                                occurred_at=probe_ts_v2,
                            ),
                        ),
                    )
                    bad_nested_eid = str(uuid.uuid4())
                    _assert_pg_rejects(
                        "events.payload nested data.kind and data.entryId coherence",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-bad-data', %s::timestamptz, %s::jsonb)
                        """,
                        (
                            bad_nested_eid,
                            probe_sid,
                            probe_ts_v2,
                            _make_event_payload(
                                bad_nested_eid,
                                probe_sid,
                                3,
                                "LedgerEntryRecorded",
                                kind="settlementInitiated",
                                entry_id=None,
                                idem="idem-probe-bad-data",
                                occurred_at=probe_ts_v2,
                            ),
                        ),
                    )
                    unupdated_parent_eid = str(uuid.uuid4())
                    _assert_pg_rejects(
                        "events trigger: parent settlement version/state must match inserted event",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-parent-mismatch', %s::timestamptz, %s::jsonb)
                        """,
                        (
                            unupdated_parent_eid,
                            probe_sid,
                            probe_ts_v2,
                            _make_event_payload(
                                unupdated_parent_eid,
                                probe_sid,
                                3,
                                "LedgerEntryRecorded",
                                status="SETTLED",
                                stage="STL-3",
                                entry_id=str(uuid.uuid4()),
                                idem="idem-probe-parent-mismatch",
                                occurred_at=probe_ts_v2,
                            ),
                        ),
                    )
                    _assert_pg_rejects(
                        "events.payload JSONB object type check",
                        """
                        INSERT INTO clearledger.events (
                            event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at, payload
                        ) VALUES (%s, %s, 3, 'LedgerEntryRecorded', 'corr-probe', 'idem-probe-arr-json', %s::timestamptz, '[]'::jsonb)
                        """,
                        (str(uuid.uuid4()), probe_sid, probe_ts_v2),
                    )
                    _assert_pg_rejects(
                        "events trigger: append-only immutability forbids UPDATE",
                        """
                        UPDATE clearledger.events SET correlation_id = 'mutated-corr' WHERE event_id = %s
                        """,
                        (probe_eid,),
                    )
                    _assert_pg_rejects(
                        "events trigger: append-only immutability forbids DELETE",
                        """
                        DELETE FROM clearledger.events WHERE event_id = %s
                        """,
                        (probe_eid_2,),
                    )

                    valid_idem_hash = "a" * 64
                    valid_create_body = json.dumps(
                        {
                            "settlementId": probe_sid,
                            "eventId": probe_eid,
                            "version": 1,
                            "accepted": True,
                            "idempotentReplay": False,
                        }
                    )
                    valid_entry_body = json.dumps(
                        {
                            "settlementId": probe_sid,
                            "eventId": probe_eid_2,
                            "version": 2,
                            "accepted": True,
                            "idempotentReplay": False,
                        }
                    )

                    _assert_pg_rejects(
                        "idempotency_keys trigger: eventId must exist in clearledger.outbox as well as clearledger.events",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (f"create:{probe_sid}", valid_idem_hash, valid_create_body),
                    )

                    _assert_pg_rejects(
                        "outbox.event_id foreign key to events(event_id)",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb)
                        """,
                        (orphan_eid, probe_sid, _make_event_payload(orphan_eid, probe_sid, 1)),
                    )
                    _assert_pg_rejects(
                        "outbox.(settlement_id, aggregate_version) composite foreign key to events",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload
                        ) VALUES (%s, %s, 99, 'corr-probe', %s::jsonb)
                        """,
                        (
                            probe_eid_2,
                            probe_sid,
                            _make_event_payload(
                                probe_eid_2,
                                probe_sid,
                                99,
                                "LedgerEntryRecorded",
                                entry_id=probe_entry_2,
                                idem="idem-probe-2-ok",
                                occurred_at=probe_ts_v2,
                            ),
                        ),
                    )
                    _assert_pg_rejects(
                        "outbox trigger: per-settlement contiguous aggregate_version starting at 1",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload
                        ) VALUES (%s, %s, 2, 'corr-probe', %s::jsonb)
                        """,
                        (probe_eid_2, probe_sid, valid_evt_2),
                    )
                    _assert_pg_rejects(
                        "outbox.payload JSONB envelope coherence with columns",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb)
                        """,
                        (
                            probe_eid,
                            probe_sid,
                            _make_event_payload(probe_eid, probe_sid, 1, "SettlementInitiated", corr="mismatched-corr"),
                        ),
                    )
                    _assert_pg_rejects(
                        "outbox trigger: payload must exactly match referenced clearledger.events row",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb)
                        """,
                        (
                            probe_eid,
                            probe_sid,
                            _make_event_payload(
                                probe_eid, probe_sid, 1, "SettlementInitiated", stage="TAMPERED-OUTBOX-STAGE", idem="idem-probe-1"
                            ),
                        ),
                    )
                    _assert_pg_rejects(
                        "outbox.attempts >= 0",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload, attempts
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb, -1)
                        """,
                        (probe_eid, probe_sid, valid_evt_1),
                    )
                    _assert_pg_rejects(
                        "outbox.published_at requires attempts >= 1 and last_error IS NULL",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload, published_at, attempts
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb, NOW(), 0)
                        """,
                        (probe_eid, probe_sid, valid_evt_1),
                    )
                    _assert_pg_rejects(
                        "outbox.published_at requires last_error IS NULL",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload, published_at, attempts, last_error
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb, NOW(), 1, 'stale error')
                        """,
                        (probe_eid, probe_sid, valid_evt_1),
                    )
                    _assert_pg_rejects(
                        "outbox.published_at >= created_at check",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload, created_at, published_at, attempts
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb,
                                  '2026-01-02T00:00:00Z'::timestamptz, '2026-01-01T00:00:00Z'::timestamptz, 1)
                        """,
                        (probe_eid, probe_sid, valid_evt_1),
                    )
                    _assert_pg_rejects(
                        "outbox.archived_at requires published_at IS NOT NULL",
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload, published_at, archived_at, attempts
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb, NULL, NOW(), 0)
                        """,
                        (probe_eid, probe_sid, valid_evt_1),
                    )

                    cur.execute(
                        """
                        INSERT INTO clearledger.outbox (
                            event_id, settlement_id, aggregate_version, correlation_id, payload, attempts
                        ) VALUES (%s, %s, 1, 'corr-probe', %s::jsonb, 2)
                        """,
                        (probe_eid, probe_sid, valid_evt_1),
                    )
                    _assert_pg_rejects(
                        "outbox trigger: forbid DELETE on transactional outbox",
                        """
                        DELETE FROM clearledger.outbox WHERE event_id = %s
                        """,
                        (probe_eid,),
                    )
                    _assert_pg_rejects(
                        "outbox trigger: forbid mutating envelope columns on UPDATE",
                        """
                        UPDATE clearledger.outbox SET correlation_id = 'mutated-corr' WHERE event_id = %s
                        """,
                        (probe_eid,),
                    )
                    _assert_pg_rejects(
                        "outbox trigger: forbid decrementing attempts on UPDATE",
                        """
                        UPDATE clearledger.outbox SET attempts = 1 WHERE event_id = %s
                        """,
                        (probe_eid,),
                    )
                    _assert_pg_rejects(
                        "outbox trigger: publishing an unpublished row requires incrementing attempts",
                        """
                        UPDATE clearledger.outbox SET published_at = NOW() WHERE event_id = %s
                        """,
                        (probe_eid,),
                    )
                    _assert_pg_rejects(
                        "outbox trigger: unpublished row cannot transition directly to archived in one UPDATE",
                        """
                        UPDATE clearledger.outbox SET published_at = NOW(), archived_at = NOW(), attempts = attempts + 1 WHERE event_id = %s
                        """,
                        (probe_eid,),
                    )
                    cur.execute("SAVEPOINT sp_outbox_pub_probe")
                    try:
                        cur.execute(
                            """
                            UPDATE clearledger.outbox
                            SET published_at = NOW(), attempts = attempts + 1, last_error = NULL
                            WHERE event_id = %s
                            """,
                            (probe_eid,),
                        )
                        _assert_pg_rejects(
                            "outbox.archived_at >= published_at check",
                            """
                            UPDATE clearledger.outbox
                            SET archived_at = published_at - interval '5 minutes'
                            WHERE event_id = %s
                            """,
                            (probe_eid,),
                        )
                        _assert_pg_rejects(
                            "outbox trigger: once published_at is set, published_at and attempts are immutable during archival",
                            """
                            UPDATE clearledger.outbox
                            SET archived_at = NOW(), attempts = attempts + 1
                            WHERE event_id = %s
                            """,
                            (probe_eid,),
                        )
                        cur.execute(
                            """
                            UPDATE clearledger.outbox
                            SET archived_at = published_at + interval '1 second'
                            WHERE event_id = %s
                            """,
                            (probe_eid,),
                        )
                        _assert_pg_rejects(
                            "outbox trigger: once archived_at is set, it cannot be mutated without resetting archived_at = NULL first",
                            """
                            UPDATE clearledger.outbox
                            SET archived_at = published_at + interval '10 seconds'
                            WHERE event_id = %s
                            """,
                            (probe_eid,),
                        )
                    finally:
                        cur.execute("ROLLBACK TO SAVEPOINT sp_outbox_pub_probe")
                        cur.execute("RELEASE SAVEPOINT sp_outbox_pub_probe")

                    _assert_pg_rejects(
                        "settlements.btrim(debit_party) <> btrim(credit_party)",
                        """
                        INSERT INTO clearledger.settlements (
                            settlement_id, account_id, reference, debit_party, credit_party,
                            current_status, current_stage, version, entry_count
                        ) VALUES (%s, 'ACCT-PROBE', 'REF-PROBE', '  BANK-SAME  ', 'BANK-SAME', 'INITIATED', 'INIT', 1, 0)
                        """,
                        (str(uuid.uuid4()),),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.scope format check (create:<uuid> or entry:<uuid>)",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES ('probe', 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (valid_idem_hash, valid_create_body),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.request_hash 64-char lowercase hex SHA-256 check",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (f"create:{probe_sid}", "A" * 64, valid_create_body),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.response_body idempotentReplay must be false on stored record",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (
                            f"create:{probe_sid}",
                            valid_idem_hash,
                            json.dumps(
                                {
                                    "settlementId": probe_sid,
                                    "eventId": probe_eid,
                                    "version": 1,
                                    "accepted": True,
                                    "idempotentReplay": True,
                                }
                            ),
                        ),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.status_code coupling for create scope (must be 201)",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 202, %s::jsonb)
                        """,
                        (f"create:{probe_sid}", valid_idem_hash, valid_create_body),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.status_code coupling for entry scope (must be 202)",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-2-ok', %s, 201, %s::jsonb)
                        """,
                        (f"entry:{probe_sid}", valid_idem_hash, valid_entry_body),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.idempotency_key length check (8..128)",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'short', %s, 201, %s::jsonb)
                        """,
                        (f"create:{probe_sid}", valid_idem_hash, valid_create_body),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.response_body JSON object and settlementId scope coherence",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (f"create:{settled_probe_sid}", valid_idem_hash, valid_create_body),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys.response_body additionalProperties: false (only 5 WriteAcceptedResponse keys allowed)",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (
                            f"create:{probe_sid}",
                            valid_idem_hash,
                            json.dumps(
                                {
                                    "settlementId": probe_sid,
                                    "eventId": probe_eid,
                                    "version": 1,
                                    "accepted": True,
                                    "idempotentReplay": False,
                                    "unexpectedField": "forbidden",
                                }
                            ),
                        ),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys trigger: eventId must exist in clearledger.events",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (
                            f"create:{probe_sid}",
                            valid_idem_hash,
                            json.dumps(
                                {
                                    "settlementId": probe_sid,
                                    "eventId": orphan_eid,
                                    "version": 1,
                                    "accepted": True,
                                    "idempotentReplay": False,
                                }
                            ),
                        ),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys trigger: idempotency_key must match referenced clearledger.events row",
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-mismatched', %s, 201, %s::jsonb)
                        """,
                        (f"create:{probe_sid}", valid_idem_hash, valid_create_body),
                    )
                    cur.execute(
                        """
                        INSERT INTO clearledger.idempotency_keys (
                            scope, idempotency_key, request_hash, status_code, response_body
                        ) VALUES (%s, 'idem-probe-1', %s, 201, %s::jsonb)
                        """,
                        (f"create:{probe_sid}", valid_idem_hash, valid_create_body),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys trigger: append-only immutability forbids UPDATE",
                        """
                        UPDATE clearledger.idempotency_keys
                        SET request_hash = %s
                        WHERE scope = %s AND idempotency_key = 'idem-probe-1'
                        """,
                        ("b" * 64, f"create:{probe_sid}"),
                    )
                    _assert_pg_rejects(
                        "idempotency_keys trigger: append-only immutability forbids DELETE",
                        """
                        DELETE FROM clearledger.idempotency_keys
                        WHERE scope = %s AND idempotency_key = 'idem-probe-1'
                        """,
                        (f"create:{probe_sid}",),
                    )
                finally:
                    cur.execute("ROLLBACK TO SAVEPOINT sp_outer_probe")
                    cur.execute("RELEASE SAVEPOINT sp_outer_probe")

        msg_kms_arn = m["kms"]["messaging_arn"]
        msg_kms_ids = {msg_kms_arn, msg_kms_arn.rsplit("/", 1)[-1]}
        q_attrs = sqs.get_queue_attributes(
            QueueUrl=m["messaging"]["queue_url"],
            AttributeNames=["All"],
        )["Attributes"]
        dlq_attrs = sqs.get_queue_attributes(
            QueueUrl=m["messaging"]["dlq_url"],
            AttributeNames=["All"],
        )["Attributes"]
        assert int(q_attrs.get("VisibilityTimeout", 0)) == 3
        assert int(q_attrs.get("ReceiveMessageWaitTimeSeconds", 0)) == 2
        assert int(q_attrs.get("MessageRetentionPeriod", 0)) == 172800
        assert int(dlq_attrs.get("MessageRetentionPeriod", 0)) == 1209600
        assert q_attrs.get("KmsMasterKeyId") in msg_kms_ids, (
            f"Live main SQS queue KmsMasterKeyId ({q_attrs.get('KmsMasterKeyId')}) does not match messaging KMS key"
        )
        assert dlq_attrs.get("KmsMasterKeyId") in msg_kms_ids, (
            f"Live DLQ KmsMasterKeyId ({dlq_attrs.get('KmsMasterKeyId')}) does not match messaging KMS key"
        )
        redrive = json.loads(q_attrs.get("RedrivePolicy", "{}"))
        assert redrive.get("deadLetterTargetArn") == dlq_attrs.get("QueueArn")
        assert int(redrive.get("maxReceiveCount", 0)) == 4

        worker_roles = (
            ("projector", "projector_role_arn"),
            ("outbox_relay", "relay_role_arn"),
            ("audit_archiver", "archiver_role_arn"),
        )
        for wkey, rkey in worker_roles:
            fn_name = m["workers"][wkey]["function_name"]
            fn_cfg = lam.get_function_configuration(FunctionName=fn_name)
            assert fn_cfg["PackageType"] == "Image"
            assert fn_cfg.get("Role") == m["iam"][rkey], (
                f"Live Lambda {fn_name} Role ({fn_cfg.get('Role')}) does not match {m['iam'][rkey]}"
            )

        relay_cfg = lam.get_function_configuration(
            FunctionName=m["workers"]["outbox_relay"]["function_name"]
        )
        assert (relay_cfg.get("Environment", {}).get("Variables") or {}).get("OUTBOX_BATCH_SIZE") == "50"

        archiver_cfg = lam.get_function_configuration(
            FunctionName=m["workers"]["audit_archiver"]["function_name"]
        )
        assert (archiver_cfg.get("Environment", {}).get("Variables") or {}).get("AUDIT_PREFIX") == "ledger-audit/"

        esm = lam.get_event_source_mapping(UUID=m["messaging"]["event_source_mapping_uuid"])
        assert esm["EventSourceArn"] == m["messaging"]["queue_arn"]
        assert esm["State"] in {"Enabled", "Enabling", "Updating"}
        assert int(esm.get("BatchSize", 0)) == 5
        assert "ReportBatchItemFailures" in (esm.get("FunctionResponseTypes") or [])

        for skey, expected_fn, expected_rate in (
            ("outbox_schedule_name", m["workers"]["outbox_relay"]["function_arn"], "rate(1 minute)"),
            ("archive_schedule_name", m["workers"]["audit_archiver"]["function_arn"], "rate(5 minutes)"),
        ):
            sched = scheduler.get_schedule(Name=m["schedules"][skey])
            assert sched["State"] == "ENABLED"
            assert sched.get("ScheduleExpression") == expected_rate
            assert sched["Target"]["Arn"] == expected_fn
            assert sched["Target"]["RoleArn"] == m["iam"]["scheduler_role_arn"]

        tbl = ddb.describe_table(TableName=m["projections"]["table_name"])["Table"]
        assert tbl["TableStatus"] == "ACTIVE"
        key_schema = {k["AttributeName"]: k["KeyType"] for k in tbl["KeySchema"]}
        assert key_schema == {"PK": "HASH", "SK": "RANGE"}
        gsis = tbl.get("GlobalSecondaryIndexes") or []
        assert any(g.get("IndexName") == "AccountIndex" for g in gsis)
        pitr = ddb.describe_continuous_backups(TableName=m["projections"]["table_name"])[
            "ContinuousBackupsDescription"
        ]
        pitr_status = (pitr.get("PointInTimeRecoveryDescription") or {}).get("PointInTimeRecoveryStatus")
        assert pitr.get("ContinuousBackupsStatus") == "ENABLED" and pitr_status in {"ENABLED", None}, (
            f"Live DynamoDB PITR must be ENABLED, got {pitr}"
        )

        rep_groups = ec.describe_replication_groups(
            ReplicationGroupId=m["cache"]["cluster_id"],
        ).get("ReplicationGroups", [])
        if rep_groups:
            assert len(rep_groups) == 1
            assert str(rep_groups[0].get("Status", "available")).lower() in {"available", "creating", "modifying"}
        else:
            clusters = ec.describe_cache_clusters(
                CacheClusterId=m["cache"]["cluster_id"],
                ShowCacheNodeInfo=True,
            )["CacheClusters"]
            assert len(clusters) == 1
            assert clusters[0].get("Engine", "valkey").lower() in {"valkey", "redis"}

        ver = s3.get_bucket_versioning(Bucket=m["audit"]["bucket_name"])
        assert ver.get("Status") == "Enabled"

        audit_kms_arn = m["kms"]["audit_arn"]
        audit_kms_ids = {audit_kms_arn, audit_kms_arn.rsplit("/", 1)[-1]}
        enc = s3.get_bucket_encryption(Bucket=m["audit"]["bucket_name"])
        rules = enc.get("ServerSideEncryptionConfiguration", {}).get("Rules", [])
        assert rules, "Live S3 bucket encryption has no rules"
        default_sse = rules[0].get("ApplyServerSideEncryptionByDefault", {})
        assert default_sse.get("SSEAlgorithm") == "aws:kms", (
            f"Live S3 bucket must use SSEAlgorithm='aws:kms', got {default_sse.get('SSEAlgorithm')}"
        )
        assert default_sse.get("KMSMasterKeyID") in audit_kms_ids, (
            f"Live S3 bucket KMSMasterKeyID ({default_sse.get('KMSMasterKeyID')}) does not match audit KMS key"
        )

        pab = s3.get_public_access_block(Bucket=m["audit"]["bucket_name"])["PublicAccessBlockConfiguration"]
        assert all(
            pab.get(k) is True
            for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")
        )

        return "Live RDS, SQS+DLQ KMS, 3 Lambdas, Scheduler, DynamoDB (AccountIndex+PITR), Valkey, and S3 KMS verified"

    _run_block(ctx, "live.data_event_graph", _check)


def test_live_security(ctx: VerifierContext) -> None:
    """Scored block: Live security graph (5 points) — live.security."""
    def _check() -> str:
        m = ctx.manifest
        iam = boto_client("iam", ctx.config)
        kms = boto_client("kms", ctx.config)
        cognito = boto_client("cognito-idp", ctx.config)
        logs = boto_client("logs", ctx.config)

        found_groups = {
            lg["logGroupName"]: lg
            for lg in logs.describe_log_groups().get("logGroups", [])
        }
        for lg_name in m["logs"].values():
            assert lg_name in found_groups, f"Live CloudWatch log group {lg_name} missing"
            ret = found_groups[lg_name].get("retentionInDays")
            assert ret is not None and int(ret) >= 14, (
                f"Live CloudWatch log group {lg_name} retentionInDays must be >= 14, got {ret}"
            )
        log_group_arns = {name: str(lg.get("arn") or "") for name, lg in found_groups.items()}

        role_trust_docs: dict[str, Any] = {}
        role_policy_docs: dict[str, list[dict[str, Any]]] = {}
        for arn in m["iam"].values():
            rname = arn.split("/")[-1]
            role = iam.get_role(RoleName=rname)["Role"]
            assert role["Arn"] == arn
            role_trust_docs[arn] = role.get("AssumeRolePolicyDocument")

            docs: list[dict[str, Any]] = []
            for pol_name in iam.list_role_policies(RoleName=rname).get("PolicyNames", []):
                pol_resp = iam.get_role_policy(RoleName=rname, PolicyName=pol_name)
                docs.append(pol_resp.get("PolicyDocument"))
            for att in iam.list_attached_role_policies(RoleName=rname).get("AttachedPolicies", []):
                pol_arn = att.get("PolicyArn")
                if pol_arn:
                    pmeta = iam.get_policy(PolicyArn=pol_arn)["Policy"]
                    pver = iam.get_policy_version(
                        PolicyArn=pol_arn,
                        VersionId=pmeta["DefaultVersionId"],
                    )["PolicyVersion"]
                    docs.append(pver.get("Document"))
            assert docs, f"Live IAM role {rname} has no inline or attached policies"
            role_policy_docs[arn] = docs

        verify_iam_roles_and_policies(
            manifest=m,
            role_trust_docs=role_trust_docs,
            role_policy_docs=role_policy_docs,
            log_group_arns=log_group_arns,
            label="Live IAM",
        )

        # Also verify via live IAM policy simulation when supported by the endpoint
        sim_checks = [
            (m["iam"]["ecs_task_role_arn"], "sqs:SendMessage", m["messaging"]["queue_arn"], "allowed"),
            (m["iam"]["ecs_task_role_arn"], "dynamodb:PutItem", m["projections"]["table_arn"], "denied"),
            (m["iam"]["projector_role_arn"], "dynamodb:PutItem", m["projections"]["table_arn"], "allowed"),
            (m["iam"]["projector_role_arn"], "sqs:SendMessage", m["messaging"]["queue_arn"], "denied"),
            (m["iam"]["relay_role_arn"], "sqs:SendMessage", m["messaging"]["queue_arn"], "allowed"),
            (m["iam"]["relay_role_arn"], "dynamodb:PutItem", m["projections"]["table_arn"], "denied"),
            (
                m["iam"]["archiver_role_arn"],
                "s3:PutObject",
                f"{m['audit']['bucket_arn']}/{str(m['audit']['prefix']).lstrip('/')}probe.ndjson",
                "allowed",
            ),
            (m["iam"]["archiver_role_arn"], "sqs:SendMessage", m["messaging"]["queue_arn"], "denied"),
            (
                m["iam"]["scheduler_role_arn"],
                "lambda:InvokeFunction",
                m["workers"]["outbox_relay"]["function_arn"],
                "allowed",
            ),
            (
                m["iam"]["scheduler_role_arn"],
                "lambda:InvokeFunction",
                m["workers"]["projector"]["function_arn"],
                "denied",
            ),
            (m["iam"]["ecs_execution_role_arn"], "sqs:SendMessage", m["messaging"]["queue_arn"], "denied"),
        ]
        for role_arn, action, resource, expected in sim_checks:
            sim = iam.simulate_principal_policy(
                PolicySourceArn=role_arn,
                ActionNames=[action],
                ResourceArns=[resource],
            )
            eval_res = sim.get("EvaluationResults") or []
            if eval_res:
                decision = str(eval_res[0].get("EvalDecision", "")).lower()
                if expected == "allowed":
                    assert decision == "allowed", f"IAM simulation expected allowed for {role_arn} {action}, got {decision}"
                else:
                    assert decision in {"implicitdeny", "explicitdeny", "denied"}, (
                        f"IAM simulation expected deny for {role_arn} {action}, got {decision}"
                    )

        assert len(set(m["kms"].values())) == 4, "Expected 4 distinct live KMS key ARNs"
        live_key_ids_by_role: dict[str, str] = {}
        for role_label, k_arn in (
            ("database", m["kms"]["database_arn"]),
            ("messaging", m["kms"]["messaging_arn"]),
            ("projection", m["kms"]["projection_arn"]),
            ("audit", m["kms"]["audit_arn"]),
        ):
            meta = kms.describe_key(KeyId=k_arn)["KeyMetadata"]
            assert meta["Enabled"] is True and meta.get("KeyState") == "Enabled"
            rot = kms.get_key_rotation_status(KeyId=k_arn)
            assert rot.get("KeyRotationEnabled") is True, (
                f"Live KMS key {k_arn} must have KeyRotationEnabled=True, got {rot}"
            )
            live_key_ids_by_role[role_label] = str(meta["KeyId"])

        prefix = ctx.config["resource_prefix"]
        aliases = {
            str(a.get("AliasName", "")): str(a.get("TargetKeyId", ""))
            for a in kms.list_aliases().get("Aliases", [])
        }
        for role_label, expected_kid in live_key_ids_by_role.items():
            expected_alias = f"alias/{prefix}-{role_label}"
            assert aliases.get(expected_alias) == expected_kid, (
                f"Live KMS alias {expected_alias} must target {role_label} key {expected_kid}, got {aliases.get(expected_alias)}"
            )

        pool_id = m["auth"]["user_pool_id"]
        rs = cognito.describe_resource_server(
            UserPoolId=pool_id,
            Identifier=m["auth"]["resource_server_identifier"],
        )["ResourceServer"]
        scopes = {s["ScopeName"] for s in rs.get("Scopes", [])}
        assert scopes == {"read", "write", "admin"}

        for role_key, expected_scope in (
            ("read", "clearledger/read"),
            ("write", "clearledger/write"),
            ("admin", "clearledger/admin"),
        ):
            cid = m["auth"]["clients"][role_key]["client_id"]
            desc = cognito.describe_user_pool_client(UserPoolId=pool_id, ClientId=cid)["UserPoolClient"]
            assert desc.get("AllowedOAuthScopes") == [expected_scope]

        return "Live IAM trust & least-privilege policies, 4 KMS keys+rotation+aliases, Cognito scopes, and 4 log groups verified"

    _run_block(ctx, "live.security", _check)

