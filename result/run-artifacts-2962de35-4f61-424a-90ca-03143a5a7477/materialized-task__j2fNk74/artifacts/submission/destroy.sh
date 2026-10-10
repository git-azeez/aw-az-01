#!/usr/bin/env bash
# ClearLedger teardown: terraform destroy + prefix-scoped sweep of out-of-band resources.
set -Euo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"

log() { printf '[destroy %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_FILE}" ]] || die "config file ${CONFIG_FILE} not found"
cfg() { jq -r --arg k "$1" '.[$k] // empty' "${CONFIG_FILE}"; }

PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"; REGION="${REGION:-us-east-1}"
ENDPOINT="$(cfg aws_endpoint_url)"
[[ -n "${PREFIX}" && -n "${ENDPOINT}" ]] || die "config missing resource_prefix/aws_endpoint_url"
case "${PREFIX}" in cl-base*) die "refusing to destroy baseline prefix ${PREFIX}";; esac

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_EC2_METADATA_DISABLED=true AWS_PAGER=""
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1 PYTHONUNBUFFERED=1
export CL_PREFIX="${PREFIX}" CL_REGION="${REGION}" CL_ENDPOINT="${ENDPOINT}"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "neither terraform nor tofu is installed"; fi

WORK_DIR="$(mktemp -d /tmp/clearledger-destroy.XXXXXX)"
PROXY_PID=""
cleanup() {
  [[ -n "${PROXY_PID}" ]] && kill "${PROXY_PID}" >/dev/null 2>&1
  rm -rf "${WORK_DIR}" 2>/dev/null
  return 0
}
trap cleanup EXIT

cat > "${WORK_DIR}/proxy.py" <<'PYEOF'
import asyncio, sys
LPORT, RHOST, RPORT = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])

async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d:
                break
            w.write(d)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass

async def handle(cr, cw):
    try:
        sr, sw = await asyncio.open_connection(RHOST, RPORT)
    except Exception:
        cw.close()
        return
    await asyncio.gather(pipe(cr, sw), pipe(sr, cw))

async def main():
    srv = await asyncio.start_server(handle, "127.0.0.1", LPORT)
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
PYEOF

cat > "${WORK_DIR}/sweep.py" <<'PYEOF'
#!/usr/bin/env python3
"""Prefix-scoped teardown of ClearLedger resources (pre- and post-terraform-destroy)."""
import os
import sys
import time

import boto3
from botocore.config import Config

PREFIX = os.environ["CL_PREFIX"]
REGION = os.environ.get("CL_REGION", "us-east-1")
ENDPOINT = os.environ["CL_ENDPOINT"]
TAG_KEY = "ClearLedgerDeployment"
CFG = Config(retries={"max_attempts": 6, "mode": "standard"}, connect_timeout=10, read_timeout=60)


def log(msg):
    print(f"[sweep] {msg}", file=sys.stderr, flush=True)


def c(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION,
                        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
                        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"), config=CFG)


def ours(name):
    if not name:
        return False
    if name.startswith("cl-base"):
        return False
    return name == PREFIX or name.startswith(PREFIX + "-") or name.startswith(PREFIX + "_") \
        or name.startswith(f"/clearledger/{PREFIX}/") or name.startswith(f"alias/{PREFIX}-")


def tagged(tags):
    if isinstance(tags, dict):
        return tags.get(TAG_KEY) == PREFIX
    for t in tags or []:
        if (t.get("Key") or t.get("key")) == TAG_KEY and (t.get("Value") or t.get("value")) == PREFIX:
            return True
    return False


def safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:  # noqa
        log(f"{getattr(fn, '__name__', fn)}: {str(e)[:200]}")
        return None


def purge_bucket(s3, b):
    kw = {"Bucket": b}
    while True:
        r = safe(s3.list_object_versions, **kw)
        if not r:
            break
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in (r.get("Versions") or [])]
        objs += [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in (r.get("DeleteMarkers") or [])]
        for i in range(0, len(objs), 500):
            safe(s3.delete_objects, Bucket=b, Delete={"Objects": objs[i:i + 500], "Quiet": True})
        if not r.get("IsTruncated"):
            break
        kw = {"Bucket": b, "KeyMarker": r.get("NextKeyMarker"), "VersionIdMarker": r.get("NextVersionIdMarker")}
        kw = {k: v for k, v in kw.items() if v}
    r = safe(s3.list_objects_v2, Bucket=b)
    for o in (r or {}).get("Contents", []) or []:
        safe(s3.delete_object, Bucket=b, Key=o["Key"])


def buckets(delete):
    s3 = c("s3")
    for b in (safe(s3.list_buckets) or {}).get("Buckets", []):
        name = b["Name"]
        mine = ours(name)
        if not mine and not name.startswith("cl-base"):
            try:
                t = s3.get_bucket_tagging(Bucket=name).get("TagSet", [])
                mine = tagged(t)
            except Exception:
                pass
        if not mine:
            continue
        log(f"purging bucket {name}")
        purge_bucket(s3, name)
        if delete:
            safe(s3.delete_bucket, Bucket=name)


def iam_roles(delete):
    iam = c("iam")
    roles = []
    for p in iam.get_paginator("list_roles").paginate():
        roles.extend(p.get("Roles", []))
    for r in roles:
        name = r["RoleName"]
        if not ours(name):
            continue
        for p in (safe(iam.list_role_policies, RoleName=name) or {}).get("PolicyNames", []):
            safe(iam.delete_role_policy, RoleName=name, PolicyName=p)
        for p in (safe(iam.list_attached_role_policies, RoleName=name) or {}).get("AttachedPolicies", []):
            safe(iam.detach_role_policy, RoleName=name, PolicyArn=p["PolicyArn"])
        if r.get("PermissionsBoundary"):
            safe(iam.delete_role_permissions_boundary, RoleName=name)
        for ip in (safe(iam.list_instance_profiles_for_role, RoleName=name) or {}).get("InstanceProfiles", []):
            safe(iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
        if delete:
            log(f"deleting role {name}")
            safe(iam.delete_role, RoleName=name)
    if delete:
        for p in (safe(iam.list_instance_profiles) or {}).get("InstanceProfiles", []):
            if ours(p["InstanceProfileName"]):
                safe(iam.delete_instance_profile, InstanceProfileName=p["InstanceProfileName"])
    pols = []
    for p in iam.get_paginator("list_policies").paginate(Scope="Local"):
        pols.extend(p.get("Policies", []))
    for p in pols:
        if not ours(p["PolicyName"]):
            continue
        arn = p["Arn"]
        ents = safe(iam.list_entities_for_policy, PolicyArn=arn) or {}
        for r in ents.get("PolicyRoles", []):
            safe(iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
        for u in ents.get("PolicyUsers", []):
            safe(iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
        for g in ents.get("PolicyGroups", []):
            safe(iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
        if delete:
            for v in (safe(iam.list_policy_versions, PolicyArn=arn) or {}).get("Versions", []):
                if not v.get("IsDefaultVersion"):
                    safe(iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
            log(f"deleting policy {arn}")
            safe(iam.delete_policy, PolicyArn=arn)


def pre():
    buckets(delete=False)
    iam_roles(delete=False)
    # stop ESMs / schedules early so nothing writes during teardown
    lam = c("lambda")
    for m in (safe(lam.list_event_source_mappings) or {}).get("EventSourceMappings", []):
        fn = m.get("FunctionArn", "").split(":")[-1]
        if ours(fn) or PREFIX in m.get("EventSourceArn", ""):
            safe(lam.delete_event_source_mapping, UUID=m["UUID"])


def post():
    lam = c("lambda")
    for m in (safe(lam.list_event_source_mappings) or {}).get("EventSourceMappings", []):
        fn = m.get("FunctionArn", "").split(":")[-1]
        if ours(fn) or (":" + PREFIX + "-") in m.get("EventSourceArn", ""):
            log(f"deleting esm {m['UUID']}")
            safe(lam.delete_event_source_mapping, UUID=m["UUID"])
    fns = []
    for p in lam.get_paginator("list_functions").paginate():
        fns.extend(p.get("Functions", []))
    for f in fns:
        if ours(f["FunctionName"]):
            log(f"deleting lambda {f['FunctionName']}")
            safe(lam.delete_function, FunctionName=f["FunctionName"])

    sch = c("scheduler")
    for g in (safe(sch.list_schedule_groups) or {}).get("ScheduleGroups", []):
        gname = g["Name"]
        for s in (safe(sch.list_schedules, GroupName=gname) or {}).get("Schedules", []):
            if ours(s["Name"]):
                log(f"deleting schedule {s['Name']}")
                safe(sch.delete_schedule, Name=s["Name"], GroupName=gname)
        if gname != "default" and ours(gname):
            safe(sch.delete_schedule_group, Name=gname)

    ev = c("events")
    for r in (safe(ev.list_rules) or {}).get("Rules", []):
        if ours(r["Name"]):
            tg = (safe(ev.list_targets_by_rule, Rule=r["Name"]) or {}).get("Targets", [])
            if tg:
                safe(ev.remove_targets, Rule=r["Name"], Ids=[t["Id"] for t in tg], Force=True)
            safe(ev.delete_rule, Name=r["Name"], Force=True)

    sqs = c("sqs")
    for q in (safe(sqs.list_queues, QueueNamePrefix=PREFIX) or {}).get("QueueUrls", []) or []:
        if ours(q.rsplit("/", 1)[-1]):
            log(f"deleting queue {q}")
            safe(sqs.delete_queue, QueueUrl=q)

    ddb = c("dynamodb")
    for t in (safe(ddb.list_tables) or {}).get("TableNames", []):
        if ours(t):
            log(f"deleting table {t}")
            safe(ddb.delete_table, TableName=t)

    logs = c("logs")
    for prefix in (f"/clearledger/{PREFIX}", PREFIX, f"/aws/lambda/{PREFIX}", f"/ecs/{PREFIX}"):
        for g in (safe(logs.describe_log_groups, logGroupNamePrefix=prefix) or {}).get("logGroups", []):
            n = g["logGroupName"]
            if ours(n) or n.startswith(f"/aws/lambda/{PREFIX}-") or n.startswith(f"/ecs/{PREFIX}"):
                log(f"deleting log group {n}")
                safe(logs.delete_log_group, logGroupName=n)

    ecs = c("ecs")
    for arn in (safe(ecs.list_clusters) or {}).get("clusterArns", []):
        name = arn.rsplit("/", 1)[-1]
        if not ours(name):
            continue
        for s in (safe(ecs.list_services, cluster=arn) or {}).get("serviceArns", []):
            safe(ecs.update_service, cluster=arn, service=s, desiredCount=0)
            safe(ecs.delete_service, cluster=arn, service=s, force=True)
        for t in (safe(ecs.list_tasks, cluster=arn) or {}).get("taskArns", []):
            safe(ecs.stop_task, cluster=arn, task=t)
        log(f"deleting ecs cluster {name}")
        safe(ecs.delete_cluster, cluster=arn)
    for fam in (safe(ecs.list_task_definition_families, familyPrefix=PREFIX, status="ACTIVE") or {}).get("families", []):
        if ours(fam):
            for td in (safe(ecs.list_task_definitions, familyPrefix=fam) or {}).get("taskDefinitionArns", []):
                safe(ecs.deregister_task_definition, taskDefinition=td)

    elb = c("elbv2")
    for lb in (safe(elb.describe_load_balancers) or {}).get("LoadBalancers", []):
        if ours(lb["LoadBalancerName"]):
            for l in (safe(elb.describe_listeners, LoadBalancerArn=lb["LoadBalancerArn"]) or {}).get("Listeners", []):
                safe(elb.delete_listener, ListenerArn=l["ListenerArn"])
            log(f"deleting alb {lb['LoadBalancerName']}")
            safe(elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in (safe(elb.describe_target_groups) or {}).get("TargetGroups", []):
        if ours(tg["TargetGroupName"]):
            safe(elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])

    rds = c("rds")
    for db in (safe(rds.describe_db_instances) or {}).get("DBInstances", []):
        if ours(db["DBInstanceIdentifier"]):
            log(f"deleting rds {db['DBInstanceIdentifier']}")
            safe(rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    for sn in (safe(rds.describe_db_snapshots) or {}).get("DBSnapshots", []):
        if ours(sn.get("DBSnapshotIdentifier")) or ours(sn.get("DBInstanceIdentifier")):
            safe(rds.delete_db_snapshot, DBSnapshotIdentifier=sn["DBSnapshotIdentifier"])

    ec = c("elasticache")
    for rg in (safe(ec.describe_replication_groups) or {}).get("ReplicationGroups", []):
        if ours(rg["ReplicationGroupId"]):
            log(f"deleting replication group {rg['ReplicationGroupId']}")
            safe(ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"])
    for cc in (safe(ec.describe_cache_clusters) or {}).get("CacheClusters", []):
        if ours(cc["CacheClusterId"]) and not cc.get("ReplicationGroupId"):
            safe(ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])

    cog = c("cognito-idp")
    for up in (safe(cog.list_user_pools, MaxResults=60) or {}).get("UserPools", []):
        if ours(up["Name"]):
            d = (safe(cog.describe_user_pool, UserPoolId=up["Id"]) or {}).get("UserPool", {})
            if d.get("Domain"):
                safe(cog.delete_user_pool_domain, Domain=d["Domain"], UserPoolId=up["Id"])
            log(f"deleting user pool {up['Name']}")
            safe(cog.delete_user_pool, UserPoolId=up["Id"])

    sm = c("secretsmanager")
    for s in (safe(sm.list_secrets) or {}).get("SecretList", []):
        if ours(s["Name"]) or tagged(s.get("Tags")):
            safe(sm.delete_secret, SecretId=s["ARN"], ForceDeleteWithoutRecovery=True)
    ssm = c("ssm")
    for p in (safe(ssm.describe_parameters) or {}).get("Parameters", []):
        if ours(p["Name"]) or p["Name"].startswith(f"/{PREFIX}/") or p["Name"].startswith(f"/clearledger/{PREFIX}/"):
            safe(ssm.delete_parameter, Name=p["Name"])

    buckets(delete=True)
    iam_roles(delete=True)

    # wait for data stores that block subnet/SG deletion
    for _ in range(60):
        busy = [d for d in (safe(rds.describe_db_instances) or {}).get("DBInstances", []) if ours(d["DBInstanceIdentifier"])]
        busy += [r for r in (safe(ec.describe_replication_groups) or {}).get("ReplicationGroups", []) if ours(r["ReplicationGroupId"])]
        if not busy:
            break
        time.sleep(3)
    for g in (safe(rds.describe_db_subnet_groups) or {}).get("DBSubnetGroups", []):
        if ours(g["DBSubnetGroupName"]):
            safe(rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    for g in (safe(ec.describe_cache_subnet_groups) or {}).get("CacheSubnetGroups", []):
        if ours(g["CacheSubnetGroupName"]):
            safe(ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])

    kms = c("kms")
    keys = set()
    for a in (safe(kms.list_aliases) or {}).get("Aliases", []):
        if ours(a["AliasName"]):
            if a.get("TargetKeyId"):
                keys.add(a["TargetKeyId"])
            safe(kms.delete_alias, AliasName=a["AliasName"])
    for k in (safe(kms.list_keys) or {}).get("Keys", []):
        tags = (safe(kms.list_resource_tags, KeyId=k["KeyId"]) or {}).get("Tags", [])
        if any(t.get("TagKey") == TAG_KEY and t.get("TagValue") == PREFIX for t in tags):
            keys.add(k["KeyId"])
    for k in keys:
        meta = (safe(kms.describe_key, KeyId=k) or {}).get("KeyMetadata", {})
        if meta.get("KeyManager") == "AWS":
            continue
        if meta.get("KeyState") not in ("PendingDeletion", None):
            log(f"scheduling deletion of kms key {k}")
            safe(kms.schedule_key_deletion, KeyId=k, PendingWindowInDays=7)

    ec2 = c("ec2")
    flt = [{"Name": f"tag:{TAG_KEY}", "Values": [PREFIX]}]
    vpcs = {v["VpcId"] for v in (safe(ec2.describe_vpcs, Filters=flt) or {}).get("Vpcs", [])}
    for v in (safe(ec2.describe_vpcs) or {}).get("Vpcs", []):
        name = next((t["Value"] for t in v.get("Tags", []) or [] if t["Key"] == "Name"), "")
        if ours(name):
            vpcs.add(v["VpcId"])
    for vpc in vpcs:
        vf = [{"Name": "vpc-id", "Values": [vpc]}]
        for e in (safe(ec2.describe_vpc_endpoints, Filters=vf) or {}).get("VpcEndpoints", []):
            safe(ec2.delete_vpc_endpoints, VpcEndpointIds=[e["VpcEndpointId"]])
        for n in (safe(ec2.describe_nat_gateways, Filters=vf) or {}).get("NatGateways", []):
            safe(ec2.delete_nat_gateway, NatGatewayId=n["NatGatewayId"])
        for eni in (safe(ec2.describe_network_interfaces, Filters=vf) or {}).get("NetworkInterfaces", []):
            if eni.get("Attachment"):
                safe(ec2.detach_network_interface, AttachmentId=eni["Attachment"]["AttachmentId"], Force=True)
            safe(ec2.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"])
        sgs = [g for g in (safe(ec2.describe_security_groups, Filters=vf) or {}).get("SecurityGroups", [])
               if g["GroupName"] != "default"]
        for g in sgs:
            if g.get("IpPermissions"):
                safe(ec2.revoke_security_group_ingress, GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
            if g.get("IpPermissionsEgress"):
                safe(ec2.revoke_security_group_egress, GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
        for g in sgs:
            safe(ec2.delete_security_group, GroupId=g["GroupId"])
        for igw in (safe(ec2.describe_internet_gateways, Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]) or {}).get("InternetGateways", []):
            safe(ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
            safe(ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in (safe(ec2.describe_subnets, Filters=vf) or {}).get("Subnets", []):
            safe(ec2.delete_subnet, SubnetId=sn["SubnetId"])
        for rt in (safe(ec2.describe_route_tables, Filters=vf) or {}).get("RouteTables", []):
            if any(a.get("Main") for a in rt.get("Associations", [])):
                continue
            for a in rt.get("Associations", []):
                safe(ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            safe(ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        log(f"deleting vpc {vpc}")
        safe(ec2.delete_vpc, VpcId=vpc)
    # stray tagged items outside our VPC
    for igw in (safe(ec2.describe_internet_gateways, Filters=flt) or {}).get("InternetGateways", []):
        for a in igw.get("Attachments", []):
            safe(ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=a["VpcId"])
        safe(ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
    for g in (safe(ec2.describe_security_groups, Filters=flt) or {}).get("SecurityGroups", []):
        if g["GroupName"] != "default":
            safe(ec2.delete_security_group, GroupId=g["GroupId"])
    for a in (safe(ec2.describe_addresses, Filters=flt) or {}).get("Addresses", []):
        safe(ec2.release_address, AllocationId=a["AllocationId"])


if __name__ == "__main__":
    {"pre": pre, "post": post}[sys.argv[1]]()
PYEOF

host="$(python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).hostname)' "${ENDPOINT}")"
port="$(python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).port or 80)' "${ENDPOINT}")"
PROXY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 "${WORK_DIR}/proxy.py" "${PROXY_PORT}" "${host}" "${port}" >/dev/null 2>&1 &
PROXY_PID=$!
sleep 0.5
export AWS_ENDPOINT_URL_S3_CONTROL="http://localhost:${PROXY_PORT}"

jq --arg s3c "http://localhost:${PROXY_PORT}" --arg host "${host}" '{
    resource_prefix, region, aws_endpoint_url, db_name, db_username, db_password,
    api_image, projector_image, relay_image, archiver_image,
    api_image_id: (.api_image_id // ""), projector_image_id: (.projector_image_id // ""),
    relay_image_id: (.relay_image_id // ""), archiver_image_id: (.archiver_image_id // ""),
    container_aws_endpoint_url: .aws_endpoint_url,
    s3control_endpoint_url: $s3c,
    service_host: $host
  }' "${CONFIG_FILE}" > "${WORK_DIR}/destroy.tfvars.json"

log "pre-destroy cleanup (out-of-band policies, bucket versions, event source mappings)"
python3 "${WORK_DIR}/sweep.py" pre || log "pre-destroy cleanup reported problems (continuing)"

cd "${INFRA_DIR}" || die "missing ${INFRA_DIR}"
"${TF}" init -input=false -no-color >"${WORK_DIR}/init.log" 2>&1 || { cat "${WORK_DIR}/init.log" >&2; log "${TF} init failed"; }

if [[ -f "${STATE_FILE}" ]]; then
  for attempt in 1 2 3; do
    log "${TF} destroy (attempt ${attempt})"
    if "${TF}" destroy -input=false -no-color -auto-approve -lock-timeout=120s \
         -state="${STATE_FILE}" -var-file="${WORK_DIR}/destroy.tfvars.json" >"${WORK_DIR}/destroy.log" 2>&1; then
      grep -E '^Destroy complete' "${WORK_DIR}/destroy.log" >&2 || true
      break
    fi
    grep -E 'Error' "${WORK_DIR}/destroy.log" | head -30 >&2 || true
    python3 "${WORK_DIR}/sweep.py" pre >/dev/null 2>&1 || true
    sleep $((attempt * 5))
  done
fi

log "prefix-scoped sweep"
python3 "${WORK_DIR}/sweep.py" post || log "sweep reported problems"

# Anything still tracked in state has been removed by the sweep; drop it from state.
if [[ -f "${STATE_FILE}" ]]; then
  remaining="$("${TF}" state list -state="${STATE_FILE}" 2>/dev/null | grep -v '^data\.' || true)"
  if [[ -n "${remaining}" ]]; then
    log "re-running ${TF} destroy for remaining state entries"
    "${TF}" destroy -input=false -no-color -auto-approve -refresh=true -state="${STATE_FILE}" \
      -var-file="${WORK_DIR}/destroy.tfvars.json" >"${WORK_DIR}/destroy2.log" 2>&1 || true
    remaining="$("${TF}" state list -state="${STATE_FILE}" 2>/dev/null | grep -v '^data\.' || true)"
    if [[ -n "${remaining}" ]]; then
      log "removing orphaned entries from state"
      while read -r addr; do
        [[ -n "${addr}" ]] && "${TF}" state rm -state="${STATE_FILE}" "${addr}" >/dev/null 2>&1 || true
      done <<< "${remaining}"
    fi
  fi
fi

log "destroy complete"
exit 0
