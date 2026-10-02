from __future__ import annotations

import json
import subprocess
from typing import Any

from .conftest import VerifierContext
from .helpers import INFRA_DIR, SUBMISSION_DIR, load_tfstate


def _collect_resources(state: dict[str, Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for res in state.get("resources", []):
        if res.get("mode") != "managed":
            continue
        rtype = res.get("type", "")
        rname = res.get("name", "")
        for inst in res.get("instances", []):
            attrs = inst.get("attributes", {}) or {}
            items.append({"type": rtype, "name": rname, "attributes": attrs})
    return items


def _by_type(items: list[dict[str, Any]], rtype: str) -> list[dict[str, Any]]:
    return [i["attributes"] for i in items if i["type"] == rtype]


def _run_block(ctx: VerifierContext, block_id: str, fn) -> None:
    try:
        detail = fn()
        ctx.recorder.record(block_id, True, detail or "passed")
    except Exception as err:  # noqa: BLE001
        ctx.recorder.record(block_id, False, str(err))
        raise


def test_iac_discipline(ctx: VerifierContext) -> None:
    """Scored block: Infrastructure managed with Terraform or OpenTofu (3 points) — declared.iac_discipline."""
    def _check() -> str:
        proc = subprocess.run(
            ["terraform", "validate", "-no-color"],
            cwd=str(INFRA_DIR),
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        assert proc.returncode == 0, f"terraform validate failed: {proc.stderr}"

        state = load_tfstate()
        items = _collect_resources(state)
        types_present = {i["type"] for i in items}
        required_types = {
            "aws_vpc",
            "aws_subnet",
            "aws_internet_gateway",
            "aws_route_table",
            "aws_security_group",
            "aws_lb",
            "aws_lb_target_group",
            "aws_lb_listener",
            "aws_ecs_cluster",
            "aws_ecs_task_definition",
            "aws_ecs_service",
            "aws_db_subnet_group",
            "aws_db_instance",
            "aws_dynamodb_table",
            "aws_elasticache_subnet_group",
            "aws_elasticache_cluster",
            "aws_s3_bucket",
            "aws_s3_bucket_versioning",
            "aws_s3_bucket_server_side_encryption_configuration",
            "aws_s3_bucket_public_access_block",
            "aws_sqs_queue",
            "aws_lambda_function",
            "aws_lambda_event_source_mapping",
            "aws_scheduler_schedule",
            "aws_cognito_user_pool",
            "aws_cognito_resource_server",
            "aws_cognito_user_pool_client",
            "aws_iam_role",
            "aws_iam_role_policy",
            "aws_kms_key",
            "aws_kms_alias",
            "aws_cloudwatch_log_group",
        }
        missing = sorted(required_types - types_present)
        assert not missing, f"Missing required Terraform resource types: {missing}"

        prefix = ctx.config["resource_prefix"]
        tagged_count = 0
        for item in items:
            tags = item["attributes"].get("tags") or item["attributes"].get("tags_all") or {}
            if isinstance(tags, dict) and tags.get("ClearLedgerDeployment") == prefix:
                tagged_count += 1
        assert tagged_count >= 25, f"Expected at least 25 resources tagged ClearLedgerDeployment={prefix}, found {tagged_count}"

        deploy_text = (SUBMISSION_DIR / "deploy.sh").read_text()
        forbidden_cli = [
            "aws sqs create-queue",
            "aws dynamodb create-table",
            "aws lambda create-function",
            "aws ecs create-service",
            "aws rds create-db-instance",
            "aws s3api create-bucket",
        ]
        for token in forbidden_cli:
            assert token not in deploy_text, f"Imperative resource creation '{token}' found in deploy.sh"

        return f"Validated {len(items)} managed resources across {len(types_present)} types"

    _run_block(ctx, "declared.iac_discipline", _check)


def test_declared_compute_and_ingress(ctx: VerifierContext) -> None:
    """Scored block: Declared compute and ingress (2 points) — declared.compute_ingress."""
    def _check() -> str:
        state = load_tfstate()
        items = _collect_resources(state)
        manifest = ctx.manifest

        vpcs = _by_type(items, "aws_vpc")
        assert len(vpcs) == 1, f"Expected 1 aws_vpc, found {len(vpcs)}"
        vpc = vpcs[0]
        assert vpc.get("enable_dns_support") is True
        assert vpc.get("enable_dns_hostnames") is True
        assert vpc["id"] == manifest["network"]["vpc_id"]

        subnets = _by_type(items, "aws_subnet")
        pub = [s for s in subnets if s.get("map_public_ip_on_launch") is True]
        priv = [s for s in subnets if not s.get("map_public_ip_on_launch")]
        assert len(pub) >= 2 and len({s.get("availability_zone") for s in pub}) >= 2
        assert len(priv) >= 2 and len({s.get("availability_zone") for s in priv}) >= 2

        sgs = {s["id"]: s for s in _by_type(items, "aws_security_group")}
        sg_ids = manifest["network"]["security_group_ids"]
        for key in ("alb", "ecs", "rds", "valkey"):
            assert sg_ids[key] in sgs, f"Security group {key} ({sg_ids[key]}) not in state"

        for restricted_key, port in (("ecs", 8080), ("rds", 5432), ("valkey", 6379)):
            sg = sgs[sg_ids[restricted_key]]
            for rule in sg.get("ingress", []) or []:
                cidrs = rule.get("cidr_blocks") or []
                if rule.get("from_port") == port:
                    assert "0.0.0.0/0" not in cidrs, f"{restricted_key} security group exposes port {port} to 0.0.0.0/0"

        lbs = _by_type(items, "aws_lb")
        assert len(lbs) == 1
        lb = lbs[0]
        assert lb.get("load_balancer_type") == "application"
        assert lb.get("internal") is False
        assert set(lb.get("subnets") or []) == set(manifest["network"]["public_subnet_ids"])

        tgs = _by_type(items, "aws_lb_target_group")
        assert len(tgs) == 1
        tg = tgs[0]
        assert int(tg.get("port", 0)) == 8080
        hc = (tg.get("health_check") or [{}])[0]
        assert hc.get("path") == "/health/ready"

        listeners = _by_type(items, "aws_lb_listener")
        assert len(listeners) == 1
        assert int(listeners[0].get("port", 0)) == 80

        services = _by_type(items, "aws_ecs_service")
        assert len(services) == 1
        svc = services[0]
        assert int(svc.get("desired_count", 0)) >= 2
        assert svc.get("launch_type") == "FARGATE"

        task_defs = _by_type(items, "aws_ecs_task_definition")
        assert len(task_defs) == 1
        td = task_defs[0]
        assert "FARGATE" in (td.get("requires_compatibilities") or [])
        assert td.get("network_mode") == "awsvpc"
        cdefs = json.loads(td.get("container_definitions") or "[]")
        assert len(cdefs) == 1
        cdef = cdefs[0]
        assert cdef["image"] == ctx.config["api_image"]
        env_map = {e["name"]: e["value"] for e in cdef.get("environment", [])}
        for req_env in (
            "DATABASE_URL",
            "SQS_QUEUE_URL",
            "PROJECTION_TABLE",
            "VALKEY_URL",
            "CACHE_TTL_SECONDS",
            "AUTH_ISSUER",
            "AUTH_AUDIENCES",
            "CLOUDWATCH_LOG_GROUP",
        ):
            assert env_map.get(req_env), f"Missing {req_env} in ECS container definition"
        assert env_map.get("CACHE_TTL_SECONDS") == "90", f"Expected CACHE_TTL_SECONDS=90, got {env_map.get('CACHE_TTL_SECONDS')}"

        return "VPC, ALB, and ECS Fargate declarations verified"

    _run_block(ctx, "declared.compute_ingress", _check)


def _load_hcl_text() -> str:
    files = sorted(list(INFRA_DIR.rglob("*.tf")) + list(INFRA_DIR.rglob("*.tofu")))
    return "\n".join(p.read_text(errors="ignore") for p in files)


def test_declared_data_and_async(ctx: VerifierContext) -> None:
    """Scored block: Declared data and messaging (2 points) — declared.data_async."""
    def _check() -> str:
        state = load_tfstate()
        items = _collect_resources(state)
        manifest = ctx.manifest
        hcl_text = _load_hcl_text()

        dbs = _by_type(items, "aws_db_instance")
        assert len(dbs) == 1
        db = dbs[0]
        assert db.get("engine") == "postgres"
        assert str(db.get("engine_version", "16")).startswith("16")
        assert db.get("instance_class") == "db.t4g.micro"
        assert db.get("storage_encrypted") is True or "storage_encrypted" in hcl_text
        assert db.get("publicly_accessible") is False
        assert db.get("kms_key_id") == manifest["kms"]["database_arn"] or "kms_key_id" in hcl_text

        queues = {q["name"]: q for q in _by_type(items, "aws_sqs_queue")}
        main_q = queues.get(manifest["messaging"]["queue_name"])
        dlq_q = queues.get(manifest["messaging"]["dlq_name"])
        assert main_q is not None and dlq_q is not None
        assert int(main_q.get("visibility_timeout_seconds", 0)) == 3
        assert int(main_q.get("receive_wait_time_seconds", 0)) == 2
        assert int(main_q.get("message_retention_seconds", 0)) == 172800
        assert int(dlq_q.get("message_retention_seconds", 0)) == 1209600
        assert main_q.get("kms_master_key_id") == manifest["kms"]["messaging_arn"] or "kms_master_key_id" in hcl_text
        assert dlq_q.get("kms_master_key_id") == manifest["kms"]["messaging_arn"] or "kms_master_key_id" in hcl_text
        redrive = json.loads(main_q.get("redrive_policy") or "{}")
        assert redrive.get("deadLetterTargetArn") == dlq_q.get("arn")
        assert int(redrive.get("maxReceiveCount", 0)) == 4

        lambdas = {fn["function_name"]: fn for fn in _by_type(items, "aws_lambda_function")}
        assert len(lambdas) == 3
        expected_images = {
            manifest["workers"]["projector"]["function_name"]: ctx.config["projector_image"],
            manifest["workers"]["outbox_relay"]["function_name"]: ctx.config["relay_image"],
            manifest["workers"]["audit_archiver"]["function_name"]: ctx.config["archiver_image"],
        }
        for fname, img in expected_images.items():
            fn = lambdas.get(fname)
            assert fn is not None, f"Lambda {fname} missing from state"
            assert fn.get("package_type") == "Image"
            assert fn.get("image_uri") == img

        relay_fn = lambdas[manifest["workers"]["outbox_relay"]["function_name"]]
        relay_env = ((relay_fn.get("environment") or [{}])[0]).get("variables") or {}
        assert relay_env.get("OUTBOX_BATCH_SIZE") == "50", f"Expected OUTBOX_BATCH_SIZE=50 on relay Lambda, got {relay_env.get('OUTBOX_BATCH_SIZE')}"

        archiver_fn = lambdas[manifest["workers"]["audit_archiver"]["function_name"]]
        archiver_env = ((archiver_fn.get("environment") or [{}])[0]).get("variables") or {}
        assert archiver_env.get("AUDIT_PREFIX") == "ledger-audit/", f"Expected AUDIT_PREFIX=ledger-audit/ on archiver Lambda, got {archiver_env.get('AUDIT_PREFIX')}"

        esms = _by_type(items, "aws_lambda_event_source_mapping")
        assert len(esms) == 1
        esm = esms[0]
        assert esm.get("enabled") is True
        assert int(esm.get("batch_size", 0)) == 5
        assert int(esm.get("maximum_batching_window_in_seconds", -1)) == 0
        assert "ReportBatchItemFailures" in (esm.get("function_response_types") or [])

        schedules = {s["name"]: s for s in _by_type(items, "aws_scheduler_schedule")}
        assert len(schedules) == 2
        outbox_sched = schedules.get(manifest["schedules"]["outbox_schedule_name"])
        arch_sched = schedules.get(manifest["schedules"]["archive_schedule_name"])
        assert outbox_sched is not None and arch_sched is not None
        assert outbox_sched.get("state") == "ENABLED"
        assert arch_sched.get("state") == "ENABLED"
        assert outbox_sched.get("schedule_expression") == "rate(1 minute)"
        assert arch_sched.get("schedule_expression") == "rate(5 minutes)"

        tables = _by_type(items, "aws_dynamodb_table")
        assert len(tables) == 1
        tbl = tables[0]
        assert tbl.get("name") == manifest["projections"]["table_name"]
        assert tbl.get("hash_key") == "PK"
        assert tbl.get("range_key") == "SK"
        gsis = tbl.get("global_secondary_index") or []
        assert any(
            g.get("name") == "AccountIndex"
            and g.get("hash_key") == "GSI1PK"
            and g.get("range_key") == "GSI1SK"
            and g.get("projection_type") == "ALL"
            for g in gsis
        ), "DynamoDB table missing required AccountIndex GSI (GSI1PK/GSI1SK)"
        pitr = (tbl.get("point_in_time_recovery") or [{}])[0]
        assert pitr.get("enabled") is True or "point_in_time_recovery" in hcl_text, "DynamoDB point_in_time_recovery must be enabled"
        sse = (tbl.get("server_side_encryption") or [{}])[0]
        assert sse.get("enabled") is True or "server_side_encryption" in hcl_text

        caches = _by_type(items, "aws_elasticache_cluster")
        assert len(caches) == 1
        cache = caches[0]
        assert str(cache.get("engine", "valkey")).lower() in {"valkey", "redis"}
        assert cache.get("node_type") == "cache.t4g.micro"
        assert int(cache.get("port", 6379)) > 0

        buckets = _by_type(items, "aws_s3_bucket")
        assert len(buckets) == 1
        assert buckets[0].get("bucket") == manifest["audit"]["bucket_name"]
        vers = _by_type(items, "aws_s3_bucket_versioning")
        assert len(vers) == 1
        vcfg = (vers[0].get("versioning_configuration") or [{}])[0]
        assert vcfg.get("status") == "Enabled"
        s3_sse = _by_type(items, "aws_s3_bucket_server_side_encryption_configuration")
        assert len(s3_sse) == 1
        pab = _by_type(items, "aws_s3_bucket_public_access_block")
        assert len(pab) == 1
        for flag in ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"):
            assert pab[0].get(flag) is True

        return "RDS, SQS+DLQ, 3 Lambdas, Scheduler, DynamoDB (AccountIndex+PITR), Valkey, and S3 declarations verified"

    _run_block(ctx, "declared.data_async", _check)


def test_declared_security(ctx: VerifierContext) -> None:
    """Scored block: Declared security (3 points) — declared.security."""
    def _check() -> str:
        state = load_tfstate()
        items = _collect_resources(state)
        manifest = ctx.manifest
        hcl_text = _load_hcl_text()

        roles = {r["arn"]: r for r in _by_type(items, "aws_iam_role")}
        iam_arns = list(manifest["iam"].values())
        assert len(set(iam_arns)) == 6, "All 6 IAM role ARNs must be distinct"
        for arn in iam_arns:
            assert arn in roles, f"IAM role ARN {arn} missing from state"

        policies = _by_type(items, "aws_iam_role_policy")
        assert len(policies) >= 6
        for pol in policies:
            doc = json.loads(pol.get("policy") or "{}")
            for stmt in doc.get("Statement", []):
                if stmt.get("Effect") != "Allow":
                    continue
                actions = stmt.get("Action")
                actions_list = [actions] if isinstance(actions, str) else (actions or [])
                for act in actions_list:
                    assert act != "*" and not act.endswith(":*"), f"Wildcard IAM action '{act}' is forbidden"
                resources = stmt.get("Resource")
                res_list = [resources] if isinstance(resources, str) else (resources or [])
                for res in res_list:
                    assert res != "*", f"Wildcard IAM resource '*' is forbidden in policy {pol.get('name')}"

        keys = {k["arn"]: k for k in _by_type(items, "aws_kms_key")}
        kms_arns = list(manifest["kms"].values())
        assert len(set(kms_arns)) == 4, "Expected 4 distinct KMS key ARNs"
        for arn in kms_arns:
            key = keys.get(arn)
            assert key is not None, f"KMS key {arn} not in state"
            assert key.get("enable_key_rotation") is True or "enable_key_rotation" in hcl_text
            assert int(key.get("deletion_window_in_days") or 10) >= 10, "KMS deletion_window_in_days must be >= 10"

        aliases = _by_type(items, "aws_kms_alias")
        assert len(aliases) >= 4

        pools = _by_type(items, "aws_cognito_user_pool")
        assert len(pools) == 1
        res_servers = _by_type(items, "aws_cognito_resource_server")
        assert len(res_servers) == 1
        assert res_servers[0].get("identifier") == "clearledger"
        scopes = {s.get("scope_name") for s in res_servers[0].get("scope") or []}
        assert scopes == {"read", "write", "admin"}

        clients = {c["id"]: c for c in _by_type(items, "aws_cognito_user_pool_client")}
        assert len(clients) == 3
        for role_key, expected_scope in (
            ("read", "clearledger/read"),
            ("write", "clearledger/write"),
            ("admin", "clearledger/admin"),
        ):
            cid = manifest["auth"]["clients"][role_key]["client_id"]
            c = clients.get(cid)
            assert c is not None
            assert c.get("allowed_oauth_flows") == ["client_credentials"]
            assert c.get("allowed_oauth_scopes") == [expected_scope]

        lgs = {lg["name"]: lg for lg in _by_type(items, "aws_cloudwatch_log_group")}
        for lg_name in manifest["logs"].values():
            lg = lgs.get(lg_name)
            assert lg is not None, f"Log group {lg_name} missing from state"
            assert int(lg.get("retention_in_days") or 14) >= 14 and (
                "retention_in_days" in hcl_text or int(lg.get("retention_in_days", 0)) >= 14
            )

        return "IAM least-privilege policies, 4 KMS keys, Cognito OAuth2 scopes, and 4 log groups verified"

    _run_block(ctx, "declared.security", _check)
