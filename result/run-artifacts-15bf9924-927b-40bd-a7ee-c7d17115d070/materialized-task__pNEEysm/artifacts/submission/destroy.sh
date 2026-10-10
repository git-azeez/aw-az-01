#!/usr/bin/env bash
# ClearLedger teardown: removes everything scoped to resource_prefix; never touches cl-base-* resources.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${HERE}/infra"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
STATE="${INFRA}/terraform.tfstate"
export CLEARLEDGER_CONFIG="${CONFIG}"
export TF_IN_AUTOMATION=1 TF_INPUT=0
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

log() { printf '[destroy %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[[ -r "${CONFIG}" ]] || { echo "config not found: ${CONFIG}" >&2; exit 1; }
PREFIX="$(jq -r .resource_prefix "${CONFIG}")"
REGION="$(jq -r .region "${CONFIG}")"
ENDPOINT="$(jq -r .aws_endpoint_url "${CONFIG}")"
[[ -n "${PREFIX}" && "${PREFIX}" != "null" ]] || { echo "resource_prefix missing" >&2; exit 1; }
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}" AWS_ENDPOINT_URL="${ENDPOINT}"
export TF_VAR_config_file="${CONFIG}"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else TF=""; fi

exec 9>"${HERE}/.deploy.lock"
flock -w 600 9 || { echo "another deploy/destroy is running" >&2; exit 1; }

WORK="$(mktemp -d /tmp/clearledger-destroy.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
export PYTHONPATH="${WORK}" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

cat > "${WORK}/common.py" <<'PYEOF_common'
import json, os, sys, time, re, hashlib, datetime
import boto3
from botocore.config import Config

def log(tag, msg):
    print(f"[{tag}] {msg}", flush=True)

def load_cfg(path="/workspace/config/config.json"):
    with open(path) as f:
        return json.load(f)

def client(cfg, svc, **kw):
    return boto3.client(svc, endpoint_url=cfg["aws_endpoint_url"], region_name=cfg["region"],
                        aws_access_key_id="test", aws_secret_access_key="test",
                        config=Config(retries={"max_attempts": 5, "mode": "standard"},
                                      connect_timeout=10, read_timeout=120), **kw)

def state_resources(state_path):
    """Return {(type, name, index_key): attributes} from a local terraform state (best effort)."""
    out = {}
    try:
        with open(state_path) as f:
            st = json.load(f)
    except Exception:
        return out
    for r in st.get("resources", []):
        if r.get("mode") != "managed":
            continue
        for inst in r.get("instances", []):
            out[(r["type"], r["name"], inst.get("index_key"))] = inst.get("attributes", {})
    return out

PYEOF_common

cat > "${WORK}/iamfix.py" <<'PYEOF_iamfix'
from common import *

ROLE_KEYS = {"ecs_execution": "ecs-execution", "ecs_task": "ecs-task", "projector": "projector",
             "relay": "relay", "archiver": "archiver", "scheduler": "scheduler"}


def delete_policy_fully(iam, arn):
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v.get("IsDefaultVersion"):
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
        iam.delete_policy(PolicyArn=arn)
    except Exception as e:
        log("iam", f"could not delete policy {arn}: {e}")


def reconcile_iam(cfg):
    """Each of the six roles keeps only its canonical Terraform-managed inline policy."""
    prefix = cfg["resource_prefix"]
    iam = client(cfg, "iam")
    for key, slug in ROLE_KEYS.items():
        role = f"{prefix}-{slug}"
        canonical = f"{prefix}-{key}-policy"
        try:
            iam.get_role(RoleName=role)
        except Exception:
            continue
        for name in iam.list_role_policies(RoleName=role).get("PolicyNames", []):
            if name != canonical:
                log("iam", f"removing out-of-band inline policy {name} from {role}")
                iam.delete_role_policy(RoleName=role, PolicyName=name)
        for p in iam.list_attached_role_policies(RoleName=role).get("AttachedPolicies", []):
            log("iam", f"detaching out-of-band managed policy {p['PolicyName']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=p["PolicyArn"])
    # unattached prefix-scoped customer-managed policies
    try:
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            for p in page["Policies"]:
                if p["PolicyName"].startswith(prefix) and not p.get("AttachmentCount"):
                    log("iam", f"deleting unattached managed policy {p['PolicyName']}")
                    delete_policy_fully(iam, p["Arn"])
    except Exception as e:
        log("iam", f"policy listing failed: {e}")


def reconcile_sg(cfg, manifest):
    """Safety net behind Terraform's exclusive inline rules."""
    ec2 = client(cfg, "ec2")
    ids = manifest["network"]["security_group_ids"]
    groups = {g["GroupId"]: g for g in ec2.describe_security_groups(GroupIds=list(ids.values()))["SecurityGroups"]}

    def public(p):
        return any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or \
               any(r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", []))

    def revoke(gid, perms, egress):
        if not perms:
            return
        log("vpc", f"revoking {len(perms)} out-of-band {'egress' if egress else 'ingress'} rule(s) on {gid}")
        if egress:
            ec2.revoke_security_group_egress(GroupId=gid, IpPermissions=perms)
        else:
            ec2.revoke_security_group_ingress(GroupId=gid, IpPermissions=perms)

    for name, gid in ids.items():
        g = groups.get(gid)
        if not g:
            continue
        ing, egr = g.get("IpPermissions", []), g.get("IpPermissionsEgress", [])
        if name == "ecs":
            ok = lambda p: p.get("IpProtocol") == "tcp" and p.get("FromPort") == 8080 and p.get("ToPort") == 8080 \
                and not p.get("IpRanges") and not p.get("Ipv6Ranges") \
                and [x["GroupId"] for x in p.get("UserIdGroupPairs", [])] == [ids["alb"]]
            revoke(gid, [p for p in ing if not ok(p)], False)
        elif name in ("rds", "valkey"):
            revoke(gid, [p for p in ing if public(p)], False)
            revoke(gid, egr, True)
        elif name == "alb":
            revoke(gid, [p for p in egr if public(p)], True)

PYEOF_iamfix

cat > "${WORK}/cleanup.py" <<'PYEOF_cleanup'
"""Prefix-scoped teardown helpers (best effort, never touches cl-base-* resources)."""
import sys
from common import *

TAG = "destroy"


def safe(desc, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:
        msg = str(e).replace("\n", " ")[:200]
        log(TAG, f"{desc}: {msg}")
        return None


def mine(name, prefix):
    return bool(name) and (name == prefix or name.startswith(prefix + "-") or name.startswith(prefix + "_"))


def tagged(tags, prefix):
    if isinstance(tags, dict):
        return tags.get("ClearLedgerDeployment") == prefix
    for t in tags or []:
        if (t.get("Key") or t.get("TagKey") or t.get("key")) == "ClearLedgerDeployment" and \
                (t.get("Value") or t.get("TagValue") or t.get("value")) == prefix:
            return True
    return False


# ------------------------------------------------------------------ S3
def purge_bucket(cfg, bucket):
    s3 = client(cfg, "s3")
    safe(f"abort multipart uploads in {bucket}", _abort_uploads, s3, bucket)
    for _ in range(5):
        kw = {"Bucket": bucket}
        n = 0
        while True:
            r = s3.list_object_versions(**kw)
            objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in r.get("Versions", [])] + \
                   [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in r.get("DeleteMarkers", [])]
            for i in range(0, len(objs), 500):
                s3.delete_objects(Bucket=bucket, Delete={"Objects": objs[i:i + 500], "Quiet": True})
            n += len(objs)
            if not r.get("IsTruncated"):
                break
            kw["KeyMarker"] = r.get("NextKeyMarker")
            kw["VersionIdMarker"] = r.get("NextVersionIdMarker")
        # plain (unversioned) leftovers
        r = s3.list_objects_v2(Bucket=bucket)
        left = [{"Key": o["Key"]} for o in r.get("Contents", [])]
        if left:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": left, "Quiet": True})
        if n == 0 and not left:
            break


def _abort_uploads(s3, bucket):
    kw = {"Bucket": bucket}
    while True:
        r = s3.list_multipart_uploads(**kw)
        for u in r.get("Uploads", []):
            s3.abort_multipart_upload(Bucket=bucket, Key=u["Key"], UploadId=u["UploadId"])
        if not r.get("IsTruncated"):
            return
        kw["KeyMarker"] = r.get("NextKeyMarker")
        kw["UploadIdMarker"] = r.get("NextUploadIdMarker")


def prefix_buckets(cfg, prefix):
    s3 = client(cfg, "s3")
    r = safe("list buckets", s3.list_buckets) or {}
    return [b["Name"] for b in r.get("Buckets", []) if mine(b["Name"], prefix)]


# ------------------------------------------------------------------ Cognito
def cognito_pools(cfg, prefix):
    cg = client(cfg, "cognito-idp")
    pools, tok = [], None
    while True:
        kw = {"MaxResults": 60}
        if tok:
            kw["NextToken"] = tok
        r = safe("list user pools", cg.list_user_pools, **kw) or {}
        pools += [p for p in r.get("UserPools", []) if mine(p["Name"], prefix)]
        tok = r.get("NextToken")
        if not tok:
            return pools


def delete_pool_domains(cfg, prefix):
    cg = client(cfg, "cognito-idp")
    for p in cognito_pools(cfg, prefix):
        d = safe("describe user pool", cg.describe_user_pool, UserPoolId=p["Id"])
        dom = ((d or {}).get("UserPool") or {}).get("Domain")
        cd = ((d or {}).get("UserPool") or {}).get("CustomDomain")
        for name in filter(None, [dom, cd]):
            log(TAG, f"deleting user pool domain {name}")
            safe("delete_user_pool_domain", cg.delete_user_pool_domain, UserPoolId=p["Id"], Domain=name)


# ------------------------------------------------------------------ IAM
def delete_policy_fully(iam, arn):
    for v in (safe("list policy versions", iam.list_policy_versions, PolicyArn=arn) or {}).get("Versions", []):
        if not v.get("IsDefaultVersion"):
            safe("delete policy version", iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
    safe(f"delete policy {arn}", iam.delete_policy, PolicyArn=arn)


def clean_iam(cfg, prefix, delete_roles):
    iam = client(cfg, "iam")
    roles = []
    for page in iam.get_paginator("list_roles").paginate():
        roles += [r["RoleName"] for r in page["Roles"] if mine(r["RoleName"], prefix)]
    for role in roles:
        for n in (safe("list role policies", iam.list_role_policies, RoleName=role) or {}).get("PolicyNames", []):
            if delete_roles or not n.startswith(prefix):
                safe(f"delete inline policy {n}", iam.delete_role_policy, RoleName=role, PolicyName=n)
        for p in (safe("list attached", iam.list_attached_role_policies, RoleName=role) or {}).get("AttachedPolicies", []):
            safe(f"detach {p['PolicyName']}", iam.detach_role_policy, RoleName=role, PolicyArn=p["PolicyArn"])
        for ip in (safe("list instance profiles for role", iam.list_instance_profiles_for_role, RoleName=role) or {}).get("InstanceProfiles", []):
            safe("remove role from instance profile", iam.remove_role_from_instance_profile,
                 InstanceProfileName=ip["InstanceProfileName"], RoleName=role)
    # instance profiles scoped to the prefix
    for page in iam.get_paginator("list_instance_profiles").paginate():
        for ip in page["InstanceProfiles"]:
            if not mine(ip["InstanceProfileName"], prefix):
                continue
            for r in ip.get("Roles", []):
                safe("remove role from instance profile", iam.remove_role_from_instance_profile,
                     InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
            log(TAG, f"deleting instance profile {ip['InstanceProfileName']}")
            safe("delete_instance_profile", iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
    if delete_roles:
        for role in roles:
            log(TAG, f"deleting role {role}")
            safe(f"delete role {role}", iam.delete_role, RoleName=role)
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            if not mine(p["PolicyName"], prefix):
                continue
            if p.get("AttachmentCount"):
                for ent in (safe("entities for policy", iam.list_entities_for_policy, PolicyArn=p["Arn"]) or {}).get("PolicyRoles", []):
                    safe("detach", iam.detach_role_policy, RoleName=ent["RoleName"], PolicyArn=p["Arn"])
            log(TAG, f"deleting managed policy {p['PolicyName']}")
            delete_policy_fully(iam, p["Arn"])


# ------------------------------------------------------------------ ECS
def clean_ecs(cfg, prefix):
    ecs = client(cfg, "ecs")
    clusters = []
    for page in ecs.get_paginator("list_clusters").paginate():
        clusters += [a for a in page["clusterArns"] if mine(a.split("/")[-1], prefix)]
    for c in clusters:
        svcs = []
        for page in ecs.get_paginator("list_services").paginate(cluster=c):
            svcs += page["serviceArns"]
        for s in svcs:
            safe(f"scale service {s}", ecs.update_service, cluster=c, service=s, desiredCount=0)
            safe(f"delete service {s}", ecs.delete_service, cluster=c, service=s, force=True)
        for page in ecs.get_paginator("list_tasks").paginate(cluster=c):
            for t in page["taskArns"]:
                safe("stop task", ecs.stop_task, cluster=c, task=t)
        for _ in range(30):
            left = [s for s in (safe("describe services", ecs.describe_services, cluster=c, services=svcs[:10]) or {}).get("services", [])
                    if s.get("status") != "INACTIVE"] if svcs else []
            if not left:
                break
            time.sleep(1)
        log(TAG, f"deleting ECS cluster {c.split('/')[-1]}")
        safe("delete cluster", ecs.delete_cluster, cluster=c)
    clean_task_definitions(cfg, prefix)


def clean_task_definitions(cfg, prefix):
    ecs = client(cfg, "ecs")
    fams = set()
    for page in ecs.get_paginator("list_task_definition_families").paginate(familyPrefix=prefix, status="ALL"):
        fams |= {f for f in page["families"] if mine(f, prefix)}
    for fam in fams:
        arns = []
        for st in ("ACTIVE", "INACTIVE"):
            for page in ecs.get_paginator("list_task_definitions").paginate(familyPrefix=fam, status=st):
                arns += [(a, st) for a in page["taskDefinitionArns"]]
        for a, st in arns:
            if st == "ACTIVE":
                safe(f"deregister {a}", ecs.deregister_task_definition, taskDefinition=a)
        allarns = [a for a, _ in arns]
        for i in range(0, len(allarns), 10):
            safe("delete_task_definitions", ecs.delete_task_definitions, taskDefinitions=allarns[i:i + 10])
        log(TAG, f"removed {len(allarns)} task definition revisions of {fam}")


# ------------------------------------------------------------------ everything else
def sweep(cfg, prefix):
    sc = client(cfg, "scheduler")
    for grp in ["default"] + [g["Name"] for g in (safe("list schedule groups", sc.list_schedule_groups) or {}).get("ScheduleGroups", []) if mine(g["Name"], prefix)]:
        for s in (safe("list schedules", sc.list_schedules, GroupName=grp, NamePrefix=prefix) or {}).get("Schedules", []):
            if mine(s["Name"], prefix):
                log(TAG, f"deleting schedule {s['Name']}")
                safe("delete schedule", sc.delete_schedule, Name=s["Name"], GroupName=grp)
        if grp != "default":
            safe("delete schedule group", sc.delete_schedule_group, Name=grp)

    lam = client(cfg, "lambda")
    for page in lam.get_paginator("list_functions").paginate():
        for f in page["Functions"]:
            if not mine(f["FunctionName"], prefix):
                continue
            for m in (safe("list ESMs", lam.list_event_source_mappings, FunctionName=f["FunctionName"]) or {}).get("EventSourceMappings", []):
                log(TAG, f"deleting event source mapping {m['UUID']}")
                safe("delete ESM", lam.delete_event_source_mapping, UUID=m["UUID"])
            log(TAG, f"deleting lambda {f['FunctionName']}")
            safe("delete function", lam.delete_function, FunctionName=f["FunctionName"])

    clean_ecs(cfg, prefix)

    elb = client(cfg, "elbv2")
    for lb in (safe("describe LBs", elb.describe_load_balancers) or {}).get("LoadBalancers", []):
        if mine(lb["LoadBalancerName"], prefix):
            for l in (safe("describe listeners", elb.describe_listeners, LoadBalancerArn=lb["LoadBalancerArn"]) or {}).get("Listeners", []):
                safe("delete listener", elb.delete_listener, ListenerArn=l["ListenerArn"])
            log(TAG, f"deleting load balancer {lb['LoadBalancerName']}")
            safe("delete LB", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    time.sleep(1)
    for tg in (safe("describe TGs", elb.describe_target_groups) or {}).get("TargetGroups", []):
        if mine(tg["TargetGroupName"], prefix):
            log(TAG, f"deleting target group {tg['TargetGroupName']}")
            safe("delete TG", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])

    rds = client(cfg, "rds")
    for db in (safe("describe DBs", rds.describe_db_instances) or {}).get("DBInstances", []):
        if mine(db["DBInstanceIdentifier"], prefix):
            log(TAG, f"deleting RDS instance {db['DBInstanceIdentifier']}")
            safe("delete DB", rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    for _ in range(90):
        left = [d for d in (safe("describe DBs", rds.describe_db_instances) or {}).get("DBInstances", [])
                if mine(d["DBInstanceIdentifier"], prefix)]
        if not left:
            break
        time.sleep(2)
    for sn in (safe("describe snapshots", rds.describe_db_snapshots) or {}).get("DBSnapshots", []):
        if mine(sn["DBSnapshotIdentifier"], prefix):
            safe("delete snapshot", rds.delete_db_snapshot, DBSnapshotIdentifier=sn["DBSnapshotIdentifier"])
    for g in (safe("describe subnet groups", rds.describe_db_subnet_groups) or {}).get("DBSubnetGroups", []):
        if mine(g["DBSubnetGroupName"], prefix):
            safe("delete db subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])

    ec = client(cfg, "elasticache")
    for g in (safe("describe replication groups", ec.describe_replication_groups) or {}).get("ReplicationGroups", []):
        if mine(g["ReplicationGroupId"], prefix):
            log(TAG, f"deleting replication group {g['ReplicationGroupId']}")
            safe("delete RG", ec.delete_replication_group, ReplicationGroupId=g["ReplicationGroupId"])
    for cl in (safe("describe cache clusters", ec.describe_cache_clusters) or {}).get("CacheClusters", []):
        if mine(cl["CacheClusterId"], prefix):
            safe("delete cache cluster", ec.delete_cache_cluster, CacheClusterId=cl["CacheClusterId"])
    for _ in range(60):
        left = [g for g in (safe("describe RGs", ec.describe_replication_groups) or {}).get("ReplicationGroups", [])
                if mine(g["ReplicationGroupId"], prefix)]
        if not left:
            break
        time.sleep(2)
    for g in (safe("describe cache subnet groups", ec.describe_cache_subnet_groups) or {}).get("CacheSubnetGroups", []):
        if mine(g["CacheSubnetGroupName"], prefix):
            safe("delete cache subnet group", ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])

    ddb = client(cfg, "dynamodb")
    for page in ddb.get_paginator("list_tables").paginate():
        for t in page["TableNames"]:
            if mine(t, prefix):
                log(TAG, f"deleting DynamoDB table {t}")
                safe("delete table", ddb.delete_table, TableName=t)

    sqs = client(cfg, "sqs")
    for u in (safe("list queues", sqs.list_queues, QueueNamePrefix=prefix) or {}).get("QueueUrls", []):
        if mine(u.rsplit("/", 1)[-1], prefix):
            log(TAG, f"deleting queue {u}")
            safe("delete queue", sqs.delete_queue, QueueUrl=u)

    s3 = client(cfg, "s3")
    for b in prefix_buckets(cfg, prefix):
        purge_bucket(cfg, b)
        log(TAG, f"deleting bucket {b}")
        safe("delete bucket", s3.delete_bucket, Bucket=b)

    cg = client(cfg, "cognito-idp")
    delete_pool_domains(cfg, prefix)
    for p in cognito_pools(cfg, prefix):
        log(TAG, f"deleting user pool {p['Name']}")
        safe("delete user pool", cg.delete_user_pool, UserPoolId=p["Id"])

    logs = client(cfg, "logs")
    for pre in (f"/clearledger/{prefix}/", f"/aws/lambda/{prefix}-", f"/ecs/{prefix}-", f"/aws/ecs/{prefix}-",
                f"/aws/rds/instance/{prefix}-", f"/aws/elasticache/cluster/{prefix}-", f"/aws/elasticache/{prefix}-"):
        for page in logs.get_paginator("describe_log_groups").paginate(logGroupNamePrefix=pre):
            for g in page["logGroups"]:
                log(TAG, f"deleting log group {g['logGroupName']}")
                safe("delete log group", logs.delete_log_group, logGroupName=g["logGroupName"])

    clean_iam(cfg, prefix, True)

    kms = client(cfg, "kms")
    for page in kms.get_paginator("list_aliases").paginate():
        for a in page["Aliases"]:
            if a["AliasName"].startswith(f"alias/{prefix}-"):
                safe("delete alias", kms.delete_alias, AliasName=a["AliasName"])
    for page in kms.get_paginator("list_keys").paginate():
        for k in page["Keys"]:
            kid = k["KeyId"]
            md = (safe("describe key", kms.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
            if md.get("KeyManager") != "CUSTOMER" or md.get("KeyState") == "PendingDeletion":
                continue
            tags = (safe("list tags", kms.list_resource_tags, KeyId=kid) or {}).get("Tags", [])
            if tagged(tags, prefix):
                log(TAG, f"scheduling KMS key {kid} for deletion")
                safe("schedule key deletion", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)

    clean_vpc(cfg, prefix)


def clean_vpc(cfg, prefix):
    ec2 = client(cfg, "ec2")
    f = [{"Name": "tag:ClearLedgerDeployment", "Values": [prefix]}]
    vpcs = [v["VpcId"] for v in (safe("describe vpcs", ec2.describe_vpcs, Filters=f) or {}).get("Vpcs", [])]
    for v in (safe("describe vpcs", ec2.describe_vpcs) or {}).get("Vpcs", []):
        name = next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), "")
        if mine(name, prefix) and v["VpcId"] not in vpcs:
            vpcs.append(v["VpcId"])
    for vpc in vpcs:
        vf = [{"Name": "vpc-id", "Values": [vpc]}]
        sgs = (safe("describe sgs", ec2.describe_security_groups, Filters=vf) or {}).get("SecurityGroups", [])
        for g in sgs:
            if g["GroupName"] == "default":
                continue
            if g.get("IpPermissions"):
                safe("revoke ingress", ec2.revoke_security_group_ingress, GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
            if g.get("IpPermissionsEgress"):
                safe("revoke egress", ec2.revoke_security_group_egress, GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
        for g in sgs:
            if g["GroupName"] != "default":
                log(TAG, f"deleting security group {g['GroupName']}")
                safe("delete sg", ec2.delete_security_group, GroupId=g["GroupId"])
        for rt in (safe("describe route tables", ec2.describe_route_tables, Filters=vf) or {}).get("RouteTables", []):
            if any(a.get("Main") for a in rt.get("Associations", [])):
                continue
            for a in rt.get("Associations", []):
                safe("disassociate rt", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            safe("delete route table", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        for igw in (safe("describe igws", ec2.describe_internet_gateways, Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]) or {}).get("InternetGateways", []):
            safe("detach igw", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
            safe("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in (safe("describe subnets", ec2.describe_subnets, Filters=vf) or {}).get("Subnets", []):
            safe("delete subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
        log(TAG, f"deleting VPC {vpc}")
        safe("delete vpc", ec2.delete_vpc, VpcId=vpc)
    # orphan tagged resources outside a (deleted) VPC
    for sn in (safe("describe subnets", ec2.describe_subnets, Filters=f) or {}).get("Subnets", []):
        safe("delete subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
    for g in (safe("describe sgs", ec2.describe_security_groups, Filters=f) or {}).get("SecurityGroups", []):
        safe("delete sg", ec2.delete_security_group, GroupId=g["GroupId"])
    for igw in (safe("describe igws", ec2.describe_internet_gateways, Filters=f) or {}).get("InternetGateways", []):
        safe("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])


def pre(cfg):
    prefix = cfg["resource_prefix"]
    for b in prefix_buckets(cfg, prefix):
        log(TAG, f"emptying bucket {b} (versions, delete markers, multipart uploads)")
        safe("purge bucket", purge_bucket, cfg, b)
    delete_pool_domains(cfg, prefix)
    safe("clean IAM extras", clean_iam, cfg, prefix, False)
    safe("clean task definitions", clean_ecs_services_only, cfg, prefix)


def clean_ecs_services_only(cfg, prefix):
    ecs = client(cfg, "ecs")
    for page in ecs.get_paginator("list_clusters").paginate():
        for c in page["clusterArns"]:
            if not mine(c.split("/")[-1], prefix):
                continue
            for sp in ecs.get_paginator("list_services").paginate(cluster=c):
                for s in sp["serviceArns"]:
                    safe("scale to zero", ecs.update_service, cluster=c, service=s, desiredCount=0)


if __name__ == "__main__":
    cfg = load_cfg(os.environ.get("CLEARLEDGER_CONFIG", "/workspace/config/config.json"))
    phase = sys.argv[1]
    if phase == "pre":
        pre(cfg)
    elif phase == "sweep":
        sweep(cfg, cfg["resource_prefix"])

PYEOF_cleanup


log "prefix=${PREFIX}"
log "pre-destroy cleanup (S3 versions/markers/multipart uploads, Cognito domains, IAM extras)"
python3 "${WORK}/cleanup.py" pre || true

tf_state_count() {
  if [[ -n "${TF}" && -f "${STATE}" ]]; then
    ( cd "${INFRA}" && "${TF}" state list 2>/dev/null | wc -l ) || echo 0
  else
    echo 0
  fi
}

if [[ -n "${TF}" && -d "${INFRA}" ]]; then
  ( cd "${INFRA}" && "${TF}" init -input=false -no-color >/dev/null ) || log "terraform init failed (continuing with sweep)"
  if [[ -f "${STATE}" && "$(tf_state_count)" != "0" ]]; then
    for attempt in 1 2; do
      log "terraform destroy (attempt ${attempt})"
      if ( cd "${INFRA}" && timeout 600 "${TF}" destroy -auto-approve -input=false -no-color -lock-timeout=60s \
              -var "config_file=${CONFIG}" ); then
        break
      fi
      log "terraform destroy failed; sweeping scoped resources before retrying"
      python3 "${WORK}/cleanup.py" sweep || true
    done
  fi
fi

log "sweeping remaining out-of-band resources scoped to ${PREFIX}"
python3 "${WORK}/cleanup.py" sweep || true

if [[ -n "${TF}" && -f "${STATE}" && "$(tf_state_count)" != "0" ]]; then
  log "state still lists resources; refreshing against the (now empty) control plane"
  ( cd "${INFRA}" && timeout 300 "${TF}" destroy -auto-approve -input=false -no-color -lock-timeout=60s \
        -var "config_file=${CONFIG}" ) || true
  if [[ "$(tf_state_count)" != "0" ]]; then
    log "removing already-deleted resources from state"
    ( cd "${INFRA}" && "${TF}" state list | xargs -r "${TF}" state rm >/dev/null ) || true
  fi
fi

log "remaining managed resources in state: $(tf_state_count)"
log "destroy complete"
