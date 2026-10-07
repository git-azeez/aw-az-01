from __future__ import annotations

import json
from typing import Any

from .conftest import VerifierContext
from .helpers import (
    INFRA_DIR,
    SUBMISSION_DIR,
    config_depends_on_resource,
    config_expr_constant,
    load_iac_configuration,
    load_tfstate,
    run_iac_validate,
    verify_iam_roles_and_policies,
)


def _collect_resources(state: dict[str, Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for res in state.get("resources", []):
        if res.get("mode") != "managed":
            continue
        rtype = res.get("type", "")
        rname = res.get("name", "")
        for inst in res.get("instances", []):
            attrs = dict(inst.get("attributes", {}) or {})
            attrs["_address"] = f"{rtype}.{rname}"
            attrs["_rname"] = rname
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
        iac_bin, _ = run_iac_validate(INFRA_DIR)

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
            "aws_kms_key",
            "aws_kms_alias",
            "aws_cloudwatch_log_group",
        }
        missing = sorted(required_types - types_present)
        assert not missing, f"Missing required IaC resource types: {missing}"
        assert "aws_iam_role_policy" in types_present or (
            {"aws_iam_policy", "aws_iam_role_policy_attachment"}.issubset(types_present)
        ), "Missing required IAM role policy resources (aws_iam_role_policy or aws_iam_policy + aws_iam_role_policy_attachment)"
        assert types_present & {"aws_elasticache_replication_group", "aws_elasticache_cluster"}, (
            "Missing required ElastiCache resource (aws_elasticache_replication_group or aws_elasticache_cluster)"
        )

        prefix = ctx.config["resource_prefix"]
        tagged_count = 0
        for item in items:
            attrs = item["attributes"]
            merged_tags: dict[str, Any] = {}
            if isinstance(attrs.get("tags_all"), dict):
                merged_tags.update(attrs["tags_all"])
            if isinstance(attrs.get("tags"), dict):
                merged_tags.update(attrs["tags"])
            if merged_tags.get("ClearLedgerDeployment") == prefix:
                tagged_count += 1
        assert tagged_count >= 25, (
            f"Expected at least 25 resources tagged ClearLedgerDeployment={prefix}, found {tagged_count}"
        )

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

        return f"Validated {len(items)} managed resources across {len(types_present)} types with {iac_bin}"

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

        sg_rules = _by_type(items, "aws_security_group_rule")
        vpc_sg_rules = _by_type(items, "aws_vpc_security_group_ingress_rule")
        for restricted_key, port in (("ecs", 8080), ("rds", 5432), ("valkey", 6379)):
            sg_id = sg_ids[restricted_key]
            sg = sgs[sg_id]
            for rule in sg.get("ingress", []) or []:
                cidrs = rule.get("cidr_blocks") or []
                if rule.get("from_port") == port:
                    assert "0.0.0.0/0" not in cidrs, f"{restricted_key} security group exposes port {port} to 0.0.0.0/0"
            for srule in sg_rules:
                if srule.get("security_group_id") == sg_id and srule.get("type") == "ingress":
                    if srule.get("from_port") == port:
                        assert "0.0.0.0/0" not in (srule.get("cidr_blocks") or []), (
                            f"{restricted_key} security group rule exposes port {port} to 0.0.0.0/0"
                        )
            for vrule in vpc_sg_rules:
                if vrule.get("security_group_id") == sg_id and vrule.get("from_port") == port:
                    assert vrule.get("cidr_ipv4") != "0.0.0.0/0", (
                        f"{restricted_key} VPC security group ingress rule exposes port {port} to 0.0.0.0/0"
                    )

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
        assert td.get("execution_role_arn") == manifest["iam"]["ecs_execution_role_arn"], (
            f"ECS task definition execution_role_arn ({td.get('execution_role_arn')}) does not match manifest"
        )
        assert td.get("task_role_arn") == manifest["iam"]["ecs_task_role_arn"], (
            f"ECS task definition task_role_arn ({td.get('task_role_arn')}) does not match manifest"
        )
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
            "AUTH_JWKS_URL",
            "AUTH_AUDIENCES",
            "CLOUDWATCH_LOG_GROUP",
        ):
            assert env_map.get(req_env), f"Missing {req_env} in ECS container definition"
        assert env_map.get("CACHE_TTL_SECONDS") == "90", (
            f"Expected CACHE_TTL_SECONDS=90, got {env_map.get('CACHE_TTL_SECONDS')}"
        )
        declared_audiences = {
            part.strip() for part in (env_map.get("AUTH_AUDIENCES") or "").split(",") if part.strip()
        }
        expected_audiences = {
            manifest["auth"]["clients"]["read"]["client_id"],
            manifest["auth"]["clients"]["write"]["client_id"],
            manifest["auth"]["clients"]["admin"]["client_id"],
        }
        assert expected_audiences.issubset(declared_audiences), (
            f"ECS container AUTH_AUDIENCES ({declared_audiences}) missing Cognito client IDs {expected_audiences}"
        )

        return "VPC, ALB, and ECS Fargate declarations and role bindings verified"

    _run_block(ctx, "declared.compute_ingress", _check)


def test_declared_data_and_async(ctx: VerifierContext) -> None:
    """Scored block: Declared data and messaging (2 points) — declared.data_async."""
    def _check() -> str:
        state = load_tfstate()
        items = _collect_resources(state)
        manifest = ctx.manifest
        cfg_map = load_iac_configuration(INFRA_DIR)

        kms_by_arn = {k["arn"]: k for k in _by_type(items, "aws_kms_key")}
        db_kms_arn = manifest["kms"]["database_arn"]
        msg_kms_arn = manifest["kms"]["messaging_arn"]
        proj_kms_arn = manifest["kms"]["projection_arn"]
        audit_kms_arn = manifest["kms"]["audit_arn"]

        db_kms_ids = {db_kms_arn, (kms_by_arn.get(db_kms_arn) or {}).get("key_id") or db_kms_arn.rsplit("/", 1)[-1]}
        msg_kms_ids = {msg_kms_arn, (kms_by_arn.get(msg_kms_arn) or {}).get("key_id") or msg_kms_arn.rsplit("/", 1)[-1]}
        proj_kms_ids = {proj_kms_arn, (kms_by_arn.get(proj_kms_arn) or {}).get("key_id") or proj_kms_arn.rsplit("/", 1)[-1]}
        audit_kms_ids = {audit_kms_arn, (kms_by_arn.get(audit_kms_arn) or {}).get("key_id") or audit_kms_arn.rsplit("/", 1)[-1]}

        for al in _by_type(items, "aws_kms_alias"):
            target = str(al.get("target_key_id") or al.get("target_key_arn") or "")
            al_vals = {str(v) for v in (al.get("name"), al.get("arn"), al.get("id")) if v}
            for kms_set in (db_kms_ids, msg_kms_ids, proj_kms_ids, audit_kms_ids):
                if target and target in kms_set:
                    kms_set.update(al_vals)

        db_kms_addr = (kms_by_arn.get(db_kms_arn) or {}).get("_address", "aws_kms_key.")
        proj_kms_addr = (kms_by_arn.get(proj_kms_arn) or {}).get("_address", "aws_kms_key.")

        dbs = _by_type(items, "aws_db_instance")
        assert len(dbs) == 1
        db = dbs[0]
        db_expr = cfg_map.get(db["_address"], {})
        assert db.get("engine") == "postgres"
        assert str(db.get("engine_version", "16")).startswith("16")
        assert db.get("instance_class") == "db.t4g.micro"
        assert db.get("publicly_accessible") is False
        assert db.get("skip_final_snapshot") is True
        db_encrypted = db.get("storage_encrypted") is True or config_expr_constant(db_expr.get("storage_encrypted")) is True
        assert db_encrypted, "RDS storage_encrypted must be enabled in state or parsed IaC configuration"
        db_kms_ok = (
            db.get("kms_key_id") in db_kms_ids
            or config_expr_constant(db_expr.get("kms_key_id")) in db_kms_ids
            or config_depends_on_resource(db_expr.get("kms_key_id"), db_kms_addr)
        )
        assert db_kms_ok, "RDS kms_key_id must reference the customer-managed database KMS key"

        queues = {q["name"]: q for q in _by_type(items, "aws_sqs_queue")}
        main_q = queues.get(manifest["messaging"]["queue_name"])
        dlq_q = queues.get(manifest["messaging"]["dlq_name"])
        assert main_q is not None and dlq_q is not None
        assert int(main_q.get("visibility_timeout_seconds", 0)) == 3
        assert int(main_q.get("receive_wait_time_seconds", 0)) == 2
        assert int(main_q.get("message_retention_seconds", 0)) == 172800
        assert int(dlq_q.get("message_retention_seconds", 0)) == 1209600
        assert main_q.get("kms_master_key_id") in msg_kms_ids, (
            f"Main SQS queue kms_master_key_id ({main_q.get('kms_master_key_id')}) does not match messaging KMS key"
        )
        assert dlq_q.get("kms_master_key_id") in msg_kms_ids, (
            f"DLQ kms_master_key_id ({dlq_q.get('kms_master_key_id')}) does not match messaging KMS key"
        )
        raw_redrive = main_q.get("redrive_policy")
        if not raw_redrive or raw_redrive.strip() in {"", "{}"}:
            main_q_name = manifest["messaging"]["queue_name"]
            main_q_urls = {
                str(u).rstrip("/")
                for u in (
                    main_q.get("url"),
                    main_q.get("id"),
                    manifest["messaging"]["queue_url"],
                )
                if u
            }
            main_q_addr = str(main_q.get("_address") or "")
            rp_items = _by_type(items, "aws_sqs_queue_redrive_policy")
            for rp in rp_items:
                rp_expr = cfg_map.get(str(rp.get("_address") or ""), {})
                rp_qurl = str(rp.get("queue_url") or rp.get("id") or "").rstrip("/")
                if (
                    rp_qurl in main_q_urls
                    or rp_qurl.endswith(f"/{main_q_name}")
                    or (main_q_addr and config_depends_on_resource(rp_expr.get("queue_url"), main_q_addr))
                    or len(rp_items) == 1
                ):
                    candidate = rp.get("redrive_policy")
                    if candidate and str(candidate).strip() not in {"", "{}"}:
                        raw_redrive = candidate
                        break
        redrive = json.loads(raw_redrive or "{}")
        dlq_addr = str(dlq_q.get("_address") or "")
        redrive_target_ok = redrive.get("deadLetterTargetArn") == dlq_q.get("arn")
        if not redrive_target_ok and dlq_addr:
            main_q_expr = cfg_map.get(str(main_q.get("_address") or ""), {})
            if config_depends_on_resource(main_q_expr.get("redrive_policy"), dlq_addr):
                redrive_target_ok = True
            for rp in _by_type(items, "aws_sqs_queue_redrive_policy"):
                rp_expr = cfg_map.get(str(rp.get("_address") or ""), {})
                if config_depends_on_resource(rp_expr.get("redrive_policy"), dlq_addr):
                    redrive_target_ok = True
                    break
        assert redrive_target_ok, (
            f"Declared SQS redrive deadLetterTargetArn ({redrive.get('deadLetterTargetArn')}) does not match DLQ ARN ({dlq_q.get('arn')})"
        )
        assert int(redrive.get("maxReceiveCount", 0)) == 4

        lambdas = {fn["function_name"]: fn for fn in _by_type(items, "aws_lambda_function")}
        assert len(lambdas) == 3
        expected_workers = {
            manifest["workers"]["projector"]["function_name"]: (
                ctx.config["projector_image"],
                manifest["iam"]["projector_role_arn"],
            ),
            manifest["workers"]["outbox_relay"]["function_name"]: (
                ctx.config["relay_image"],
                manifest["iam"]["relay_role_arn"],
            ),
            manifest["workers"]["audit_archiver"]["function_name"]: (
                ctx.config["archiver_image"],
                manifest["iam"]["archiver_role_arn"],
            ),
        }
        for fname, (img, expected_role_arn) in expected_workers.items():
            fn = lambdas.get(fname)
            assert fn is not None, f"Lambda {fname} missing from state"
            assert fn.get("package_type") == "Image"
            assert fn.get("image_uri") == img
            assert fn.get("role") == expected_role_arn, (
                f"Lambda {fname} role ({fn.get('role')}) does not match expected role {expected_role_arn}"
            )

        relay_fn = lambdas[manifest["workers"]["outbox_relay"]["function_name"]]
        relay_env = ((relay_fn.get("environment") or [{}])[0]).get("variables") or {}
        assert relay_env.get("OUTBOX_BATCH_SIZE") == "50", (
            f"Expected OUTBOX_BATCH_SIZE=50 on relay Lambda, got {relay_env.get('OUTBOX_BATCH_SIZE')}"
        )

        archiver_fn = lambdas[manifest["workers"]["audit_archiver"]["function_name"]]
        archiver_env = ((archiver_fn.get("environment") or [{}])[0]).get("variables") or {}
        assert archiver_env.get("AUDIT_PREFIX") == "ledger-audit/", (
            f"Expected AUDIT_PREFIX=ledger-audit/ on archiver Lambda, got {archiver_env.get('AUDIT_PREFIX')}"
        )

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
        outbox_target = (outbox_sched.get("target") or [{}])[0]
        arch_target = (arch_sched.get("target") or [{}])[0]
        assert outbox_target.get("arn") == manifest["workers"]["outbox_relay"]["function_arn"]
        assert outbox_target.get("role_arn") == manifest["iam"]["scheduler_role_arn"]
        assert arch_target.get("arn") == manifest["workers"]["audit_archiver"]["function_arn"]
        assert arch_target.get("role_arn") == manifest["iam"]["scheduler_role_arn"]

        tables = _by_type(items, "aws_dynamodb_table")
        assert len(tables) == 1
        tbl = tables[0]
        tbl_expr = cfg_map.get(tbl["_address"], {})
        assert tbl.get("name") == manifest["projections"]["table_name"]
        assert tbl.get("billing_mode") == "PAY_PER_REQUEST"
        assert tbl.get("hash_key") == "PK"
        assert tbl.get("range_key") == "SK"
        gsis = tbl.get("global_secondary_index") or []

        def _gsi_matches(g: dict[str, Any]) -> bool:
            if g.get("name") != "AccountIndex" or g.get("projection_type") != "ALL":
                return False
            if g.get("hash_key") == "GSI1PK" and g.get("range_key") == "GSI1SK":
                return True
            ks = {
                k.get("attribute_name"): k.get("key_type")
                for k in (g.get("key_schema") or [])
                if isinstance(k, dict)
            }
            return ks == {"GSI1PK": "HASH", "GSI1SK": "RANGE"}

        assert any(_gsi_matches(g) for g in gsis), "DynamoDB table missing required AccountIndex GSI (GSI1PK/GSI1SK)"
        pitr = (tbl.get("point_in_time_recovery") or [{}])[0]
        assert pitr.get("enabled") is True, "DynamoDB point_in_time_recovery must be enabled in state"

        sse = (tbl.get("server_side_encryption") or [{}])[0]
        sse_expr_list = tbl_expr.get("server_side_encryption") or []
        sse_expr = sse_expr_list[0] if isinstance(sse_expr_list, list) and sse_expr_list else {}
        sse_enabled = sse.get("enabled") is True or config_expr_constant(sse_expr.get("enabled")) is True
        sse_kms_ok = (
            sse.get("kms_key_arn") in proj_kms_ids
            or config_expr_constant(sse_expr.get("kms_key_arn")) in proj_kms_ids
            or config_depends_on_resource(sse_expr.get("kms_key_arn"), proj_kms_addr)
        )
        assert sse_enabled and sse_kms_ok, (
            "DynamoDB server_side_encryption must be enabled with the projection KMS key"
        )

        caches = _by_type(items, "aws_elasticache_replication_group") + _by_type(items, "aws_elasticache_cluster")
        assert len(caches) >= 1
        cache = caches[0]
        assert str(cache.get("engine", "valkey")).lower() in {"valkey", "redis"}
        assert cache.get("node_type") == "cache.t4g.micro"
        assert int(cache.get("port") or 6379) == 6379

        buckets = _by_type(items, "aws_s3_bucket")
        assert len(buckets) == 1
        assert buckets[0].get("bucket") == manifest["audit"]["bucket_name"]
        vers = _by_type(items, "aws_s3_bucket_versioning")
        assert len(vers) == 1
        vcfg = (vers[0].get("versioning_configuration") or [{}])[0]
        assert vcfg.get("status") == "Enabled"
        s3_sse = _by_type(items, "aws_s3_bucket_server_side_encryption_configuration")
        assert len(s3_sse) == 1
        sse_rules = s3_sse[0].get("rule") or []
        assert sse_rules, "S3 server-side encryption configuration has no rules"
        default_sse = (sse_rules[0].get("apply_server_side_encryption_by_default") or [{}])[0]
        assert default_sse.get("sse_algorithm") == "aws:kms", (
            f"Expected S3 SSE algorithm aws:kms, got {default_sse.get('sse_algorithm')}"
        )
        assert default_sse.get("kms_master_key_id") in audit_kms_ids, (
            f"S3 KMS key ({default_sse.get('kms_master_key_id')}) does not match audit KMS key"
        )
        pab = _by_type(items, "aws_s3_bucket_public_access_block")
        assert len(pab) == 1
        for flag in ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"):
            assert pab[0].get(flag) is True

        return "RDS, SQS+DLQ, 3 Lambdas, Scheduler, DynamoDB (AccountIndex+PITR+SSE), Valkey, and S3 KMS verified"

    _run_block(ctx, "declared.data_async", _check)


def test_declared_security(ctx: VerifierContext) -> None:
    """Scored block: Declared security (3 points) — declared.security."""
    def _check() -> str:
        state = load_tfstate()
        items = _collect_resources(state)
        manifest = ctx.manifest

        roles = {r["arn"]: r for r in _by_type(items, "aws_iam_role")}
        roles_by_name = {r["name"]: r["arn"] for r in roles.values() if r.get("name")}
        roles_by_id = {r["id"]: r["arn"] for r in roles.values() if r.get("id")}

        role_trust_docs: dict[str, Any] = {}
        role_policy_docs: dict[str, list[dict[str, Any]]] = {arn: [] for arn in manifest["iam"].values()}
        for arn in manifest["iam"].values():
            assert arn in roles, f"IAM role ARN {arn} missing from state"
            role_trust_docs[arn] = roles[arn].get("assume_role_policy")

        for pol in _by_type(items, "aws_iam_role_policy"):
            role_ref = str(pol.get("role") or "")
            role_arn = roles_by_name.get(role_ref) or roles_by_id.get(role_ref) or (role_ref if role_ref in roles else None)
            if role_arn and role_arn in role_policy_docs:
                role_policy_docs[role_arn].append(json.loads(pol.get("policy") or "{}"))

        managed_policies = {p["arn"]: p for p in _by_type(items, "aws_iam_policy") if p.get("arn")}
        for att in _by_type(items, "aws_iam_role_policy_attachment"):
            role_ref = str(att.get("role") or "")
            pol_arn = str(att.get("policy_arn") or "")
            role_arn = roles_by_name.get(role_ref) or roles_by_id.get(role_ref) or (role_ref if role_ref in roles else None)
            if role_arn in role_policy_docs and pol_arn in managed_policies:
                role_policy_docs[role_arn].append(json.loads(managed_policies[pol_arn].get("policy") or "{}"))

        lgs = {lg["name"]: lg for lg in _by_type(items, "aws_cloudwatch_log_group")}
        log_group_arns = {name: str(lg.get("arn") or "") for name, lg in lgs.items()}

        verify_iam_roles_and_policies(
            manifest=manifest,
            role_trust_docs=role_trust_docs,
            role_policy_docs=role_policy_docs,
            log_group_arns=log_group_arns,
            label="Declared IAM",
        )

        keys = {k["arn"]: k for k in _by_type(items, "aws_kms_key")}
        kms_arns = list(manifest["kms"].values())
        assert len(set(kms_arns)) == 4, "Expected 4 distinct KMS key ARNs"
        expected_key_ids: set[str] = set()
        for arn in kms_arns:
            key = keys.get(arn)
            assert key is not None, f"KMS key {arn} not in state"
            assert key.get("is_enabled") is not False, f"KMS key {arn} must be enabled"
            assert key.get("enable_key_rotation") is True, f"KMS key {arn} must have enable_key_rotation=true in state"
            del_window = int(key.get("deletion_window_in_days") or 0)
            assert 10 <= del_window <= 30, f"KMS key {arn} deletion_window_in_days must be 10..30, got {del_window}"
            expected_key_ids.add(str(key.get("key_id") or arn.rsplit("/", 1)[-1]))
            expected_key_ids.add(arn)

        aliases = _by_type(items, "aws_kms_alias")
        assert len(aliases) >= 4, f"Expected at least 4 aws_kms_alias resources, found {len(aliases)}"
        alias_targets: set[str] = set()
        for al in aliases:
            name = str(al.get("name") or "")
            assert name.startswith("alias/"), f"KMS alias '{name}' must start with 'alias/'"
            target = str(al.get("target_key_id") or al.get("target_key_arn") or "")
            if target:
                alias_targets.add(target)
        for arn in kms_arns:
            kid = str((keys.get(arn) or {}).get("key_id") or arn.rsplit("/", 1)[-1])
            assert arn in alias_targets or kid in alias_targets, f"KMS key {arn} has no declared aws_kms_alias"

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

        for lg_name in manifest["logs"].values():
            lg = lgs.get(lg_name)
            assert lg is not None, f"Log group {lg_name} missing from state"
            ret = int(lg.get("retention_in_days") or 0)
            assert ret >= 14, f"Log group {lg_name} retention_in_days must be >= 14 in state, got {ret}"

        return "IAM trust & least-privilege policies, 4 KMS keys+aliases, Cognito OAuth2 scopes, and 4 log groups verified"

    _run_block(ctx, "declared.security", _check)

