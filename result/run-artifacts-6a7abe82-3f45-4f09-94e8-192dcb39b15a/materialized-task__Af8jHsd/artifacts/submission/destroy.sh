#!/usr/bin/env bash
# ClearLedger teardown: terraform destroy + prefix-scoped sweep of out-of-band
# resources. Baseline cl-base-* resources are never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"

log() { printf '[destroy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "${CONFIG_FILE}" ] || die "config file ${CONFIG_FILE} not found"
PREFIX="$(jq -r '.resource_prefix' "${CONFIG_FILE}")"
REGION="$(jq -r '.region // "us-east-1"' "${CONFIG_FILE}")"
ENDPOINT="$(jq -r '.aws_endpoint_url // "http://aws:4566"' "${CONFIG_FILE}")"
DB_PASS="$(jq -r '.db_password' "${CONFIG_FILE}")"
case "${PREFIX}" in
  ""|null|cl-base*) die "refusing to destroy with prefix '${PREFIX}'" ;;
esac

export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1
export TF_INPUT=0

if command -v terraform >/dev/null 2>&1; then
  TF=terraform
elif command -v tofu >/dev/null 2>&1; then
  TF=tofu
else
  die "neither terraform nor tofu is installed"
fi

WORK="$(mktemp -d /tmp/clearledger-destroy.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
tf() { "${TF}" -chdir="${INFRA_DIR}" "$@"; }
tf_filter() {
  grep -E --line-buffered '(: (Destruction|Creation|Modifications) complete|: Destroying\.\.\.|Destroy complete|Apply complete|Error|error|No changes|Plan:)' \
    | grep -v -F "${DB_PASS}" || true
}
state_count() {
  if [ -f "${STATE_FILE}" ]; then
    python3 - "${STATE_FILE}" <<'PY'
import json, sys
try:
    st = json.load(open(sys.argv[1]))
    print(sum(len(r.get("instances", [])) for r in st.get("resources", []) if r.get("mode") == "managed"))
except Exception:
    print(0)
PY
  else
    echo 0
  fi
}

log "tearing down deployment ${PREFIX} (${REGION}) via ${TF}"

cat >"${WORK}/sweep.py" <<'__CLEARLEDGER_EOF__'
"""Prefix-scoped teardown of every ClearLedger resource (managed or out-of-band).

Only resources whose name/identifier starts with the deployment prefix or that
carry ClearLedgerDeployment=<prefix> are touched; baseline cl-base-* resources
never match.
Usage: sweep.py <resource_prefix> <region>
"""
import os
import sys
import time

import boto3
from botocore.config import Config

PREFIX = sys.argv[1]
REGION = sys.argv[2]
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://aws:4566")
CFG = Config(retries={"max_attempts": 5, "mode": "standard"}, read_timeout=120)
TAG_KEY = "ClearLedgerDeployment"

if not PREFIX or PREFIX.startswith("cl-base") or len(PREFIX) < 4:
    raise SystemExit(f"refusing to sweep with unsafe prefix {PREFIX!r}")


def client(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION, config=CFG,
                        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
                        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"))


def log(msg):
    print(f"[sweep] {msg}", flush=True)


def owned(name):
    return isinstance(name, str) and name.startswith(PREFIX)


def tagged(tags):
    if not tags:
        return False
    if isinstance(tags, dict):
        return tags.get(TAG_KEY) == PREFIX
    for t in tags:
        k = t.get("Key", t.get("key", t.get("TagKey")))
        v = t.get("Value", t.get("value", t.get("TagValue")))
        if k == TAG_KEY and v == PREFIX:
            return True
    return False


def safe(fn):
    def wrapper(*a, **kw):
        try:
            return fn(*a, **kw)
        except Exception as exc:  # noqa: BLE001
            log(f"{fn.__name__}: {type(exc).__name__}: {exc}")
    wrapper.__name__ = fn.__name__
    return wrapper


def attempt(desc, fn, *a, **kw):
    try:
        fn(*a, **kw)
        log(f"deleted {desc}")
        return True
    except Exception as exc:  # noqa: BLE001
        log(f"could not delete {desc}: {type(exc).__name__}: {exc}")
        return False


# ---------------------------------------------------------------------------
@safe
def sweep_scheduler():
    sch = client("scheduler")
    groups = ["default"]
    try:
        for page in sch.get_paginator("list_schedule_groups").paginate():
            groups += [g["Name"] for g in page.get("ScheduleGroups", []) if g["Name"] != "default"]
    except Exception:  # noqa: BLE001
        pass
    for g in groups:
        try:
            for page in sch.get_paginator("list_schedules").paginate(GroupName=g):
                for s in page.get("Schedules", []):
                    target = (s.get("Target") or {}).get("Arn", "")
                    if owned(s["Name"]) or f":function:{PREFIX}" in target or owned(g):
                        attempt(f"schedule {g}/{s['Name']}", sch.delete_schedule, Name=s["Name"], GroupName=g)
        except Exception as exc:  # noqa: BLE001
            log(f"list schedules {g}: {exc}")
        if g != "default" and owned(g):
            attempt(f"schedule group {g}", sch.delete_schedule_group, Name=g)


@safe
def sweep_events():
    ev = client("events")
    for page in ev.get_paginator("list_rules").paginate():
        for r in page.get("Rules", []):
            if owned(r["Name"]):
                targets = ev.list_targets_by_rule(Rule=r["Name"]).get("Targets", [])
                if targets:
                    ev.remove_targets(Rule=r["Name"], Ids=[t["Id"] for t in targets], Force=True)
                attempt(f"event rule {r['Name']}", ev.delete_rule, Name=r["Name"], Force=True)


@safe
def sweep_lambda():
    lam = client("lambda")
    for page in lam.get_paginator("list_event_source_mappings").paginate():
        for m in page.get("EventSourceMappings", []):
            fn = m.get("FunctionArn", "")
            src = m.get("EventSourceArn", "")
            if f":function:{PREFIX}" in fn or f":{PREFIX}" in src:
                attempt(f"event source mapping {m['UUID']}", lam.delete_event_source_mapping, UUID=m["UUID"])
    for page in lam.get_paginator("list_functions").paginate():
        for f in page.get("Functions", []):
            if owned(f["FunctionName"]):
                attempt(f"lambda {f['FunctionName']}", lam.delete_function, FunctionName=f["FunctionName"])
    try:
        for page in lam.get_paginator("list_layers").paginate():
            for layer in page.get("Layers", []):
                if owned(layer["LayerName"]):
                    for v in lam.list_layer_versions(LayerName=layer["LayerName"]).get("LayerVersions", []):
                        lam.delete_layer_version(LayerName=layer["LayerName"], VersionNumber=v["Version"])
    except Exception:  # noqa: BLE001
        pass


@safe
def sweep_ecs():
    ecs = client("ecs")
    clusters = ecs.list_clusters().get("clusterArns", [])
    for arn in clusters:
        name = arn.split("/")[-1]
        mine = owned(name)
        if not mine:
            try:
                d = ecs.describe_clusters(clusters=[arn], include=["TAGS"])["clusters"]
                mine = bool(d) and tagged(d[0].get("tags"))
            except Exception:  # noqa: BLE001
                pass
        services = []
        try:
            for page in ecs.get_paginator("list_services").paginate(cluster=arn):
                services += page.get("serviceArns", [])
        except Exception:  # noqa: BLE001
            pass
        for s in services:
            sname = s.split("/")[-1]
            if mine or owned(sname):
                try:
                    ecs.update_service(cluster=arn, service=s, desiredCount=0)
                except Exception:  # noqa: BLE001
                    pass
                attempt(f"ecs service {sname}", ecs.delete_service, cluster=arn, service=s, force=True)
        if mine:
            try:
                for page in ecs.get_paginator("list_tasks").paginate(cluster=arn):
                    for t in page.get("taskArns", []):
                        try:
                            ecs.stop_task(cluster=arn, task=t, reason="clearledger teardown")
                        except Exception:  # noqa: BLE001
                            pass
            except Exception:  # noqa: BLE001
                pass
            for _ in range(20):
                if attempt(f"ecs cluster {name}", ecs.delete_cluster, cluster=arn):
                    break
                time.sleep(3)
    for status in ("ACTIVE", "INACTIVE"):
        try:
            arns = []
            for page in ecs.get_paginator("list_task_definitions").paginate(familyPrefix=PREFIX, status=status):
                arns += page.get("taskDefinitionArns", [])
            for td in arns:
                fam = td.split("/")[-1].split(":")[0]
                if not owned(fam):
                    continue
                if status == "ACTIVE":
                    attempt(f"task definition {td}", ecs.deregister_task_definition, taskDefinition=td)
                try:
                    ecs.delete_task_definitions(taskDefinitions=[td])
                except Exception:  # noqa: BLE001
                    pass
        except Exception as exc:  # noqa: BLE001
            log(f"task definitions ({status}): {exc}")


@safe
def sweep_elb():
    elb = client("elbv2")
    lbs = elb.describe_load_balancers().get("LoadBalancers", [])
    for lb in lbs:
        mine = owned(lb["LoadBalancerName"])
        if not mine:
            try:
                tags = elb.describe_tags(ResourceArns=[lb["LoadBalancerArn"]])["TagDescriptions"][0]["Tags"]
                mine = tagged(tags)
            except Exception:  # noqa: BLE001
                pass
        if mine:
            try:
                for l in elb.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", []):
                    attempt(f"listener {l['ListenerArn']}", elb.delete_listener, ListenerArn=l["ListenerArn"])
            except Exception:  # noqa: BLE001
                pass
            attempt(f"load balancer {lb['LoadBalancerName']}", elb.delete_load_balancer,
                    LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in elb.describe_target_groups().get("TargetGroups", []):
        mine = owned(tg["TargetGroupName"])
        if not mine:
            try:
                tags = elb.describe_tags(ResourceArns=[tg["TargetGroupArn"]])["TagDescriptions"][0]["Tags"]
                mine = tagged(tags)
            except Exception:  # noqa: BLE001
                pass
        if mine:
            for _ in range(5):
                if attempt(f"target group {tg['TargetGroupName']}", elb.delete_target_group,
                           TargetGroupArn=tg["TargetGroupArn"]):
                    break
                time.sleep(2)


@safe
def sweep_sqs():
    sqs = client("sqs")
    urls = []
    kwargs = {"QueueNamePrefix": PREFIX}
    while True:
        resp = sqs.list_queues(**kwargs)
        urls += resp.get("QueueUrls", [])
        if not resp.get("NextToken"):
            break
        kwargs["NextToken"] = resp["NextToken"]
    # also tagged queues with other names
    try:
        for u in sqs.list_queues().get("QueueUrls", []):
            if u in urls:
                continue
            if tagged(sqs.list_queue_tags(QueueUrl=u).get("Tags", {})):
                urls.append(u)
    except Exception:  # noqa: BLE001
        pass
    for u in urls:
        attempt(f"queue {u}", sqs.delete_queue, QueueUrl=u)


@safe
def sweep_dynamodb():
    ddb = client("dynamodb")
    for page in ddb.get_paginator("list_tables").paginate():
        for t in page.get("TableNames", []):
            mine = owned(t)
            if not mine:
                try:
                    arn = ddb.describe_table(TableName=t)["Table"]["TableArn"]
                    mine = tagged(ddb.list_tags_of_resource(ResourceArn=arn).get("Tags", []))
                except Exception:  # noqa: BLE001
                    pass
            if mine:
                try:
                    ddb.update_table(TableName=t, DeletionProtectionEnabled=False)
                except Exception:  # noqa: BLE001
                    pass
                attempt(f"dynamodb table {t}", ddb.delete_table, TableName=t)


def empty_bucket(s3, bucket):
    kwargs = {"Bucket": bucket}
    while True:
        resp = s3.list_object_versions(**kwargs)
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in resp.get("Versions", [])]
        objs += [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in resp.get("DeleteMarkers", [])]
        for i in range(0, len(objs), 500):
            chunk = objs[i:i + 500]
            try:
                s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
            except Exception:  # noqa: BLE001
                for o in chunk:
                    try:
                        s3.delete_object(Bucket=bucket, Key=o["Key"], VersionId=o["VersionId"])
                    except Exception:  # noqa: BLE001
                        pass
        if not resp.get("IsTruncated"):
            break
        kwargs["KeyMarker"] = resp.get("NextKeyMarker")
        if resp.get("NextVersionIdMarker"):
            kwargs["VersionIdMarker"] = resp["NextVersionIdMarker"]
    # unversioned leftovers
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for o in page.get("Contents", []):
            try:
                s3.delete_object(Bucket=bucket, Key=o["Key"])
            except Exception:  # noqa: BLE001
                pass


@safe
def sweep_s3():
    s3 = client("s3")
    for b in s3.list_buckets().get("Buckets", []):
        name = b["Name"]
        mine = owned(name)
        if not mine:
            try:
                mine = tagged(s3.get_bucket_tagging(Bucket=name).get("TagSet", []))
            except Exception:  # noqa: BLE001
                pass
        if not mine:
            continue
        try:
            s3.delete_bucket_policy(Bucket=name)
        except Exception:  # noqa: BLE001
            pass
        empty_bucket(s3, name)
        attempt(f"bucket {name}", s3.delete_bucket, Bucket=name)


@safe
def sweep_cognito():
    idp = client("cognito-idp")
    for page in idp.get_paginator("list_user_pools").paginate(MaxResults=60):
        for p in page.get("UserPools", []):
            mine = owned(p.get("Name"))
            desc = None
            if not mine:
                try:
                    desc = idp.describe_user_pool(UserPoolId=p["Id"])["UserPool"]
                    mine = tagged(desc.get("UserPoolTags", {}))
                except Exception:  # noqa: BLE001
                    pass
            if not mine:
                continue
            try:
                desc = desc or idp.describe_user_pool(UserPoolId=p["Id"])["UserPool"]
                for dom in (desc.get("Domain"), desc.get("CustomDomain")):
                    if dom:
                        idp.delete_user_pool_domain(Domain=dom, UserPoolId=p["Id"])
            except Exception:  # noqa: BLE001
                pass
            try:
                idp.update_user_pool(UserPoolId=p["Id"], DeletionProtection="INACTIVE")
            except Exception:  # noqa: BLE001
                pass
            attempt(f"user pool {p['Id']} ({p.get('Name')})", idp.delete_user_pool, UserPoolId=p["Id"])


@safe
def sweep_logs():
    logs = client("logs")
    for page in logs.get_paginator("describe_log_groups").paginate():
        for g in page.get("logGroups", []):
            name = g["logGroupName"]
            if PREFIX in name:
                attempt(f"log group {name}", logs.delete_log_group, logGroupName=name)


@safe
def sweep_misc():
    try:
        sns = client("sns")
        for page in sns.get_paginator("list_topics").paginate():
            for t in page.get("Topics", []):
                if owned(t["TopicArn"].split(":")[-1]):
                    attempt(f"topic {t['TopicArn']}", sns.delete_topic, TopicArn=t["TopicArn"])
    except Exception as exc:  # noqa: BLE001
        log(f"sns: {exc}")
    try:
        sm = client("secretsmanager")
        for page in sm.get_paginator("list_secrets").paginate():
            for s in page.get("SecretList", []):
                if owned(s["Name"]) or tagged(s.get("Tags")):
                    attempt(f"secret {s['Name']}", sm.delete_secret, SecretId=s["ARN"], ForceDeleteWithoutRecovery=True)
    except Exception as exc:  # noqa: BLE001
        log(f"secretsmanager: {exc}")
    try:
        ssm = client("ssm")
        names = []
        for page in ssm.get_paginator("describe_parameters").paginate():
            for p in page.get("Parameters", []):
                n = p["Name"]
                if owned(n.lstrip("/")) or n.startswith(f"/clearledger/{PREFIX}"):
                    names.append(n)
        for n in names:
            attempt(f"ssm parameter {n}", ssm.delete_parameter, Name=n)
    except Exception as exc:  # noqa: BLE001
        log(f"ssm: {exc}")
    try:
        cw = client("cloudwatch")
        alarms = [a["AlarmName"] for a in cw.describe_alarms().get("MetricAlarms", []) if owned(a["AlarmName"])]
        if alarms:
            attempt(f"alarms {alarms}", cw.delete_alarms, AlarmNames=alarms)
    except Exception as exc:  # noqa: BLE001
        log(f"cloudwatch: {exc}")
    try:
        ecr = client("ecr")
        for r in ecr.describe_repositories().get("repositories", []):
            if owned(r["repositoryName"]):
                attempt(f"ecr repo {r['repositoryName']}", ecr.delete_repository,
                        repositoryName=r["repositoryName"], force=True)
    except Exception as exc:  # noqa: BLE001
        log(f"ecr: {exc}")


@safe
def sweep_elasticache():
    ec = client("elasticache")
    pending = []
    for rg in ec.describe_replication_groups().get("ReplicationGroups", []):
        if owned(rg["ReplicationGroupId"]):
            if attempt(f"replication group {rg['ReplicationGroupId']}", ec.delete_replication_group,
                       ReplicationGroupId=rg["ReplicationGroupId"]):
                pending.append(("rg", rg["ReplicationGroupId"]))
    for cc in ec.describe_cache_clusters().get("CacheClusters", []):
        if owned(cc["CacheClusterId"]) and not cc.get("ReplicationGroupId"):
            if attempt(f"cache cluster {cc['CacheClusterId']}", ec.delete_cache_cluster,
                       CacheClusterId=cc["CacheClusterId"]):
                pending.append(("cc", cc["CacheClusterId"]))
    deadline = time.time() + 240
    while pending and time.time() < deadline:
        still = []
        for kind, ident in pending:
            try:
                if kind == "rg":
                    ec.describe_replication_groups(ReplicationGroupId=ident)
                else:
                    ec.describe_cache_clusters(CacheClusterId=ident)
                still.append((kind, ident))
            except Exception:  # noqa: BLE001
                pass
        pending = still
        if pending:
            time.sleep(5)
    for g in ec.describe_cache_subnet_groups().get("CacheSubnetGroups", []):
        if owned(g["CacheSubnetGroupName"]):
            attempt(f"cache subnet group {g['CacheSubnetGroupName']}", ec.delete_cache_subnet_group,
                    CacheSubnetGroupName=g["CacheSubnetGroupName"])
    try:
        for g in ec.describe_cache_parameter_groups().get("CacheParameterGroups", []):
            if owned(g["CacheParameterGroupName"]):
                attempt(f"cache parameter group {g['CacheParameterGroupName']}", ec.delete_cache_parameter_group,
                        CacheParameterGroupName=g["CacheParameterGroupName"])
    except Exception:  # noqa: BLE001
        pass


@safe
def sweep_rds():
    rds = client("rds")
    pending = []
    for db in rds.describe_db_instances().get("DBInstances", []):
        ident = db["DBInstanceIdentifier"]
        mine = owned(ident) or tagged(db.get("TagList"))
        if mine:
            try:
                rds.modify_db_instance(DBInstanceIdentifier=ident, DeletionProtection=False, ApplyImmediately=True)
            except Exception:  # noqa: BLE001
                pass
            if attempt(f"db instance {ident}", rds.delete_db_instance, DBInstanceIdentifier=ident,
                       SkipFinalSnapshot=True, DeleteAutomatedBackups=True):
                pending.append(ident)
    deadline = time.time() + 300
    while pending and time.time() < deadline:
        still = []
        for ident in pending:
            try:
                rds.describe_db_instances(DBInstanceIdentifier=ident)
                still.append(ident)
            except Exception:  # noqa: BLE001
                pass
        pending = still
        if pending:
            time.sleep(5)
    try:
        for s in rds.describe_db_snapshots().get("DBSnapshots", []):
            if owned(s["DBSnapshotIdentifier"]) or owned(s.get("DBInstanceIdentifier")):
                attempt(f"db snapshot {s['DBSnapshotIdentifier']}", rds.delete_db_snapshot,
                        DBSnapshotIdentifier=s["DBSnapshotIdentifier"])
    except Exception:  # noqa: BLE001
        pass
    for g in rds.describe_db_subnet_groups().get("DBSubnetGroups", []):
        if owned(g["DBSubnetGroupName"]):
            attempt(f"db subnet group {g['DBSubnetGroupName']}", rds.delete_db_subnet_group,
                    DBSubnetGroupName=g["DBSubnetGroupName"])
    try:
        for g in rds.describe_db_parameter_groups().get("DBParameterGroups", []):
            if owned(g["DBParameterGroupName"]):
                attempt(f"db parameter group {g['DBParameterGroupName']}", rds.delete_db_parameter_group,
                        DBParameterGroupName=g["DBParameterGroupName"])
    except Exception:  # noqa: BLE001
        pass


@safe
def sweep_iam():
    iam = client("iam")
    for page in iam.get_paginator("list_roles").paginate():
        for r in page.get("Roles", []):
            name = r["RoleName"]
            mine = owned(name)
            if not mine:
                try:
                    mine = tagged(iam.list_role_tags(RoleName=name).get("Tags", []))
                except Exception:  # noqa: BLE001
                    pass
            if not mine:
                continue
            try:
                for p in iam.list_role_policies(RoleName=name).get("PolicyNames", []):
                    iam.delete_role_policy(RoleName=name, PolicyName=p)
                for p in iam.list_attached_role_policies(RoleName=name).get("AttachedPolicies", []):
                    iam.detach_role_policy(RoleName=name, PolicyArn=p["PolicyArn"])
                for ip in iam.list_instance_profiles_for_role(RoleName=name).get("InstanceProfiles", []):
                    iam.remove_role_from_instance_profile(InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
            except Exception as exc:  # noqa: BLE001
                log(f"role {name} cleanup: {exc}")
            attempt(f"role {name}", iam.delete_role, RoleName=name)
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page.get("Policies", []):
            if not owned(p["PolicyName"]):
                continue
            arn = p["Arn"]
            try:
                ents = iam.list_entities_for_policy(PolicyArn=arn)
                for r in ents.get("PolicyRoles", []):
                    iam.detach_role_policy(RoleName=r["RoleName"], PolicyArn=arn)
                for u in ents.get("PolicyUsers", []):
                    iam.detach_user_policy(UserName=u["UserName"], PolicyArn=arn)
                for g in ents.get("PolicyGroups", []):
                    iam.detach_group_policy(GroupName=g["GroupName"], PolicyArn=arn)
                for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
                    if not v.get("IsDefaultVersion"):
                        iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
            except Exception:  # noqa: BLE001
                pass
            attempt(f"policy {arn}", iam.delete_policy, PolicyArn=arn)
    try:
        for page in iam.get_paginator("list_instance_profiles").paginate():
            for ip in page.get("InstanceProfiles", []):
                if owned(ip["InstanceProfileName"]):
                    for r in ip.get("Roles", []):
                        iam.remove_role_from_instance_profile(InstanceProfileName=ip["InstanceProfileName"],
                                                              RoleName=r["RoleName"])
                    attempt(f"instance profile {ip['InstanceProfileName']}", iam.delete_instance_profile,
                            InstanceProfileName=ip["InstanceProfileName"])
    except Exception:  # noqa: BLE001
        pass


@safe
def sweep_kms():
    kms = client("kms")
    keys = set()
    for page in kms.get_paginator("list_aliases").paginate():
        for a in page.get("Aliases", []):
            if a.get("AliasName", "").startswith(f"alias/{PREFIX}"):
                if a.get("TargetKeyId"):
                    keys.add(a["TargetKeyId"])
                attempt(f"kms alias {a['AliasName']}", kms.delete_alias, AliasName=a["AliasName"])
    for page in kms.get_paginator("list_keys").paginate():
        for k in page.get("Keys", []):
            kid = k["KeyId"]
            try:
                meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
            except Exception:  # noqa: BLE001
                continue
            if meta.get("KeyManager") == "AWS":
                continue
            mine = kid in keys or owned(meta.get("Description", ""))
            if not mine:
                try:
                    mine = tagged(kms.list_resource_tags(KeyId=kid).get("Tags", []))
                except Exception:  # noqa: BLE001
                    pass
            if mine and meta.get("KeyState") not in ("PendingDeletion", "PendingReplicaDeletion"):
                attempt(f"kms key {kid} (scheduled)", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)


@safe
def sweep_ec2():
    ec2 = client("ec2")
    vpcs = []
    for v in ec2.describe_vpcs().get("Vpcs", []):
        name = next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), "")
        if tagged(v.get("Tags")) or owned(name):
            if not v.get("IsDefault"):
                vpcs.append(v["VpcId"])
    # standalone tagged/prefixed resources outside our VPCs
    for sg in ec2.describe_security_groups().get("SecurityGroups", []):
        if sg.get("GroupName") == "default" or sg["VpcId"] in vpcs:
            continue
        if owned(sg.get("GroupName")) or tagged(sg.get("Tags")):
            revoke_all(ec2, sg)
            attempt(f"security group {sg['GroupId']}", ec2.delete_security_group, GroupId=sg["GroupId"])
    try:
        for a in ec2.describe_addresses().get("Addresses", []):
            if tagged(a.get("Tags")):
                if a.get("AssociationId"):
                    ec2.disassociate_address(AssociationId=a["AssociationId"])
                attempt(f"eip {a.get('AllocationId')}", ec2.release_address, AllocationId=a["AllocationId"])
    except Exception:  # noqa: BLE001
        pass
    try:
        for kp in ec2.describe_key_pairs().get("KeyPairs", []):
            if owned(kp.get("KeyName")) or tagged(kp.get("Tags")):
                attempt(f"key pair {kp['KeyName']}", ec2.delete_key_pair, KeyName=kp["KeyName"])
    except Exception:  # noqa: BLE001
        pass
    for vpc in vpcs:
        teardown_vpc(ec2, vpc)
    # stray tagged subnets / igws / route tables in other VPCs
    try:
        for s in ec2.describe_subnets().get("Subnets", []):
            if tagged(s.get("Tags")) and s["VpcId"] not in vpcs:
                attempt(f"subnet {s['SubnetId']}", ec2.delete_subnet, SubnetId=s["SubnetId"])
        for igw in ec2.describe_internet_gateways().get("InternetGateways", []):
            if tagged(igw.get("Tags")):
                for att in igw.get("Attachments", []):
                    try:
                        ec2.detach_internet_gateway(InternetGatewayId=igw["InternetGatewayId"], VpcId=att["VpcId"])
                    except Exception:  # noqa: BLE001
                        pass
                attempt(f"igw {igw['InternetGatewayId']}", ec2.delete_internet_gateway,
                        InternetGatewayId=igw["InternetGatewayId"])
        for rt in ec2.describe_route_tables().get("RouteTables", []):
            if tagged(rt.get("Tags")) and not any(a.get("Main") for a in rt.get("Associations", [])):
                for a in rt.get("Associations", []):
                    try:
                        ec2.disassociate_route_table(AssociationId=a["RouteTableAssociationId"])
                    except Exception:  # noqa: BLE001
                        pass
                attempt(f"route table {rt['RouteTableId']}", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
    except Exception as exc:  # noqa: BLE001
        log(f"ec2 stray sweep: {exc}")


def revoke_all(ec2, sg):
    try:
        if sg.get("IpPermissions"):
            ec2.revoke_security_group_ingress(GroupId=sg["GroupId"], IpPermissions=sg["IpPermissions"])
    except Exception:  # noqa: BLE001
        pass
    try:
        if sg.get("IpPermissionsEgress"):
            ec2.revoke_security_group_egress(GroupId=sg["GroupId"], IpPermissions=sg["IpPermissionsEgress"])
    except Exception:  # noqa: BLE001
        pass


def teardown_vpc(ec2, vpc):
    flt = [{"Name": "vpc-id", "Values": [vpc]}]
    try:
        for ep in ec2.describe_vpc_endpoints(Filters=flt).get("VpcEndpoints", []):
            ec2.delete_vpc_endpoints(VpcEndpointIds=[ep["VpcEndpointId"]])
    except Exception:  # noqa: BLE001
        pass
    try:
        for nat in ec2.describe_nat_gateways(Filters=flt).get("NatGateways", []):
            if nat.get("State") not in ("deleted", "deleting"):
                ec2.delete_nat_gateway(NatGatewayId=nat["NatGatewayId"])
    except Exception:  # noqa: BLE001
        pass
    try:
        for eni in ec2.describe_network_interfaces(Filters=flt).get("NetworkInterfaces", []):
            att = eni.get("Attachment")
            if att and att.get("AttachmentId"):
                try:
                    ec2.detach_network_interface(AttachmentId=att["AttachmentId"], Force=True)
                except Exception:  # noqa: BLE001
                    pass
            try:
                ec2.delete_network_interface(NetworkInterfaceId=eni["NetworkInterfaceId"])
            except Exception:  # noqa: BLE001
                pass
    except Exception:  # noqa: BLE001
        pass
    sgs = [sg for sg in ec2.describe_security_groups(Filters=flt).get("SecurityGroups", [])
           if sg.get("GroupName") != "default"]
    for sg in sgs:
        revoke_all(ec2, sg)
    for sg in sgs:
        attempt(f"security group {sg['GroupId']}", ec2.delete_security_group, GroupId=sg["GroupId"])
    for s in ec2.describe_subnets(Filters=flt).get("Subnets", []):
        attempt(f"subnet {s['SubnetId']}", ec2.delete_subnet, SubnetId=s["SubnetId"])
    for rt in ec2.describe_route_tables(Filters=flt).get("RouteTables", []):
        if any(a.get("Main") for a in rt.get("Associations", [])):
            continue
        for a in rt.get("Associations", []):
            try:
                ec2.disassociate_route_table(AssociationId=a["RouteTableAssociationId"])
            except Exception:  # noqa: BLE001
                pass
        attempt(f"route table {rt['RouteTableId']}", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
    for igw in ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]).get(
            "InternetGateways", []):
        try:
            ec2.detach_internet_gateway(InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
        except Exception:  # noqa: BLE001
            pass
        attempt(f"igw {igw['InternetGatewayId']}", ec2.delete_internet_gateway,
                InternetGatewayId=igw["InternetGatewayId"])
    for _ in range(5):
        if attempt(f"vpc {vpc}", ec2.delete_vpc, VpcId=vpc):
            break
        time.sleep(3)


def main():
    sweep_scheduler()
    sweep_events()
    sweep_lambda()
    sweep_ecs()
    sweep_elb()
    sweep_sqs()
    sweep_dynamodb()
    sweep_s3()
    sweep_cognito()
    sweep_misc()
    sweep_elasticache()
    sweep_rds()
    sweep_iam()
    sweep_kms()
    sweep_logs()
    sweep_ec2()
    log("sweep complete")


if __name__ == "__main__":
    main()
__CLEARLEDGER_EOF__


if ! tf init -input=false -no-color >"${WORK}/init.log" 2>&1; then
  cat "${WORK}/init.log"
  log "terraform init failed; falling back to sweep only"
fi

for attempt in 1 2 3; do
  if [ "$(state_count)" = "0" ]; then
    break
  fi
  log "terraform destroy (attempt ${attempt})"
  set +e
  tf destroy -auto-approve -input=false -no-color -lock-timeout=120s -refresh=true \
     -var "config_path=${CONFIG_FILE}" >"${WORK}/destroy.log" 2>&1
  rc=$?
  set -e
  tf_filter <"${WORK}/destroy.log"
  if [ "${rc}" -eq 0 ]; then
    break
  fi
  log "terraform destroy failed (rc=${rc}); sweeping before retry"
  python3 "${WORK}/sweep.py" "${PREFIX}" "${REGION}" || true
  sleep 5
done

log "sweeping remaining ${PREFIX} resources (managed leftovers and out-of-band)"
python3 "${WORK}/sweep.py" "${PREFIX}" "${REGION}" || log "sweep reported problems"

# Anything still tracked in state no longer exists (or was swept): drop it.
if [ "$(state_count)" != "0" ]; then
  log "pruning stale entries from terraform state"
  set +e
  tf destroy -auto-approve -input=false -no-color -lock-timeout=60s \
     -var "config_path=${CONFIG_FILE}" >"${WORK}/destroy2.log" 2>&1
  set -e
  tf_filter <"${WORK}/destroy2.log"
fi
if [ "$(state_count)" != "0" ]; then
  tf state list 2>/dev/null | while read -r addr; do
    [ -n "${addr}" ] && tf state rm -lock-timeout=60s "${addr}" >/dev/null 2>&1 || true
  done
fi

# Runtime log groups can be re-created by late writers; sweep logs once more.
python3 "${WORK}/sweep.py" "${PREFIX}" "${REGION}" >"${WORK}/sweep2.log" 2>&1 || true
grep -E "deleted" "${WORK}/sweep2.log" || true

log "remaining managed resources in state: $(state_count)"
log "teardown of ${PREFIX} complete"
exit 0
