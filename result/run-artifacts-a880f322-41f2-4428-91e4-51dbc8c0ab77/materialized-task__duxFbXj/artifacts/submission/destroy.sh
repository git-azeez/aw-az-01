#!/usr/bin/env bash
# ClearLedger teardown: terraform destroy + prefix-scoped sweep of any
# out-of-band leftovers. Baseline (cl-base-*) resources are never touched.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/infra"
CONFIG_PATH="${CL_CONFIG:-/workspace/config/config.json}"
STATE_PATH="${INFRA_DIR}/terraform.tfstate"

log() { printf '[destroy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_PATH}" ]] || die "config not found: ${CONFIG_PATH}"
PREFIX="$(jq -r '.resource_prefix' "${CONFIG_PATH}")"
REGION="$(jq -r '.region' "${CONFIG_PATH}")"
ENDPOINT="$(jq -r '.aws_endpoint_url' "${CONFIG_PATH}")"
[[ -n "${PREFIX}" && "${PREFIX}" != "null" ]] || die "resource_prefix missing"
case "${PREFIX}" in cl-base*) die "refusing to destroy baseline prefix ${PREFIX}";; esac

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1
export TF_INPUT=0
export CL_CONFIG="${CONFIG_PATH}"
export PYTHONUNBUFFERED=1

if command -v terraform >/dev/null 2>&1; then TF=terraform; elif command -v tofu >/dev/null 2>&1; then TF=tofu; else die "terraform/tofu not found"; fi

WORK="$(mktemp -d /tmp/clearledger-destroy.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/sweep.py" <<'CLEARLEDGER_PY'
import json, os, sys, time
import boto3
from botocore.config import Config

CFG = json.load(open(os.environ["CL_CONFIG"]))
PREFIX = CFG["resource_prefix"]
REGION = CFG["region"]
ENDPOINT = CFG["aws_endpoint_url"]
TAG_KEY = "ClearLedgerDeployment"
_cfg = Config(retries={"max_attempts": 6, "mode": "standard"}, connect_timeout=10, read_timeout=60)


def log(m):
    print(f"[sweep] {m}", flush=True)


def c(name):
    return boto3.client(name, region_name=REGION, endpoint_url=ENDPOINT,
                        aws_access_key_id="test", aws_secret_access_key="test", config=_cfg)


def mine(name):
    return isinstance(name, str) and name.startswith(PREFIX) and not name.startswith("cl-base")


def tagged(tags):
    if isinstance(tags, dict):
        return tags.get(TAG_KEY) == PREFIX
    for t in tags or []:
        k = t.get("Key", t.get("TagKey"))
        v = t.get("Value", t.get("TagValue"))
        if k == TAG_KEY and v == PREFIX:
            return True
    return False


def safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:
        log(f"{getattr(fn, '__name__', fn)}: {e}")
        return None


def empty_bucket(s3, b):
    try:
        for u in s3.list_multipart_uploads(Bucket=b).get("Uploads", []):
            safe(s3.abort_multipart_upload, Bucket=b, Key=u["Key"], UploadId=u["UploadId"])
    except Exception as e:
        log(f"multipart {b}: {e}")
    while True:
        try:
            r = s3.list_object_versions(Bucket=b)
        except Exception as e:
            log(f"list versions {b}: {e}")
            break
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in r.get("Versions", []) + r.get("DeleteMarkers", [])]
        if not objs:
            break
        for i in range(0, len(objs), 500):
            safe(s3.delete_objects, Bucket=b, Delete={"Objects": objs[i:i + 500], "Quiet": True})
    try:
        while True:
            r = s3.list_objects_v2(Bucket=b)
            objs = [{"Key": o["Key"]} for o in r.get("Contents", [])]
            if not objs:
                break
            s3.delete_objects(Bucket=b, Delete={"Objects": objs, "Quiet": True})
    except Exception as e:
        log(f"list objects {b}: {e}")


def buckets(delete=False):
    s3 = c("s3")
    for b in s3.list_buckets().get("Buckets", []):
        n = b["Name"]
        if mine(n):
            log(f"s3: emptying {n}")
            empty_bucket(s3, n)
            if delete:
                safe(s3.delete_bucket, Bucket=n)


def ecs():
    e = c("ecs")
    for arn in e.list_clusters().get("clusterArns", []):
        name = arn.split("/")[-1]
        if not mine(name):
            continue
        for s in (safe(e.list_services, cluster=arn) or {}).get("serviceArns", []):
            safe(e.update_service, cluster=arn, service=s, desiredCount=0)
            safe(e.delete_service, cluster=arn, service=s, force=True)
        for t in (safe(e.list_tasks, cluster=arn) or {}).get("taskArns", []):
            safe(e.stop_task, cluster=arn, task=t)
        log(f"ecs: deleting cluster {name}")
        safe(e.delete_cluster, cluster=arn)
    # Task definitions: deregister ACTIVE, then delete INACTIVE revisions.
    for status in ("ACTIVE", "INACTIVE"):
        token = None
        arns = []
        while True:
            kw = {"status": status, "familyPrefix": PREFIX}
            if token:
                kw["nextToken"] = token
            r = safe(e.list_task_definitions, **kw) or {}
            arns += r.get("taskDefinitionArns", [])
            token = r.get("nextToken")
            if not token:
                break
        arns = [a for a in arns if mine(a.split("/")[-1])]
        for a in arns:
            if status == "ACTIVE":
                safe(e.deregister_task_definition, taskDefinition=a)
        if arns:
            log(f"ecs: deleting {len(arns)} {status} task definitions")
            for i in range(0, len(arns), 10):
                safe(e.delete_task_definitions, taskDefinitions=arns[i:i + 10])
    # Anything still registered after deregistration.
    r = safe(e.list_task_definitions, familyPrefix=PREFIX, status="INACTIVE") or {}
    left = [a for a in r.get("taskDefinitionArns", []) if mine(a.split("/")[-1])]
    for i in range(0, len(left), 10):
        safe(e.delete_task_definitions, taskDefinitions=left[i:i + 10])


def lambdas():
    l = c("lambda")
    fns = []
    for p in l.get_paginator("list_functions").paginate():
        fns += [f for f in p.get("Functions", []) if mine(f["FunctionName"])]
    for m in (safe(l.list_event_source_mappings) or {}).get("EventSourceMappings", []):
        fn = m.get("FunctionArn", "").split(":")[-1]
        src = m.get("EventSourceArn", "").split(":")[-1]
        if mine(fn) or mine(src):
            log(f"lambda: deleting event source mapping {m['UUID']}")
            safe(l.delete_event_source_mapping, UUID=m["UUID"])
    for f in fns:
        log(f"lambda: deleting {f['FunctionName']}")
        safe(l.delete_function, FunctionName=f["FunctionName"])


def scheduler():
    s = c("scheduler")
    groups = ["default"] + [g["Name"] for g in (safe(s.list_schedule_groups) or {}).get("ScheduleGroups", []) if g["Name"] != "default"]
    for g in groups:
        for sc in (safe(s.list_schedules, GroupName=g) or {}).get("Schedules", []):
            if mine(sc["Name"]):
                log(f"scheduler: deleting {g}/{sc['Name']}")
                safe(s.delete_schedule, Name=sc["Name"], GroupName=g)
        if g != "default" and mine(g):
            safe(s.delete_schedule_group, Name=g)
    ev = c("events")
    for r in (safe(ev.list_rules, NamePrefix=PREFIX) or {}).get("Rules", []):
        if mine(r["Name"]):
            ts = [t["Id"] for t in (safe(ev.list_targets_by_rule, Rule=r["Name"]) or {}).get("Targets", [])]
            if ts:
                safe(ev.remove_targets, Rule=r["Name"], Ids=ts, Force=True)
            safe(ev.delete_rule, Name=r["Name"], Force=True)


def sqs():
    q = c("sqs")
    for u in (safe(q.list_queues, QueueNamePrefix=PREFIX) or {}).get("QueueUrls", []):
        if mine(u.rsplit("/", 1)[-1]):
            log(f"sqs: deleting {u}")
            safe(q.delete_queue, QueueUrl=u)


def dynamodb():
    d = c("dynamodb")
    for t in (safe(d.list_tables) or {}).get("TableNames", []):
        if mine(t):
            log(f"dynamodb: deleting {t}")
            safe(d.delete_table, TableName=t)


def cognito():
    ci = c("cognito-idp")
    for p in (safe(ci.list_user_pools, MaxResults=60) or {}).get("UserPools", []):
        if not mine(p["Name"]):
            continue
        desc = (safe(ci.describe_user_pool, UserPoolId=p["Id"]) or {}).get("UserPool", {})
        for dom in {desc.get("Domain"), desc.get("CustomDomain")} - {None, ""}:
            log(f"cognito: deleting domain {dom}")
            safe(ci.delete_user_pool_domain, Domain=dom, UserPoolId=p["Id"])
        log(f"cognito: deleting pool {p['Name']}")
        safe(ci.delete_user_pool, UserPoolId=p["Id"])


def iam():
    i = c("iam")
    roles = []
    for pg in i.get_paginator("list_roles").paginate():
        roles += [r["RoleName"] for r in pg.get("Roles", []) if mine(r["RoleName"])]
    profiles = []
    for pg in i.get_paginator("list_instance_profiles").paginate():
        profiles += pg.get("InstanceProfiles", [])
    for ip in profiles:
        if mine(ip["InstanceProfileName"]) or any(mine(r["RoleName"]) for r in ip.get("Roles", [])):
            for r in ip.get("Roles", []):
                safe(i.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
            if mine(ip["InstanceProfileName"]):
                log(f"iam: deleting instance profile {ip['InstanceProfileName']}")
                safe(i.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
    for r in roles:
        for n in (safe(i.list_role_policies, RoleName=r) or {}).get("PolicyNames", []):
            safe(i.delete_role_policy, RoleName=r, PolicyName=n)
        for p in (safe(i.list_attached_role_policies, RoleName=r) or {}).get("AttachedPolicies", []):
            safe(i.detach_role_policy, RoleName=r, PolicyArn=p["PolicyArn"])
        log(f"iam: deleting role {r}")
        safe(i.delete_role, RoleName=r)
    for pg in i.get_paginator("list_policies").paginate(Scope="Local"):
        for p in pg.get("Policies", []):
            if not mine(p["PolicyName"]):
                continue
            ents = safe(i.list_entities_for_policy, PolicyArn=p["Arn"]) or {}
            for r in ents.get("PolicyRoles", []):
                safe(i.detach_role_policy, RoleName=r["RoleName"], PolicyArn=p["Arn"])
            for u in ents.get("PolicyUsers", []):
                safe(i.detach_user_policy, UserName=u["UserName"], PolicyArn=p["Arn"])
            for g in ents.get("PolicyGroups", []):
                safe(i.detach_group_policy, GroupName=g["GroupName"], PolicyArn=p["Arn"])
            for v in (safe(i.list_policy_versions, PolicyArn=p["Arn"]) or {}).get("Versions", []):
                if not v.get("IsDefaultVersion"):
                    safe(i.delete_policy_version, PolicyArn=p["Arn"], VersionId=v["VersionId"])
            log(f"iam: deleting policy {p['PolicyName']}")
            safe(i.delete_policy, PolicyArn=p["Arn"])


def kms():
    k = c("kms")
    targets = set()
    for pg in k.get_paginator("list_aliases").paginate():
        for a in pg.get("Aliases", []):
            if a["AliasName"].startswith(f"alias/{PREFIX}"):
                if a.get("TargetKeyId"):
                    targets.add(a["TargetKeyId"])
                log(f"kms: deleting alias {a['AliasName']}")
                safe(k.delete_alias, AliasName=a["AliasName"])
    for pg in k.get_paginator("list_keys").paginate():
        for key in pg.get("Keys", []):
            kid = key["KeyId"]
            tags = (safe(k.list_resource_tags, KeyId=kid) or {}).get("Tags", [])
            if tagged(tags):
                targets.add(kid)
    for kid in targets:
        meta = (safe(k.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
        if not meta or meta.get("KeyManager") == "AWS":
            continue
        if meta.get("KeyState") not in ("PendingDeletion", "PendingReplicaDeletion"):
            log(f"kms: scheduling deletion of {kid}")
            safe(k.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)


def logs():
    lg = c("logs")
    for pg in lg.get_paginator("describe_log_groups").paginate():
        for g in pg.get("logGroups", []):
            n = g["logGroupName"]
            if f"/{PREFIX}/" in n or f"/{PREFIX}-" in n or n.endswith(f"/{PREFIX}") or mine(n):
                log(f"logs: deleting {n}")
                safe(lg.delete_log_group, logGroupName=n)


def elb():
    e = c("elbv2")
    for lb in (safe(e.describe_load_balancers) or {}).get("LoadBalancers", []):
        if mine(lb["LoadBalancerName"]):
            for li in (safe(e.describe_listeners, LoadBalancerArn=lb["LoadBalancerArn"]) or {}).get("Listeners", []):
                safe(e.delete_listener, ListenerArn=li["ListenerArn"])
            log(f"elbv2: deleting {lb['LoadBalancerName']}")
            safe(e.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in (safe(e.describe_target_groups) or {}).get("TargetGroups", []):
        if mine(tg["TargetGroupName"]):
            safe(e.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])


def rds_cache():
    r = c("rds")
    for db in (safe(r.describe_db_instances) or {}).get("DBInstances", []):
        if mine(db["DBInstanceIdentifier"]) and db.get("DBInstanceStatus") != "deleting":
            log(f"rds: deleting {db['DBInstanceIdentifier']}")
            safe(r.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    ec = c("elasticache")
    for g in (safe(ec.describe_replication_groups) or {}).get("ReplicationGroups", []):
        if mine(g["ReplicationGroupId"]) and g.get("Status") != "deleting":
            log(f"elasticache: deleting {g['ReplicationGroupId']}")
            safe(ec.delete_replication_group, ReplicationGroupId=g["ReplicationGroupId"])
    for cc in (safe(ec.describe_cache_clusters) or {}).get("CacheClusters", []):
        if mine(cc["CacheClusterId"]) and not cc.get("ReplicationGroupId") and cc.get("CacheClusterStatus") != "deleting":
            safe(ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])
    time.sleep(2)
    for sg in (safe(r.describe_db_subnet_groups) or {}).get("DBSubnetGroups", []):
        if mine(sg["DBSubnetGroupName"]):
            safe(r.delete_db_subnet_group, DBSubnetGroupName=sg["DBSubnetGroupName"])
    for sg in (safe(ec.describe_cache_subnet_groups) or {}).get("CacheSubnetGroups", []):
        if mine(sg["CacheSubnetGroupName"]):
            safe(ec.delete_cache_subnet_group, CacheSubnetGroupName=sg["CacheSubnetGroupName"])


def ec2():
    e = c("ec2")
    flt = [{"Name": f"tag:{TAG_KEY}", "Values": [PREFIX]}]
    vpcs = [v["VpcId"] for v in (safe(e.describe_vpcs, Filters=flt) or {}).get("Vpcs", [])]
    for vpc in vpcs:
        vf = [{"Name": "vpc-id", "Values": [vpc]}]
        for ni in (safe(e.describe_network_interfaces, Filters=vf) or {}).get("NetworkInterfaces", []):
            if ni.get("Attachment", {}).get("AttachmentId"):
                safe(e.detach_network_interface, AttachmentId=ni["Attachment"]["AttachmentId"], Force=True)
            safe(e.delete_network_interface, NetworkInterfaceId=ni["NetworkInterfaceId"])
        sgs = [s for s in (safe(e.describe_security_groups, Filters=vf) or {}).get("SecurityGroups", []) if s["GroupName"] != "default"]
        for s in sgs:
            if s.get("IpPermissions"):
                safe(e.revoke_security_group_ingress, GroupId=s["GroupId"], IpPermissions=s["IpPermissions"])
            if s.get("IpPermissionsEgress"):
                safe(e.revoke_security_group_egress, GroupId=s["GroupId"], IpPermissions=s["IpPermissionsEgress"])
        for s in sgs:
            safe(e.delete_security_group, GroupId=s["GroupId"])
        for igw in (safe(e.describe_internet_gateways, Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]) or {}).get("InternetGateways", []):
            safe(e.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
            safe(e.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in (safe(e.describe_subnets, Filters=vf) or {}).get("Subnets", []):
            safe(e.delete_subnet, SubnetId=sn["SubnetId"])
        for rt in (safe(e.describe_route_tables, Filters=vf) or {}).get("RouteTables", []):
            if any(a.get("Main") for a in rt.get("Associations", [])):
                continue
            for a in rt.get("Associations", []):
                safe(e.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            safe(e.delete_route_table, RouteTableId=rt["RouteTableId"])
        log(f"ec2: deleting vpc {vpc}")
        safe(e.delete_vpc, VpcId=vpc)
    # Tagged leftovers outside a ClearLedger VPC.
    for igw in (safe(e.describe_internet_gateways, Filters=flt) or {}).get("InternetGateways", []):
        for a in igw.get("Attachments", []):
            safe(e.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=a["VpcId"])
        safe(e.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
    for s in (safe(e.describe_security_groups, Filters=flt) or {}).get("SecurityGroups", []):
        if s["GroupName"] != "default":
            safe(e.delete_security_group, GroupId=s["GroupId"])
    for sn in (safe(e.describe_subnets, Filters=flt) or {}).get("Subnets", []):
        safe(e.delete_subnet, SubnetId=sn["SubnetId"])


STEPS = {
    "buckets": lambda: buckets(False),
    "all": None,
}

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if mode == "buckets":
        safe(buckets, False)
    else:
        for fn in (ecs, scheduler, lambdas, sqs, dynamodb, cognito, elb, rds_cache,
                   lambda: buckets(True), logs, iam, kms, ec2):
            safe(fn)
CLEARLEDGER_PY

log "destroying ClearLedger prefix=${PREFIX} (${TF})"

# 1. Empty versioned audit buckets / abort multipart uploads so bucket deletion succeeds.
python3 "${WORK}/sweep.py" buckets || true

# 2. Terraform destroy.
cd "${INFRA_DIR}"
"${TF}" init -input=false -no-color >"${WORK}/init.log" 2>&1 || { cat "${WORK}/init.log"; log "terraform init failed (continuing with sweep)"; }
if [[ -f "${STATE_PATH}" ]] && [[ -n "$("${TF}" state list 2>/dev/null || true)" ]]; then
  for attempt in 1 2 3; do
    log "terraform destroy (attempt ${attempt})"
    if "${TF}" destroy -input=false -auto-approve -no-color -var "config_path=${CONFIG_PATH}" >"${WORK}/destroy.log" 2>&1; then
      grep -E '^Destroy complete' "${WORK}/destroy.log" || true
      break
    fi
    tail -n 30 "${WORK}/destroy.log"
    python3 "${WORK}/sweep.py" buckets || true
    sleep 5
  done
else
  log "no managed resources in state"
fi

# 3. Prefix-scoped sweep of out-of-band and leftover resources.
log "sweeping out-of-band resources for ${PREFIX}"
python3 "${WORK}/sweep.py" all || true

# 4. Drop any remaining state entries (resources are gone from the cloud).
remaining="$("${TF}" state list 2>/dev/null || true)"
if [[ -n "${remaining}" ]]; then
  log "removing stale state entries:"
  echo "${remaining}"
  # shellcheck disable=SC2086
  "${TF}" state rm ${remaining} >/dev/null 2>&1 || true
fi
remaining="$("${TF}" state list 2>/dev/null || true)"
[[ -z "${remaining}" ]] || die "terraform state still tracks resources"

log "ClearLedger ${PREFIX} destroyed"
exit 0
