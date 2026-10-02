from __future__ import annotations

import json

import httpx

from .conftest import VerifierContext
from .helpers import boto_client


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

        svcs = ecs.describe_services(
            cluster=m["compute"]["cluster_name"],
            services=[m["compute"]["service_name"]],
        )["services"]
        assert len(svcs) == 1
        svc = svcs[0]
        assert int(svc["desiredCount"]) >= 2
        assert int(svc["runningCount"]) >= 2

        task_arns = ecs.list_tasks(
            cluster=m["compute"]["cluster_name"],
            serviceName=m["compute"]["service_name"],
            desiredStatus="RUNNING",
        )["taskArns"]
        assert len(task_arns) >= 2, f"Expected >=2 running ECS tasks, found {len(task_arns)}"
        tasks = ecs.describe_tasks(cluster=m["compute"]["cluster_name"], tasks=task_arns)["tasks"]
        task_subnets = set()
        for t in tasks:
            for att in t.get("attachments", []):
                for d in att.get("details", []):
                    if d.get("name") == "subnetId":
                        task_subnets.add(d.get("value"))
        if task_subnets:
            assert len(task_subnets) >= 2, f"Expected tasks across >=2 subnets, found {task_subnets}"

        instances_seen = set()
        service_url = m["service_url"].rstrip("/")
        with httpx.Client(timeout=5.0) as client:
            for _ in range(8):
                resp = client.get(f"{service_url}/health/ready")
                assert resp.status_code == 200
                body = resp.json()
                assert body["status"] == "UP"
                assert body["checks"]["postgres"] == "UP"
                assert body["checks"]["dynamodb"] == "UP"
                inst = resp.headers.get("X-ClearLedger-Instance") or body.get("instance")
                if inst:
                    instances_seen.add(inst)
        assert len(instances_seen) >= 1

        return f"ALB and {len(task_arns)} running ECS tasks verified across subnets"

    _run_block(ctx, "live.compute_ingress", _check)


def test_live_data_and_event_graph(ctx: VerifierContext) -> None:
    def _check() -> str:
        m = ctx.manifest
        rds = boto_client("rds", ctx.config)
        sqs = boto_client("sqs", ctx.config)
        lam = boto_client("lambda", ctx.config)
        ddb = boto_client("dynamodb", ctx.config)
        ec = boto_client("elasticache", ctx.config)
        s3 = boto_client("s3", ctx.config)
        scheduler = boto_client("scheduler", ctx.config)

        db_inst = rds.describe_db_instances(DBInstanceIdentifier=m["database"]["instance_id"])["DBInstances"][0]
        assert db_inst["Engine"] == "postgres"
        assert db_inst["StorageEncrypted"] is True

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
        redrive = json.loads(q_attrs.get("RedrivePolicy", "{}"))
        assert redrive.get("deadLetterTargetArn") == dlq_attrs.get("QueueArn")
        assert int(redrive.get("maxReceiveCount", 0)) == 4

        for wkey in ("projector", "outbox_relay", "audit_archiver"):
            fn_name = m["workers"][wkey]["function_name"]
            fn_cfg = lam.get_function_configuration(FunctionName=fn_name)
            assert fn_cfg["PackageType"] == "Image"

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

        for skey, expected_fn in (
            ("outbox_schedule_name", m["workers"]["outbox_relay"]["function_arn"]),
            ("archive_schedule_name", m["workers"]["audit_archiver"]["function_arn"]),
        ):
            sched = scheduler.get_schedule(Name=m["schedules"][skey])
            assert sched["State"] == "ENABLED"
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
        assert pitr.get("PointInTimeRecoveryDescription", {}).get("PointInTimeRecoveryStatus") == "ENABLED"

        clusters = ec.describe_cache_clusters(
            CacheClusterId=m["cache"]["cluster_id"],
            ShowCacheNodeInfo=True,
        )["CacheClusters"]
        assert len(clusters) == 1
        assert clusters[0]["Engine"] == "valkey"

        ver = s3.get_bucket_versioning(Bucket=m["audit"]["bucket_name"])
        assert ver.get("Status") == "Enabled"
        enc = s3.get_bucket_encryption(Bucket=m["audit"]["bucket_name"])
        rules = enc["ServerSideEncryptionConfiguration"]["Rules"]
        assert rules[0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "aws:kms"
        pab = s3.get_public_access_block(Bucket=m["audit"]["bucket_name"])["PublicAccessBlockConfiguration"]
        assert all(pab.get(k) is True for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"))

        return "Live RDS, SQS+DLQ, 3 Lambdas, Scheduler, DynamoDB (AccountIndex+PITR), Valkey, and S3 verified"

    _run_block(ctx, "live.data_event_graph", _check)


def test_live_security(ctx: VerifierContext) -> None:
    def _check() -> str:
        m = ctx.manifest
        iam = boto_client("iam", ctx.config)
        kms = boto_client("kms", ctx.config)
        cognito = boto_client("cognito-idp", ctx.config)
        logs = boto_client("logs", ctx.config)

        role_names = [arn.split("/")[-1] for arn in m["iam"].values()]
        assert len(set(role_names)) == 6
        for rname in role_names:
            role = iam.get_role(RoleName=rname)["Role"]
            assert role["Arn"] in m["iam"].values()
            inline_names = iam.list_role_policies(RoleName=rname)["PolicyNames"]
            assert inline_names, f"Role {rname} has no inline policies"

        for k_arn in m["kms"].values():
            meta = kms.describe_key(KeyId=k_arn)["KeyMetadata"]
            assert meta["Enabled"] is True
            rot = kms.get_key_rotation_status(KeyId=k_arn)
            assert rot.get("KeyRotationEnabled") is True

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

        found_groups = {
            lg["logGroupName"]: lg
            for lg in logs.describe_log_groups(logGroupNamePrefix=f"/clearledger/{ctx.config['resource_prefix']}")[
                "logGroups"
            ]
        }
        for lg_name in m["logs"].values():
            assert lg_name in found_groups, f"Live CloudWatch log group {lg_name} missing"
            assert int(found_groups[lg_name].get("retentionInDays", 0)) >= 14

        return "Live IAM roles, KMS rotation, Cognito scopes, and CloudWatch log groups verified"

    _run_block(ctx, "live.security", _check)
