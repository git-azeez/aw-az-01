#!/usr/bin/env bash
# ClearLedger destroy: tear down every resource of the active resource_prefix
# (Terraform-managed and out-of-band), leaving baseline (cl-base-*) untouched.
set -Euo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
STATE="${INFRA_DIR}/terraform.tfstate"
CONFIG_PATH="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
START_TS=$(date +%s)

log() { printf '[destroy %4ds] %s\n' "$(( $(date +%s) - START_TS ))" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_PATH}" ]] || die "config not found: ${CONFIG_PATH}"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
if command -v terraform >/dev/null 2>&1; then TF=terraform; elif command -v tofu >/dev/null 2>&1; then TF=tofu; else die "terraform/tofu not found"; fi

PREFIX=$(jq -er '.resource_prefix' "${CONFIG_PATH}")
REGION=$(jq -er '.region' "${CONFIG_PATH}")
ENDPOINT=$(jq -er '.aws_endpoint_url' "${CONFIG_PATH}")
[[ -n "${PREFIX}" && "${PREFIX}" != cl-base* ]] || die "refusing to destroy prefix '${PREFIX}'"

export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1 TF_INPUT=0

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/clearledger-destroy.XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

log "destroying ClearLedger prefix=${PREFIX} (${TF})"

# Embedded prefix-scoped sweep program
write_sweep_py() {
cat <<'CLEARLEDGER_PY_EOF'
#!/usr/bin/env python3
"""Prefix-scoped sweep of ClearLedger resources (Terraform-managed leftovers
and out-of-band operational resources). Never touches anything that does not
belong to the active resource_prefix (e.g. cl-base-* baseline resources).

Usage: sweep.py <config.json>
"""
import json
import os
import re
import sys
import time

import boto3
from botocore.config import Config

CFG = json.load(open(sys.argv[1]))
PREFIX = CFG["resource_prefix"]
EP = CFG["aws_endpoint_url"]
REGION = CFG["region"]
TAG_KEY = "ClearLedgerDeployment"
NAME_RE = re.compile(r"^" + re.escape(PREFIX) + r"([-_.]|$)")
LOG_RE = re.compile(r"(^|/)" + re.escape(PREFIX) + r"([-_./]|$)")
BOTO_CFG = Config(retries={"max_attempts": 5, "mode": "standard"}, read_timeout=60, connect_timeout=10)


def log(msg):
    print(f"[sweep] {msg}", file=sys.stderr, flush=True)


def c(name):
    return boto3.client(name, endpoint_url=EP, region_name=REGION, aws_access_key_id="test",
                        aws_secret_access_key="test", config=BOTO_CFG)


def mine(name):
    return bool(name) and bool(NAME_RE.match(name))


def safe(desc, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if not any(s in msg for s in ("NotFound", "NoSuch", "does not exist", "not found", "ResourceNotFound")):
            log(f"{desc}: {msg[:200]}")
        return None


def tags_mine(tags):
    if isinstance(tags, dict):
        return tags.get(TAG_KEY) == PREFIX
    for t in tags or []:
        if (t.get("Key") or t.get("TagKey")) == TAG_KEY and (t.get("Value") or t.get("TagValue")) == PREFIX:
            return True
    return False


# ---------------------------------------------------------------------------

def sweep_scheduler():
    s = c("scheduler")
    groups = [g["Name"] for g in (safe("scheduler groups", s.list_schedule_groups) or {}).get("ScheduleGroups", [])]
    for g in groups:
        token = None
        while True:
            kw = {"GroupName": g}
            if token:
                kw["NextToken"] = token
            resp = safe("list schedules", s.list_schedules, **kw) or {}
            for sch in resp.get("Schedules", []):
                if mine(sch["Name"]):
                    log(f"scheduler: delete {g}/{sch['Name']}")
                    safe("delete schedule", s.delete_schedule, Name=sch["Name"], GroupName=g)
            token = resp.get("NextToken")
            if not token:
                break
        if mine(g):
            log(f"scheduler: delete group {g}")
            safe("delete schedule group", s.delete_schedule_group, Name=g)


def sweep_lambda():
    lam = c("lambda")
    fns = []
    for page in lam.get_paginator("list_functions").paginate():
        fns += [f for f in page.get("Functions", []) if mine(f["FunctionName"])]
    for page in lam.get_paginator("list_event_source_mappings").paginate():
        for m in page.get("EventSourceMappings", []):
            fn = m.get("FunctionArn", "").split(":function:")[-1].split(":")[0]
            src = m.get("EventSourceArn", "").split(":")[-1]
            if mine(fn) or mine(src):
                log(f"lambda: delete event source mapping {m['UUID']}")
                safe("delete esm", lam.delete_event_source_mapping, UUID=m["UUID"])
    for f in fns:
        log(f"lambda: delete function {f['FunctionName']}")
        safe("delete function", lam.delete_function, FunctionName=f["FunctionName"])


def sweep_ecs():
    ecs = c("ecs")
    arns = (safe("list clusters", ecs.list_clusters) or {}).get("clusterArns", [])
    for arn in arns:
        name = arn.split("/")[-1]
        if not mine(name):
            continue
        svcs = (safe("list services", ecs.list_services, cluster=arn) or {}).get("serviceArns", [])
        for s in svcs:
            log(f"ecs: delete service {s}")
            safe("scale service", ecs.update_service, cluster=arn, service=s, desiredCount=0)
            safe("delete service", ecs.delete_service, cluster=arn, service=s, force=True)
        for t in (safe("list tasks", ecs.list_tasks, cluster=arn) or {}).get("taskArns", []):
            safe("stop task", ecs.stop_task, cluster=arn, task=t, reason="clearledger destroy")
        log(f"ecs: delete cluster {name}")
        for _ in range(10):
            if safe("delete cluster", ecs.delete_cluster, cluster=arn) is not None:
                break
            time.sleep(2)
    for status in ("ACTIVE", "INACTIVE"):
        token = None
        while True:
            kw = {"status": status}
            if token:
                kw["nextToken"] = token
            resp = safe("list task defs", ecs.list_task_definitions, **kw) or {}
            for td in resp.get("taskDefinitionArns", []):
                fam = td.split("/")[-1].rsplit(":", 1)[0]
                if mine(fam):
                    if status == "ACTIVE":
                        safe("deregister td", ecs.deregister_task_definition, taskDefinition=td)
                    if hasattr(ecs, "delete_task_definitions"):
                        safe("delete td", ecs.delete_task_definitions, taskDefinitions=[td])
            token = resp.get("nextToken")
            if not token:
                break


def sweep_elb():
    elb = c("elbv2")
    for lb in (safe("describe lbs", elb.describe_load_balancers) or {}).get("LoadBalancers", []):
        if mine(lb["LoadBalancerName"]):
            for ln in (safe("listeners", elb.describe_listeners, LoadBalancerArn=lb["LoadBalancerArn"]) or {}).get("Listeners", []):
                safe("delete listener", elb.delete_listener, ListenerArn=ln["ListenerArn"])
            log(f"elbv2: delete load balancer {lb['LoadBalancerName']}")
            safe("delete lb", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in (safe("describe tgs", elb.describe_target_groups) or {}).get("TargetGroups", []):
        if mine(tg["TargetGroupName"]):
            log(f"elbv2: delete target group {tg['TargetGroupName']}")
            safe("delete tg", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])


def sweep_rds():
    rds = c("rds")
    doomed = []
    for db in (safe("describe dbs", rds.describe_db_instances) or {}).get("DBInstances", []):
        if mine(db["DBInstanceIdentifier"]):
            log(f"rds: delete instance {db['DBInstanceIdentifier']}")
            safe("modify db", rds.modify_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 DeletionProtection=False, ApplyImmediately=True)
            safe("delete db", rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
            doomed.append(db["DBInstanceIdentifier"])
    for _ in range(60):
        left = [d["DBInstanceIdentifier"] for d in (safe("describe dbs", rds.describe_db_instances) or {}).get("DBInstances", [])
                if d["DBInstanceIdentifier"] in doomed]
        if not left:
            break
        time.sleep(3)
    for snap in (safe("describe snapshots", rds.describe_db_snapshots) or {}).get("DBSnapshots", []):
        if mine(snap["DBSnapshotIdentifier"]) or mine(snap.get("DBInstanceIdentifier")):
            safe("delete snapshot", rds.delete_db_snapshot, DBSnapshotIdentifier=snap["DBSnapshotIdentifier"])
    for g in (safe("describe subnet groups", rds.describe_db_subnet_groups) or {}).get("DBSubnetGroups", []):
        if mine(g["DBSubnetGroupName"]):
            log(f"rds: delete subnet group {g['DBSubnetGroupName']}")
            safe("delete db subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    for g in (safe("describe pgs", rds.describe_db_parameter_groups) or {}).get("DBParameterGroups", []):
        if mine(g["DBParameterGroupName"]):
            safe("delete pg", rds.delete_db_parameter_group, DBParameterGroupName=g["DBParameterGroupName"])


def sweep_elasticache():
    ec = c("elasticache")
    doomed = []
    for rg in (safe("describe rgs", ec.describe_replication_groups) or {}).get("ReplicationGroups", []):
        if mine(rg["ReplicationGroupId"]):
            log(f"elasticache: delete replication group {rg['ReplicationGroupId']}")
            safe("delete rg", ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"])
            doomed.append(rg["ReplicationGroupId"])
    for cc in (safe("describe ccs", ec.describe_cache_clusters) or {}).get("CacheClusters", []):
        if mine(cc["CacheClusterId"]) and not cc.get("ReplicationGroupId"):
            safe("delete cc", ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])
    for _ in range(40):
        left = [r for r in (safe("describe rgs", ec.describe_replication_groups) or {}).get("ReplicationGroups", [])
                if r["ReplicationGroupId"] in doomed]
        if not left:
            break
        time.sleep(3)
    for g in (safe("describe subnet groups", ec.describe_cache_subnet_groups) or {}).get("CacheSubnetGroups", []):
        if mine(g["CacheSubnetGroupName"]):
            log(f"elasticache: delete subnet group {g['CacheSubnetGroupName']}")
            safe("delete cache subnet group", ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])


def sweep_dynamodb():
    ddb = c("dynamodb")
    for page in ddb.get_paginator("list_tables").paginate():
        for t in page.get("TableNames", []):
            if mine(t):
                log(f"dynamodb: delete table {t}")
                safe("ddb protection", ddb.update_table, TableName=t, DeletionProtectionEnabled=False)
                safe("delete table", ddb.delete_table, TableName=t)


def sweep_sqs():
    sqs = c("sqs")
    urls = (safe("list queues", sqs.list_queues, QueueNamePrefix=PREFIX) or {}).get("QueueUrls", [])
    for u in urls:
        if mine(u.rstrip("/").split("/")[-1]):
            log(f"sqs: delete queue {u}")
            safe("delete queue", sqs.delete_queue, QueueUrl=u)


def purge_bucket(s3, b):
    while True:
        resp = safe("list versions", s3.list_object_versions, Bucket=b) or {}
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in resp.get("Versions", []) or []]
        objs += [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in resp.get("DeleteMarkers", []) or []]
        if not objs:
            break
        for i in range(0, len(objs), 500):
            safe("delete objects", s3.delete_objects, Bucket=b, Delete={"Objects": objs[i:i + 500], "Quiet": True})
    while True:
        resp = safe("list objects", s3.list_objects_v2, Bucket=b) or {}
        objs = [{"Key": o["Key"]} for o in resp.get("Contents", []) or []]
        if not objs:
            break
        safe("delete objects", s3.delete_objects, Bucket=b, Delete={"Objects": objs, "Quiet": True})


def sweep_s3():
    s3 = boto3.client("s3", endpoint_url=EP, region_name=REGION, aws_access_key_id="test",
                      aws_secret_access_key="test", config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 5}))
    for b in (safe("list buckets", s3.list_buckets) or {}).get("Buckets", []):
        if mine(b["Name"]):
            log(f"s3: purge + delete bucket {b['Name']}")
            safe("bucket policy", s3.delete_bucket_policy, Bucket=b["Name"])
            purge_bucket(s3, b["Name"])
            safe("delete bucket", s3.delete_bucket, Bucket=b["Name"])


def sweep_cognito():
    cg = c("cognito-idp")
    token = None
    while True:
        kw = {"MaxResults": 60}
        if token:
            kw["NextToken"] = token
        resp = safe("list pools", cg.list_user_pools, **kw) or {}
        for p in resp.get("UserPools", []):
            if mine(p["Name"]):
                d = (safe("describe pool", cg.describe_user_pool, UserPoolId=p["Id"]) or {}).get("UserPool", {})
                if d.get("Domain"):
                    safe("delete domain", cg.delete_user_pool_domain, Domain=d["Domain"], UserPoolId=p["Id"])
                log(f"cognito: delete user pool {p['Name']} ({p['Id']})")
                safe("pool protection", cg.update_user_pool, UserPoolId=p["Id"], DeletionProtection="INACTIVE")
                safe("delete pool", cg.delete_user_pool, UserPoolId=p["Id"])
        token = resp.get("NextToken")
        if not token:
            break


def delete_policy(iam, arn):
    ents = safe("entities", iam.list_entities_for_policy, PolicyArn=arn) or {}
    for r in ents.get("PolicyRoles", []):
        safe("detach role", iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
    for u in ents.get("PolicyUsers", []):
        safe("detach user", iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
    for g in ents.get("PolicyGroups", []):
        safe("detach group", iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
    for v in (safe("versions", iam.list_policy_versions, PolicyArn=arn) or {}).get("Versions", []):
        if not v["IsDefaultVersion"]:
            safe("delete version", iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
    log(f"iam: delete policy {arn}")
    safe("delete policy", iam.delete_policy, PolicyArn=arn)


def sweep_iam():
    iam = c("iam")
    for page in iam.get_paginator("list_roles").paginate():
        for r in page.get("Roles", []):
            name = r["RoleName"]
            if not mine(name):
                continue
            for p in (safe("inline", iam.list_role_policies, RoleName=name) or {}).get("PolicyNames", []):
                safe("delete inline", iam.delete_role_policy, RoleName=name, PolicyName=p)
            for p in (safe("attached", iam.list_attached_role_policies, RoleName=name) or {}).get("AttachedPolicies", []):
                safe("detach", iam.detach_role_policy, RoleName=name, PolicyArn=p["PolicyArn"])
            for ip in (safe("profiles", iam.list_instance_profiles_for_role, RoleName=name) or {}).get("InstanceProfiles", []):
                safe("remove from profile", iam.remove_role_from_instance_profile,
                     InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
            safe("permissions boundary", iam.delete_role_permissions_boundary, RoleName=name)
            log(f"iam: delete role {name}")
            safe("delete role", iam.delete_role, RoleName=name)
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page.get("Policies", []):
            if mine(p["PolicyName"]):
                delete_policy(iam, p["Arn"])
    for page in iam.get_paginator("list_instance_profiles").paginate():
        for ip in page.get("InstanceProfiles", []):
            if mine(ip["InstanceProfileName"]):
                for r in ip.get("Roles", []):
                    safe("remove role", iam.remove_role_from_instance_profile,
                         InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
                safe("delete profile", iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
    for page in iam.get_paginator("list_users").paginate():
        for u in page.get("Users", []):
            name = u["UserName"]
            if not mine(name):
                continue
            for p in (safe("inline", iam.list_user_policies, UserName=name) or {}).get("PolicyNames", []):
                safe("delete inline", iam.delete_user_policy, UserName=name, PolicyName=p)
            for p in (safe("attached", iam.list_attached_user_policies, UserName=name) or {}).get("AttachedPolicies", []):
                safe("detach", iam.detach_user_policy, UserName=name, PolicyArn=p["PolicyArn"])
            for k in (safe("keys", iam.list_access_keys, UserName=name) or {}).get("AccessKeyMetadata", []):
                safe("delete key", iam.delete_access_key, UserName=name, AccessKeyId=k["AccessKeyId"])
            for g in (safe("groups", iam.list_groups_for_user, UserName=name) or {}).get("Groups", []):
                safe("remove from group", iam.remove_user_from_group, GroupName=g["GroupName"], UserName=name)
            safe("login profile", iam.delete_login_profile, UserName=name)
            log(f"iam: delete user {name}")
            safe("delete user", iam.delete_user, UserName=name)


def sweep_kms():
    kms = c("kms")
    keys = set()
    for page in kms.get_paginator("list_aliases").paginate():
        for a in page.get("Aliases", []):
            an = a["AliasName"]
            if an.startswith("alias/") and mine(an[len("alias/"):]):
                if a.get("TargetKeyId"):
                    keys.add(a["TargetKeyId"])
                log(f"kms: delete alias {an}")
                safe("delete alias", kms.delete_alias, AliasName=an)
    for page in kms.get_paginator("list_keys").paginate():
        for k in page.get("Keys", []):
            kid = k["KeyId"]
            if kid in keys:
                continue
            tags = (safe("key tags", kms.list_resource_tags, KeyId=kid) or {}).get("Tags", [])
            if tags_mine(tags):
                keys.add(kid)
                continue
            md = (safe("describe key", kms.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
            if md.get("KeyManager") == "CUSTOMER" and mine(md.get("Description", "").split(" ")[0]):
                keys.add(kid)
    for kid in keys:
        md = (safe("describe key", kms.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
        if md.get("KeyManager", "CUSTOMER") != "CUSTOMER":
            continue
        if md.get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
            continue
        log(f"kms: schedule deletion of key {kid}")
        safe("schedule key deletion", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)


def sweep_logs():
    logs = c("logs")
    for page in logs.get_paginator("describe_log_groups").paginate():
        for g in page.get("logGroups", []):
            if LOG_RE.search(g["logGroupName"]):
                log(f"logs: delete log group {g['logGroupName']}")
                safe("delete log group", logs.delete_log_group, logGroupName=g["logGroupName"])


def sweep_misc():
    ssm = c("ssm")
    try:
        for page in ssm.get_paginator("describe_parameters").paginate():
            for p in page.get("Parameters", []):
                n = p["Name"]
                if mine(n.lstrip("/")) or LOG_RE.search(n):
                    safe("delete param", ssm.delete_parameter, Name=n)
    except Exception:  # noqa: BLE001
        pass
    sm = c("secretsmanager")
    try:
        for page in sm.get_paginator("list_secrets").paginate():
            for s in page.get("SecretList", []):
                if mine(s["Name"]) or tags_mine(s.get("Tags")):
                    safe("delete secret", sm.delete_secret, SecretId=s["ARN"], ForceDeleteWithoutRecovery=True)
    except Exception:  # noqa: BLE001
        pass
    sns = c("sns")
    try:
        for page in sns.get_paginator("list_topics").paginate():
            for t in page.get("Topics", []):
                if mine(t["TopicArn"].split(":")[-1]):
                    safe("delete topic", sns.delete_topic, TopicArn=t["TopicArn"])
    except Exception:  # noqa: BLE001
        pass


def name_tag(tags):
    for t in tags or []:
        if t.get("Key") == "Name":
            return t.get("Value")
    return None


def sweep_ec2():
    ec2 = c("ec2")
    vpcs = [v for v in (safe("vpcs", ec2.describe_vpcs) or {}).get("Vpcs", [])
            if not v.get("IsDefault") and (tags_mine(v.get("Tags")) or mine(name_tag(v.get("Tags"))))]
    vpc_ids = [v["VpcId"] for v in vpcs]
    known_vpcs = set(vpc_ids) | {x for x in os.environ.get("CL_VPC_IDS", "").split(",") if x}

    # Security groups owned by the prefix (inside or outside our VPCs).
    sgs = (safe("sgs", ec2.describe_security_groups) or {}).get("SecurityGroups", [])
    doomed_sgs = [g for g in sgs if g["GroupName"] != "default" and
                  (g.get("VpcId") in vpc_ids or mine(g["GroupName"]) or tags_mine(g.get("Tags")))]
    for g in doomed_sgs:
        if g.get("IpPermissions"):
            safe("revoke ingress", ec2.revoke_security_group_ingress, GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
        if g.get("IpPermissionsEgress"):
            safe("revoke egress", ec2.revoke_security_group_egress, GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])

    for vid in vpc_ids:
        enis = (safe("enis", ec2.describe_network_interfaces, Filters=[{"Name": "vpc-id", "Values": [vid]}]) or {}).get("NetworkInterfaces", [])
        for e in enis:
            if e.get("Attachment", {}).get("AttachmentId"):
                safe("detach eni", ec2.detach_network_interface, AttachmentId=e["Attachment"]["AttachmentId"], Force=True)
            safe("delete eni", ec2.delete_network_interface, NetworkInterfaceId=e["NetworkInterfaceId"])
        for ep in (safe("vpc endpoints", ec2.describe_vpc_endpoints, Filters=[{"Name": "vpc-id", "Values": [vid]}]) or {}).get("VpcEndpoints", []):
            safe("delete endpoint", ec2.delete_vpc_endpoints, VpcEndpointIds=[ep["VpcEndpointId"]])
        for ng in (safe("nat", ec2.describe_nat_gateways, Filters=[{"Name": "vpc-id", "Values": [vid]}]) or {}).get("NatGateways", []):
            safe("delete nat", ec2.delete_nat_gateway, NatGatewayId=ng["NatGatewayId"])

    for g in doomed_sgs:
        log(f"ec2: delete security group {g['GroupName']} ({g['GroupId']})")
        safe("delete sg", ec2.delete_security_group, GroupId=g["GroupId"])

    for vid in vpc_ids:
        for igw in (safe("igws", ec2.describe_internet_gateways, Filters=[{"Name": "attachment.vpc-id", "Values": [vid]}]) or {}).get("InternetGateways", []):
            safe("detach igw", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vid)
            safe("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in (safe("subnets", ec2.describe_subnets, Filters=[{"Name": "vpc-id", "Values": [vid]}]) or {}).get("Subnets", []):
            safe("delete subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
        for rt in (safe("rts", ec2.describe_route_tables, Filters=[{"Name": "vpc-id", "Values": [vid]}]) or {}).get("RouteTables", []):
            if any(a.get("Main") for a in rt.get("Associations", [])):
                continue
            for a in rt.get("Associations", []):
                safe("disassociate rt", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            safe("delete rt", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        for acl in (safe("acls", ec2.describe_network_acls, Filters=[{"Name": "vpc-id", "Values": [vid]}]) or {}).get("NetworkAcls", []):
            if not acl.get("IsDefault"):
                safe("delete acl", ec2.delete_network_acl, NetworkAclId=acl["NetworkAclId"])
        log(f"ec2: delete vpc {vid}")
        safe("delete vpc", ec2.delete_vpc, VpcId=vid)

    # Default security groups orphaned by our (deleted) VPCs.
    live = {v["VpcId"] for v in (safe("vpcs", ec2.describe_vpcs) or {}).get("Vpcs", [])}
    for g in (safe("sgs", ec2.describe_security_groups) or {}).get("SecurityGroups", []):
        if g.get("VpcId") in known_vpcs and g.get("VpcId") not in live:
            log(f"ec2: delete orphaned security group {g['GroupId']} of deleted vpc {g['VpcId']}")
            safe("delete orphan sg", ec2.delete_security_group, GroupId=g["GroupId"])

    # Orphaned IGWs tagged for the prefix.
    for igw in (safe("igws", ec2.describe_internet_gateways) or {}).get("InternetGateways", []):
        if tags_mine(igw.get("Tags")) and not igw.get("Attachments"):
            safe("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])


def main():
    steps = [sweep_scheduler, sweep_lambda, sweep_ecs, sweep_elb, sweep_rds, sweep_elasticache,
             sweep_dynamodb, sweep_sqs, sweep_s3, sweep_cognito, sweep_iam, sweep_kms, sweep_misc,
             sweep_ec2, sweep_logs]
    for step in steps:
        try:
            step()
        except Exception as exc:  # noqa: BLE001
            log(f"{step.__name__} failed: {exc}")


if __name__ == "__main__":
    main()
CLEARLEDGER_PY_EOF
}

write_sweep_py >"${WORK_DIR}/sweep.py"

state_count() {
  [[ -f "${STATE}" ]] || { echo 0; return; }
  "${TF}" state list -state="${STATE}" 2>/dev/null | grep -vc '^data\.' || true
}

tf_destroy() {
  local limit=$1
  timeout -s INT -k 30 "${limit}" "${TF}" destroy -auto-approve -input=false -no-color -compact-warnings \
      -lock-timeout=30s -state="${STATE}" -var "config_path=${CONFIG_PATH}" >"${WORK_DIR}/destroy.log" 2>&1
  local rc=$?
  grep -E 'Destruction complete after ([0-9]+m|[3-9][0-9]s)|^(Destroy complete|Error)' "${WORK_DIR}/destroy.log" >&2 || true
  if [[ $rc -ne 0 ]]; then
    grep -vE 'Still (destroying|modifying|creating)|Destroying\.\.\.|Destruction complete' "${WORK_DIR}/destroy.log" | tail -n 40 >&2
  fi
  return $rc
}

cd "${INFRA_DIR}" || die "missing ${INFRA_DIR}"
if ! "${TF}" init -input=false -no-color >"${WORK_DIR}/init.log" 2>&1; then
  cat "${WORK_DIR}/init.log" >&2
  log "WARNING: ${TF} init failed; relying on prefix sweep"
fi

# Remember our VPC ids: the control plane can leave the VPC's default security
# group behind after the VPC itself is deleted.
if [[ -f "${STATE}" ]]; then
  CL_VPC_IDS=$(jq -r '[.resources[]? | select(.type=="aws_vpc") | .instances[]?.attributes.id] | join(",")' "${STATE}" 2>/dev/null || true)
  export CL_VPC_IDS
fi

# 1. Terraform-managed teardown.
if [[ $(state_count) -gt 0 ]]; then
  log "${TF} destroy ($(state_count) managed resources)"
  tf_destroy 420 || log "first ${TF} destroy did not complete cleanly"
fi

# 2. Prefix-scoped sweep of leftovers and out-of-band resources.
log "sweeping prefix-scoped resources"
python3 "${WORK_DIR}/sweep.py" "${CONFIG_PATH}" || log "sweep reported errors"

# 3. Reconcile state: anything still tracked is re-destroyed or, if already
#    gone/unmanageable, dropped from state so terraform.tfstate ends empty.
if [[ $(state_count) -gt 0 ]]; then
  log "retrying ${TF} destroy for $(state_count) remaining resources"
  tf_destroy 240 || true
fi
if [[ $(state_count) -gt 0 ]]; then
  log "dropping $(state_count) unreachable resources from state"
  "${TF}" state list -state="${STATE}" 2>/dev/null | grep -v '^data\.' | while read -r addr; do
    "${TF}" state rm -state="${STATE}" "${addr}" >/dev/null 2>&1 || true
  done
fi

# 4. Final sweep (log groups re-created by stopping workloads, async deletes).
sleep 3
python3 "${WORK_DIR}/sweep.py" "${CONFIG_PATH}" || true

left=$(state_count)
log "destroy complete; ${left} managed resources remain in state"
[[ "${left}" -eq 0 ]] || exit 1
exit 0
