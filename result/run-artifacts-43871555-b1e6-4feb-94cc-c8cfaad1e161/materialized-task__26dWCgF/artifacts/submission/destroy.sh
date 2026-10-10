#!/usr/bin/env bash
# ClearLedger teardown: Terraform/OpenTofu destroy plus a prefix-scoped sweep of
# out-of-band resources. Leaves cl-base-* baseline resources untouched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/infra"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"

log() { printf '[destroy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
command -v jq >/dev/null || die "jq is required"

PYTHON=""
for cand in python3 /opt/venv/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import boto3' >/dev/null 2>&1; then PYTHON="$cand"; break; fi
done
[ -n "$PYTHON" ] || die "no python3 with boto3 available"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "neither terraform nor tofu found"; fi

REGION="$(jq -r .region "$CONFIG_FILE")"
PREFIX="$(jq -r .resource_prefix "$CONFIG_FILE")"
ENDPOINT="$(jq -r .aws_endpoint_url "$CONFIG_FILE")"
[ -n "$PREFIX" ] && [ "$PREFIX" != "null" ] && [ "${#PREFIX}" -ge 4 ] || die "invalid resource_prefix in config"

export AWS_ENDPOINT_URL="$ENDPOINT" AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0 TF_VAR_config_file="$CONFIG_FILE"
export NO_PROXY="${NO_PROXY:-},aws" no_proxy="${no_proxy:-},aws"

exec 9>"/tmp/clearledger-deploy-${PREFIX}.lock"
flock -w 600 9 || die "another deploy/destroy is running"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/sweep.py" <<'PYEOF'
#!/usr/bin/env python3
"""Prefix-scoped cleanup of anything the ClearLedger deployment (or an operator
drill) left behind. Usage: sweep.py CONFIG {pre|post|check}

Only resources whose name starts with <resource_prefix> (or that carry the tag
ClearLedgerDeployment=<resource_prefix>) are touched; cl-base-* is never matched.
"""
import json
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

cfg = json.load(open(sys.argv[1]))
MODE = sys.argv[2]
PREFIX = cfg["resource_prefix"]
assert len(PREFIX) >= 4, "refusing to sweep with a short prefix"
TAG = "ClearLedgerDeployment"
BCFG = Config(retries={"max_attempts": 8, "mode": "standard"})
CANON_ROLES = {PREFIX + "-" + s for s in ("ecs-execution", "ecs-task", "projector", "relay", "archiver", "scheduler")}


def client(name):
    return boto3.client(name, endpoint_url=cfg["aws_endpoint_url"], region_name=cfg["region"],
                        aws_access_key_id="test", aws_secret_access_key="test", config=BCFG)


def log(msg):
    print("[sweep %s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


GONE = ("NoSuchEntity", "NoSuchEntityException", "NotFound", "ResourceNotFoundException", "NoSuchBucket",
        "AWS.SimpleQueueService.NonExistentQueue", "QueueDoesNotExist", "ParameterNotFound", "DBInstanceNotFound",
        "DBInstanceNotFoundFault", "ReplicationGroupNotFoundFault", "ReplicationGroupNotFound", "LoadBalancerNotFound",
        "LoadBalancerNotFoundException", "TargetGroupNotFound", "TargetGroupNotFoundException", "ListenerNotFound",
        "ClusterNotFoundException", "ServiceNotFoundException", "InvalidVpcID.NotFound", "InvalidGroup.NotFound",
        "InvalidSubnetID.NotFound", "InvalidInternetGatewayID.NotFound", "InvalidRouteTableID.NotFound",
        "DBSubnetGroupNotFoundFault", "DBSubnetGroupNotFound", "CacheSubnetGroupNotFoundFault", "CacheSubnetGroupNotFound",
        "NotFoundException", "KMSInvalidStateException", "InvalidAssociationID.NotFound", "ResourceNotFound",
        "InvalidPermission.NotFound", "ResourceNotFoundFault", "ConflictException404")
failures = []


def safe(desc, fn, *a, **kw):
    """Run fn; swallow 'already gone' errors; record other errors."""
    try:
        return fn(*a, **kw)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in GONE:
            return None
        log("WARN %s: %s" % (desc, exc))
        failures.append(desc)
    except Exception as exc:  # noqa: BLE001
        log("WARN %s: %s" % (desc, exc))
        failures.append(desc)
    return None


def mine(name):
    """Exact prefix match on a name component: <prefix> or <prefix>-..."""
    return name is not None and (name == PREFIX or name.startswith(PREFIX + "-"))


def mine_log_group(name):
    import re
    return re.search(r"(^|/)" + re.escape(PREFIX) + r"($|[-/])", name) is not None


iam, s3, sqs, ddb, logs, kms = (client(n) for n in ("iam", "s3", "sqs", "dynamodb", "logs", "kms"))
lam, sch, ecs, elb, rds, ec, ec2, cog = (client(n) for n in
                                         ("lambda", "scheduler", "ecs", "elbv2", "rds", "elasticache", "ec2", "cognito-idp"))


# --------------------------------------------------------------------------
# IAM
# --------------------------------------------------------------------------
def delete_policy_fully(arn):
    ents = iam.list_entities_for_policy(PolicyArn=arn)
    for r in ents.get("PolicyRoles", []):
        safe("detach role", iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
    for u in ents.get("PolicyUsers", []):
        safe("detach user", iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
    for g in ents.get("PolicyGroups", []):
        safe("detach group", iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
    for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
        if not v["IsDefaultVersion"]:
            safe("policy version", iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
    iam.delete_policy(PolicyArn=arn)


def delete_role_fully(name):
    for n in iam.list_role_policies(RoleName=name).get("PolicyNames", []):
        iam.delete_role_policy(RoleName=name, PolicyName=n)
    for p in iam.list_attached_role_policies(RoleName=name).get("AttachedPolicies", []):
        iam.detach_role_policy(RoleName=name, PolicyArn=p["PolicyArn"])
    for ip in iam.list_instance_profiles_for_role(RoleName=name).get("InstanceProfiles", []):
        safe("remove role from profile", iam.remove_role_from_instance_profile,
             InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
        if mine(ip["InstanceProfileName"]):
            safe("delete instance profile", iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
    iam.delete_role(RoleName=name)


def iam_pre():
    for page in iam.get_paginator("list_roles").paginate():
        for r in page["Roles"]:
            name = r["RoleName"]
            if not mine(name):
                continue
            if name in CANON_ROLES:
                for n in iam.list_role_policies(RoleName=name).get("PolicyNames", []):
                    if n != name:
                        log("removing out-of-band inline policy %s from %s" % (n, name))
                        safe("inline policy", iam.delete_role_policy, RoleName=name, PolicyName=n)
                for p in iam.list_attached_role_policies(RoleName=name).get("AttachedPolicies", []):
                    log("detaching %s from %s" % (p["PolicyArn"], name))
                    safe("detach", iam.detach_role_policy, RoleName=name, PolicyArn=p["PolicyArn"])
            else:
                log("deleting out-of-band role %s" % name)
                safe("delete role " + name, delete_role_fully, name)
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            if mine(p["PolicyName"]):
                log("deleting customer-managed policy %s" % p["PolicyName"])
                safe("delete policy " + p["PolicyName"], delete_policy_fully, p["Arn"])


def iam_post():
    for page in iam.get_paginator("list_roles").paginate():
        for r in page["Roles"]:
            if mine(r["RoleName"]):
                log("deleting leftover role %s" % r["RoleName"])
                safe("delete role " + r["RoleName"], delete_role_fully, r["RoleName"])
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            if mine(p["PolicyName"]):
                safe("delete policy " + p["PolicyName"], delete_policy_fully, p["Arn"])
    for page in iam.get_paginator("list_instance_profiles").paginate():
        for ip in page["InstanceProfiles"]:
            if mine(ip["InstanceProfileName"]):
                for r in ip.get("Roles", []):
                    safe("profile role", iam.remove_role_from_instance_profile,
                         InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
                safe("instance profile", iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])


# --------------------------------------------------------------------------
# S3 (versioned buckets)
# --------------------------------------------------------------------------
def purge_bucket(bucket):
    while True:
        r = s3.list_object_versions(Bucket=bucket, MaxKeys=1000)
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in r.get("Versions", []) + r.get("DeleteMarkers", [])]
        if not objs:
            break
        res = s3.delete_objects(Bucket=bucket, Delete={"Objects": objs, "Quiet": True})
        if res.get("Errors"):
            raise RuntimeError("delete_objects errors: %s" % res["Errors"][:2])
    # unversioned leftovers (e.g. written before versioning was enabled)
    while True:
        r = s3.list_objects_v2(Bucket=bucket, MaxKeys=1000)
        objs = [{"Key": o["Key"]} for o in r.get("Contents", [])]
        if not objs:
            break
        s3.delete_objects(Bucket=bucket, Delete={"Objects": objs, "Quiet": True})


def s3_purge_all(delete=False):
    for b in s3.list_buckets().get("Buckets", []):
        if mine(b["Name"]):
            log("purging bucket %s" % b["Name"])
            safe("purge " + b["Name"], purge_bucket, b["Name"])
            if delete:
                safe("delete bucket " + b["Name"], s3.delete_bucket, Bucket=b["Name"])


# --------------------------------------------------------------------------
# Everything else (post-destroy leftovers)
# --------------------------------------------------------------------------
def lambdas():
    for page in lam.get_paginator("list_functions").paginate():
        for f in page["Functions"]:
            if mine(f["FunctionName"]):
                for e in lam.list_event_source_mappings(FunctionName=f["FunctionName"]).get("EventSourceMappings", []):
                    safe("esm", lam.delete_event_source_mapping, UUID=e["UUID"])
                log("deleting lambda %s" % f["FunctionName"])
                safe("lambda " + f["FunctionName"], lam.delete_function, FunctionName=f["FunctionName"])


def schedules():
    groups = [g["Name"] for g in sch.list_schedule_groups().get("ScheduleGroups", [])]
    for g in groups:
        for s in sch.list_schedules(GroupName=g, NamePrefix=PREFIX).get("Schedules", []):
            if not mine(s["Name"]):
                continue
            log("deleting schedule %s" % s["Name"])
            safe("schedule", sch.delete_schedule, Name=s["Name"], GroupName=g)
        if mine(g):
            safe("schedule group", sch.delete_schedule_group, Name=g)


def ecs_all():
    for arn in ecs.list_clusters().get("clusterArns", []):
        name = arn.split("/")[-1]
        if not mine(name):
            continue
        for sarn in ecs.list_services(cluster=arn).get("serviceArns", []):
            log("deleting ecs service %s" % sarn.split("/")[-1])
            safe("ecs update", ecs.update_service, cluster=arn, service=sarn, desiredCount=0)
            safe("ecs service", ecs.delete_service, cluster=arn, service=sarn, force=True)
        for t in ecs.list_tasks(cluster=arn).get("taskArns", []):
            safe("ecs stop task", ecs.stop_task, cluster=arn, task=t)
        log("deleting ecs cluster %s" % name)
        safe("ecs cluster", ecs.delete_cluster, cluster=arn)
    for status in ("ACTIVE", "INACTIVE"):
        for page in ecs.get_paginator("list_task_definitions").paginate(status=status):
            for arn in page["taskDefinitionArns"]:
                fam = arn.split("/")[-1]
                if mine(fam):
                    if status == "ACTIVE":
                        safe("deregister td", ecs.deregister_task_definition, taskDefinition=arn)
                    safe("delete td", ecs.delete_task_definitions, taskDefinitions=[arn])


def load_balancers():
    for lb in elb.describe_load_balancers().get("LoadBalancers", []):
        if mine(lb["LoadBalancerName"]):
            for ls in elb.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", []):
                safe("listener", elb.delete_listener, ListenerArn=ls["ListenerArn"])
            log("deleting load balancer %s" % lb["LoadBalancerName"])
            safe("lb", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    time.sleep(2)
    for tg in elb.describe_target_groups().get("TargetGroups", []):
        if mine(tg["TargetGroupName"]):
            log("deleting target group %s" % tg["TargetGroupName"])
            safe("tg", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])


def databases():
    for db in rds.describe_db_instances().get("DBInstances", []):
        if mine(db["DBInstanceIdentifier"]):
            log("deleting rds instance %s" % db["DBInstanceIdentifier"])
            safe("rds", rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    deadline = time.time() + 240
    while time.time() < deadline:
        left = [d for d in rds.describe_db_instances().get("DBInstances", []) if mine(d["DBInstanceIdentifier"])]
        if not left:
            break
        time.sleep(4)
    for g in rds.describe_db_subnet_groups().get("DBSubnetGroups", []):
        if mine(g["DBSubnetGroupName"]):
            safe("db subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    for p in rds.describe_db_parameter_groups().get("DBParameterGroups", []):
        if mine(p["DBParameterGroupName"]):
            safe("db parameter group", rds.delete_db_parameter_group, DBParameterGroupName=p["DBParameterGroupName"])


def caches():
    for rg in ec.describe_replication_groups().get("ReplicationGroups", []):
        if mine(rg["ReplicationGroupId"]):
            log("deleting replication group %s" % rg["ReplicationGroupId"])
            safe("replication group", ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"])
    for cc in ec.describe_cache_clusters().get("CacheClusters", []):
        if mine(cc["CacheClusterId"]):
            safe("cache cluster", ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])
    deadline = time.time() + 180
    while time.time() < deadline:
        left = [r for r in ec.describe_replication_groups().get("ReplicationGroups", []) if mine(r["ReplicationGroupId"])]
        if not left:
            break
        time.sleep(4)
    for g in ec.describe_cache_subnet_groups().get("CacheSubnetGroups", []):
        if mine(g["CacheSubnetGroupName"]):
            safe("cache subnet group", ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])


def tables():
    for page in ddb.get_paginator("list_tables").paginate():
        for t in page["TableNames"]:
            if mine(t):
                log("deleting dynamodb table %s" % t)
                safe("table " + t, ddb.delete_table, TableName=t)


def queues():
    for u in sqs.list_queues(QueueNamePrefix=PREFIX).get("QueueUrls", []):
        if not mine(u.rsplit("/", 1)[-1]):
            continue
        log("deleting queue %s" % u)
        safe("queue " + u, sqs.delete_queue, QueueUrl=u)


def log_groups():
    for page in logs.get_paginator("describe_log_groups").paginate():
        for g in page["logGroups"]:
            n = g["logGroupName"]
            if mine_log_group(n):
                log("deleting log group %s" % n)
                safe("log group " + n, logs.delete_log_group, logGroupName=n)


def cognito():
    for p in cog.list_user_pools(MaxResults=60).get("UserPools", []):
        if mine(p["Name"]):
            d = cog.describe_user_pool(UserPoolId=p["Id"])["UserPool"]
            if d.get("Domain"):
                safe("pool domain", cog.delete_user_pool_domain, Domain=d["Domain"], UserPoolId=p["Id"])
            log("deleting user pool %s" % p["Name"])
            safe("user pool", cog.delete_user_pool, UserPoolId=p["Id"])


def kms_all():
    keys = {}
    for page in kms.get_paginator("list_aliases").paginate():
        for a in page["Aliases"]:
            if mine(a["AliasName"][len("alias/"):]):
                log("deleting alias %s" % a["AliasName"])
                safe("alias", kms.delete_alias, AliasName=a["AliasName"])
                if a.get("TargetKeyId"):
                    keys[a["TargetKeyId"]] = True
    for page in kms.get_paginator("list_keys").paginate():
        for k in page["Keys"]:
            kid = k["KeyId"]
            try:
                md = kms.describe_key(KeyId=kid)["KeyMetadata"]
                tags = {t["TagKey"]: t["TagValue"] for t in kms.list_resource_tags(KeyId=kid).get("Tags", [])}
            except ClientError:
                continue
            if md.get("KeyManager") == "AWS":
                continue
            if tags.get(TAG) == PREFIX or "(%s)" % PREFIX in (md.get("Description") or ""):
                keys[kid] = True
    for kid in keys:
        try:
            md = kms.describe_key(KeyId=kid)["KeyMetadata"]
        except ClientError:
            continue
        if md.get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
            continue
        log("scheduling deletion of kms key %s" % kid)
        safe("kms key", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=10)


def network():
    vpcs = [v for v in ec2.describe_vpcs().get("Vpcs", [])
            if any(t["Key"] == TAG and t["Value"] == PREFIX for t in v.get("Tags", []))
            or mine(next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), ""))]
    for v in vpcs:
        vid = v["VpcId"]
        log("removing vpc %s" % vid)
        flt = [{"Name": "vpc-id", "Values": [vid]}]
        for eni in ec2.describe_network_interfaces(Filters=flt).get("NetworkInterfaces", []):
            safe("eni", ec2.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"])
        sgs = [g for g in ec2.describe_security_groups(Filters=flt).get("SecurityGroups", []) if g["GroupName"] != "default"]
        for g in sgs:  # break cross references first
            if g.get("IpPermissions"):
                safe("sg ingress", ec2.revoke_security_group_ingress, GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
            if g.get("IpPermissionsEgress"):
                safe("sg egress", ec2.revoke_security_group_egress, GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
        for g in sgs:
            safe("sg " + g["GroupId"], ec2.delete_security_group, GroupId=g["GroupId"])
        for rt in ec2.describe_route_tables(Filters=flt).get("RouteTables", []):
            if any(a.get("Main") for a in rt.get("Associations", [])):
                continue
            for a in rt.get("Associations", []):
                safe("rt assoc", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            safe("rt", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        for igw in ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vid]}]).get("InternetGateways", []):
            safe("igw detach", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vid)
            safe("igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in ec2.describe_subnets(Filters=flt).get("Subnets", []):
            safe("subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
        safe("vpc " + vid, ec2.delete_vpc, VpcId=vid)
    # orphans outside a tagged VPC
    for g in ec2.describe_security_groups().get("SecurityGroups", []):
        if mine(g["GroupName"]):
            safe("orphan sg", ec2.delete_security_group, GroupId=g["GroupId"])


def post():
    s3_purge_all(delete=True)
    for fn in (schedules, lambdas, ecs_all, load_balancers, databases, caches, tables, queues, cognito):
        safe(fn.__name__, fn)
    iam_post()
    safe("log_groups", log_groups)
    safe("kms", kms_all)
    safe("network", network)


def leftovers():
    left = []
    for page in iam.get_paginator("list_roles").paginate():
        left += ["iam role " + r["RoleName"] for r in page["Roles"] if mine(r["RoleName"])]
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        left += ["iam policy " + p["PolicyName"] for p in page["Policies"] if mine(p["PolicyName"])]
    left += ["bucket " + b["Name"] for b in s3.list_buckets().get("Buckets", []) if mine(b["Name"])]
    left += ["queue " + u for u in sqs.list_queues(QueueNamePrefix=PREFIX).get("QueueUrls", [])]
    for page in ddb.get_paginator("list_tables").paginate():
        left += ["table " + t for t in page["TableNames"] if mine(t)]
    for page in logs.get_paginator("describe_log_groups").paginate():
        left += ["log group " + g["logGroupName"] for g in page["logGroups"] if mine_log_group(g["logGroupName"])]
    for page in lam.get_paginator("list_functions").paginate():
        left += ["lambda " + f["FunctionName"] for f in page["Functions"] if mine(f["FunctionName"])]
    for g in sch.list_schedule_groups().get("ScheduleGroups", []):
        left += ["schedule " + s["Name"] for s in sch.list_schedules(GroupName=g["Name"], NamePrefix=PREFIX).get("Schedules", [])]
    left += ["ecs cluster " + a for a in ecs.list_clusters().get("clusterArns", []) if mine(a.split("/")[-1])]
    left += ["load balancer " + lb["LoadBalancerName"] for lb in elb.describe_load_balancers().get("LoadBalancers", []) if mine(lb["LoadBalancerName"])]
    left += ["target group " + t["TargetGroupName"] for t in elb.describe_target_groups().get("TargetGroups", []) if mine(t["TargetGroupName"])]
    left += ["rds " + d["DBInstanceIdentifier"] for d in rds.describe_db_instances().get("DBInstances", []) if mine(d["DBInstanceIdentifier"])]
    left += ["valkey " + r["ReplicationGroupId"] for r in ec.describe_replication_groups().get("ReplicationGroups", []) if mine(r["ReplicationGroupId"])]
    left += ["user pool " + p["Name"] for p in cog.list_user_pools(MaxResults=60).get("UserPools", []) if mine(p["Name"])]
    for page in kms.get_paginator("list_aliases").paginate():
        left += ["kms alias " + a["AliasName"] for a in page["Aliases"] if mine(a["AliasName"][len("alias/"):])]
    left += ["vpc " + v["VpcId"] for v in ec2.describe_vpcs().get("Vpcs", [])
             if any(t["Key"] == TAG and t["Value"] == PREFIX for t in v.get("Tags", []))]
    return left


if MODE == "pre":
    safe("iam_pre", iam_pre)
    s3_purge_all(delete=False)
elif MODE == "post":
    post()
elif MODE == "check":
    pass
left = leftovers() if MODE in ("post", "check") else []
if MODE in ("post", "check"):
    if left:
        log("LEFTOVER resources: %s" % "; ".join(left))
    else:
        log("no resources remain for prefix %s" % PREFIX)
sys.exit(1 if left else 0)
PYEOF

sweep() { "$PYTHON" "$WORK/sweep.py" "$CONFIG_FILE" "$1"; }
tf() { "$TF" -chdir="$INFRA_DIR" "$@"; }
state_count() { tf state list -state="$STATE_FILE" 2>/dev/null | grep -c . || true; }

# 1. Remove things that would block (or survive) a normal destroy: out-of-band
#    IAM attachments/roles/policies and versioned objects in prefix buckets.
log "pre-sweep: out-of-band IAM and versioned S3 contents for prefix ${PREFIX}"
sweep pre || log "pre-sweep reported problems (continuing)"

# 2. Terraform / OpenTofu destroy.
if [ -d "$INFRA_DIR" ]; then
  tf init -input=false -no-color >"$WORK/init.log" 2>&1 || { tail -n 20 "$WORK/init.log"; log "init failed (continuing with sweep)"; }
fi
destroy_tf() {
  [ -f "$STATE_FILE" ] || return 0
  [ "$(state_count)" != "0" ] || return 0
  log "destroying managed infrastructure ($(state_count) resources in state)"
  tf destroy -auto-approve -input=false -no-color -lock-timeout=120s -state="$STATE_FILE" >"$WORK/destroy.log" 2>&1
  rc=$?
  tail -n 6 "$WORK/destroy.log"
  return $rc
}
if ! destroy_tf; then
  log "terraform destroy reported errors; sweeping and retrying"
  grep -E "Error" -A3 "$WORK/destroy.log" | head -40
  sweep pre || true
  sweep post || true
  destroy_tf || log "second terraform destroy still reported errors"
fi

# 3. Prefix-scoped sweep for anything left (out-of-band or emulator-created).
log "post-sweep: prefix-scoped cleanup"
sweep post
SWEEP_RC=$?

# 4. If any resource is still tracked (e.g. its cloud object was swept first), refresh the state away.
if [ -f "$STATE_FILE" ] && [ "$(state_count)" != "0" ]; then
  log "state still tracks $(state_count) resources; refreshing"
  destroy_tf || true
  sweep post || true
  SWEEP_RC=$?
fi

REMAINING="$(state_count)"
log "terraform state resources remaining: ${REMAINING}"
if [ "$REMAINING" != "0" ]; then
  tf state list -state="$STATE_FILE" 2>/dev/null | head -20
  die "terraform state is not empty"
fi
[ "$SWEEP_RC" = 0 ] || die "resources scoped to ${PREFIX} remain"
log "teardown complete for prefix ${PREFIX}"
exit 0
