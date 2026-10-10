#!/usr/bin/env python3
"""Prefix-scoped teardown sweeper used by destroy.sh after `terraform destroy`.

Removes every resource whose name/identifier starts with <resource_prefix>
(or that carries ClearLedgerDeployment=<resource_prefix>), including
out-of-band operational leftovers. Baseline `cl-base-*` resources are never
touched.
"""
import json
import os
import re
import sys
import time

import boto3
from botocore.config import Config

CONFIG = json.load(open(sys.argv[1]))
PREFIX = CONFIG["resource_prefix"]
REGION = CONFIG["region"]
ENDPOINT = CONFIG["aws_endpoint_url"]
TAG_KEY = "ClearLedgerDeployment"
BASELINE = "cl-base"

if not PREFIX or PREFIX.startswith(BASELINE):
    sys.exit(f"refusing to sweep with prefix {PREFIX!r}")

_PREFIX_RE = re.compile(r"^" + re.escape(PREFIX) + r"($|[-_./:])")
_cfg = Config(region_name=REGION, retries={"max_attempts": 3, "mode": "standard"},
              read_timeout=60, connect_timeout=10, s3={"addressing_style": "path"})


def log(msg):
    print(f"[sweep] {msg}", flush=True)


def ours(name):
    return bool(name) and not name.startswith(BASELINE) and bool(_PREFIX_RE.match(name))


def tagged(tags):
    """Accept list-of-{Key,Value} or dict tags."""
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


def c(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION,
                        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
                        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
                        config=_cfg)


def safe(desc, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:  # noqa: BLE001
        msg = str(e)
        if not re.search(r"NotFound|NoSuch|does not exist|not found|ResourceNotFound|NonExistent", msg):
            log(f"{desc}: {msg[:200]}")
        return None


def paginate(client, op, key, **kw):
    try:
        if client.can_paginate(op):
            out = []
            for page in client.get_paginator(op).paginate(**kw):
                out.extend(page.get(key, []))
            return out
        return getattr(client, op)(**kw).get(key, [])
    except Exception as e:  # noqa: BLE001
        log(f"list {op}: {str(e)[:200]}")
        return []


# ------------------------------------------------------------- scheduler ----
def sweep_scheduler():
    sch = c("scheduler")
    for s in paginate(sch, "list_schedules", "Schedules"):
        if ours(s.get("Name")) or ours(s.get("GroupName")):
            log(f"scheduler: deleting schedule {s.get('GroupName')}/{s['Name']}")
            safe("delete schedule", sch.delete_schedule, Name=s["Name"], GroupName=s.get("GroupName", "default"))
    for g in paginate(sch, "list_schedule_groups", "ScheduleGroups"):
        if ours(g.get("Name")):
            log(f"scheduler: deleting group {g['Name']}")
            safe("delete schedule group", sch.delete_schedule_group, Name=g["Name"])
    ev = c("events")
    for r in paginate(ev, "list_rules", "Rules"):
        if ours(r.get("Name")):
            tg = safe("targets", ev.list_targets_by_rule, Rule=r["Name"]) or {}
            ids = [t["Id"] for t in tg.get("Targets", [])]
            if ids:
                safe("remove targets", ev.remove_targets, Rule=r["Name"], Ids=ids, Force=True)
            log(f"events: deleting rule {r['Name']}")
            safe("delete rule", ev.delete_rule, Name=r["Name"], Force=True)


# ---------------------------------------------------------------- lambda ----
def sweep_lambda():
    lam = c("lambda")
    for m in paginate(lam, "list_event_source_mappings", "EventSourceMappings"):
        fn = (m.get("FunctionArn") or "").split(":function:")[-1].split(":")[0]
        src = (m.get("EventSourceArn") or "").split(":")[-1]
        if ours(fn) or ours(src):
            log(f"lambda: deleting event source mapping {m['UUID']}")
            safe("delete esm", lam.delete_event_source_mapping, UUID=m["UUID"])
    for f in paginate(lam, "list_functions", "Functions"):
        if ours(f["FunctionName"]):
            log(f"lambda: deleting function {f['FunctionName']}")
            safe("delete function", lam.delete_function, FunctionName=f["FunctionName"])


# ------------------------------------------------------------------- ecs ----
def sweep_ecs():
    ecs = c("ecs")
    for arn in paginate(ecs, "list_clusters", "clusterArns"):
        name = arn.split("/")[-1]
        if not ours(name):
            continue
        for svc in paginate(ecs, "list_services", "serviceArns", cluster=arn):
            log(f"ecs: deleting service {svc}")
            safe("scale service", ecs.update_service, cluster=arn, service=svc, desiredCount=0)
            safe("delete service", ecs.delete_service, cluster=arn, service=svc, force=True)
        for t in paginate(ecs, "list_tasks", "taskArns", cluster=arn):
            safe("stop task", ecs.stop_task, cluster=arn, task=t, reason="clearledger destroy")
        log(f"ecs: deleting cluster {name}")
        for _ in range(10):
            if safe("delete cluster", ecs.delete_cluster, cluster=arn) is not None:
                break
            time.sleep(3)
    for status in ("ACTIVE", "INACTIVE"):
        for td in paginate(ecs, "list_task_definitions", "taskDefinitionArns", status=status):
            fam = td.split("/")[-1].rsplit(":", 1)[0]
            if ours(fam):
                if status == "ACTIVE":
                    safe("deregister task def", ecs.deregister_task_definition, taskDefinition=td)
                if hasattr(ecs, "delete_task_definitions"):
                    safe("delete task def", ecs.delete_task_definitions, taskDefinitions=[td])


# ------------------------------------------------------------------- elb ----
def sweep_elb():
    elb = c("elbv2")
    for lb in paginate(elb, "describe_load_balancers", "LoadBalancers"):
        if ours(lb["LoadBalancerName"]):
            for li in paginate(elb, "describe_listeners", "Listeners", LoadBalancerArn=lb["LoadBalancerArn"]):
                safe("delete listener", elb.delete_listener, ListenerArn=li["ListenerArn"])
            log(f"elb: deleting load balancer {lb['LoadBalancerName']}")
            safe("delete lb", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in paginate(elb, "describe_target_groups", "TargetGroups"):
        if ours(tg["TargetGroupName"]):
            log(f"elb: deleting target group {tg['TargetGroupName']}")
            safe("delete tg", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])


# ------------------------------------------------------------------- rds ----
def sweep_rds():
    rds = c("rds")
    pending = []
    for db in paginate(rds, "describe_db_instances", "DBInstances"):
        if ours(db["DBInstanceIdentifier"]):
            log(f"rds: deleting instance {db['DBInstanceIdentifier']}")
            safe("rds deletion protection", rds.modify_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 DeletionProtection=False, ApplyImmediately=True) if db.get("DeletionProtection") else None
            safe("delete db", rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
            pending.append(db["DBInstanceIdentifier"])
    for snap in paginate(rds, "describe_db_snapshots", "DBSnapshots", SnapshotType="manual"):
        if ours(snap["DBSnapshotIdentifier"]):
            safe("delete snapshot", rds.delete_db_snapshot, DBSnapshotIdentifier=snap["DBSnapshotIdentifier"])
    deadline = time.time() + 240
    while pending and time.time() < deadline:
        live = {d["DBInstanceIdentifier"] for d in paginate(rds, "describe_db_instances", "DBInstances")}
        pending = [p for p in pending if p in live]
        if pending:
            time.sleep(5)
    for g in paginate(rds, "describe_db_subnet_groups", "DBSubnetGroups"):
        if ours(g["DBSubnetGroupName"]):
            log(f"rds: deleting subnet group {g['DBSubnetGroupName']}")
            safe("delete db subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    for g in paginate(rds, "describe_db_parameter_groups", "DBParameterGroups"):
        if ours(g["DBParameterGroupName"]):
            safe("delete db param group", rds.delete_db_parameter_group, DBParameterGroupName=g["DBParameterGroupName"])


# ----------------------------------------------------------- elasticache ----
def sweep_elasticache():
    ec = c("elasticache")
    pending = []
    for rg in paginate(ec, "describe_replication_groups", "ReplicationGroups"):
        if ours(rg["ReplicationGroupId"]):
            log(f"elasticache: deleting replication group {rg['ReplicationGroupId']}")
            safe("delete rg", ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"],
                 RetainPrimaryCluster=False)
            pending.append(rg["ReplicationGroupId"])
    for cc in paginate(ec, "describe_cache_clusters", "CacheClusters"):
        if ours(cc["CacheClusterId"]) and not cc.get("ReplicationGroupId"):
            log(f"elasticache: deleting cache cluster {cc['CacheClusterId']}")
            safe("delete cache cluster", ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])
    deadline = time.time() + 240
    while pending and time.time() < deadline:
        live = {r["ReplicationGroupId"] for r in paginate(ec, "describe_replication_groups", "ReplicationGroups")}
        pending = [p for p in pending if p in live]
        if pending:
            time.sleep(5)
    for g in paginate(ec, "describe_cache_subnet_groups", "CacheSubnetGroups"):
        if ours(g["CacheSubnetGroupName"]):
            log(f"elasticache: deleting subnet group {g['CacheSubnetGroupName']}")
            safe("delete cache subnet group", ec.delete_cache_subnet_group,
                 CacheSubnetGroupName=g["CacheSubnetGroupName"])


# -------------------------------------------------------- dynamodb / sqs ----
def sweep_dynamodb():
    d = c("dynamodb")
    for t in paginate(d, "list_tables", "TableNames"):
        if ours(t):
            log(f"dynamodb: deleting table {t}")
            safe("ddb deletion protection", d.update_table, TableName=t, DeletionProtectionEnabled=False)
            safe("delete table", d.delete_table, TableName=t)


def sweep_sqs():
    q = c("sqs")
    for url in paginate(q, "list_queues", "QueueUrls"):
        if ours(url.rstrip("/").split("/")[-1]):
            log(f"sqs: deleting queue {url}")
            safe("delete queue", q.delete_queue, QueueUrl=url)


# -------------------------------------------------------------------- s3 ----
def empty_bucket(s3, bucket):
    while True:
        r = safe("list versions", s3.list_object_versions, Bucket=bucket) or {}
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]}
                for v in r.get("Versions", []) + r.get("DeleteMarkers", [])]
        if not objs:
            r2 = safe("list objects", s3.list_objects_v2, Bucket=bucket) or {}
            objs = [{"Key": o["Key"]} for o in r2.get("Contents", [])]
            if not objs:
                return
        for i in range(0, len(objs), 500):
            res = safe("delete objects", s3.delete_objects, Bucket=bucket,
                       Delete={"Objects": objs[i:i + 500], "Quiet": True})
            if res is None or res.get("Errors"):
                for o in objs[i:i + 500]:
                    safe("delete object", s3.delete_object, Bucket=bucket, **o)


def sweep_s3():
    s3 = c("s3")
    for b in (safe("list buckets", s3.list_buckets) or {}).get("Buckets", []):
        if ours(b["Name"]):
            log(f"s3: emptying and deleting bucket {b['Name']}")
            safe("bucket policy", s3.delete_bucket_policy, Bucket=b["Name"])
            empty_bucket(s3, b["Name"])
            for _ in range(5):
                if safe("delete bucket", s3.delete_bucket, Bucket=b["Name"]) is not None:
                    break
                empty_bucket(s3, b["Name"])
                time.sleep(1)


# --------------------------------------------------------------- cognito ----
def sweep_cognito():
    cg = c("cognito-idp")
    pools = []
    token = None
    while True:
        kw = {"MaxResults": 60}
        if token:
            kw["NextToken"] = token
        r = safe("list pools", cg.list_user_pools, **kw) or {}
        pools.extend(r.get("UserPools", []))
        token = r.get("NextToken")
        if not token:
            break
    for p in pools:
        if not ours(p.get("Name")):
            continue
        d = (safe("describe pool", cg.describe_user_pool, UserPoolId=p["Id"]) or {}).get("UserPool", {})
        for dom in filter(None, [d.get("Domain"), d.get("CustomDomain")]):
            safe("delete domain", cg.delete_user_pool_domain, Domain=dom, UserPoolId=p["Id"])
        if d.get("DeletionProtection") == "ACTIVE":
            safe("deletion protection", cg.update_user_pool, UserPoolId=p["Id"], DeletionProtection="INACTIVE")
        log(f"cognito: deleting user pool {p['Name']} ({p['Id']})")
        safe("delete pool", cg.delete_user_pool, UserPoolId=p["Id"])


# ------------------------------------------------------------------- iam ----
def sweep_iam():
    iam = c("iam")
    for r in paginate(iam, "list_roles", "Roles"):
        name = r["RoleName"]
        tags = (safe("role tags", iam.list_role_tags, RoleName=name) or {}).get("Tags", []) if not ours(name) else []
        if not (ours(name) or tagged(tags)) or name.startswith(BASELINE):
            continue
        log(f"iam: deleting role {name}")
        for p in paginate(iam, "list_role_policies", "PolicyNames", RoleName=name):
            safe("delete inline", iam.delete_role_policy, RoleName=name, PolicyName=p)
        for p in paginate(iam, "list_attached_role_policies", "AttachedPolicies", RoleName=name):
            safe("detach", iam.detach_role_policy, RoleName=name, PolicyArn=p["PolicyArn"])
        for ip in paginate(iam, "list_instance_profiles_for_role", "InstanceProfiles", RoleName=name):
            safe("remove from ip", iam.remove_role_from_instance_profile,
                 InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
        safe("delete role", iam.delete_role, RoleName=name)
    for u in paginate(iam, "list_users", "Users"):
        name = u["UserName"]
        if not ours(name):
            continue
        log(f"iam: deleting user {name}")
        for p in paginate(iam, "list_user_policies", "PolicyNames", UserName=name):
            safe("delete user inline", iam.delete_user_policy, UserName=name, PolicyName=p)
        for p in paginate(iam, "list_attached_user_policies", "AttachedPolicies", UserName=name):
            safe("detach user", iam.detach_user_policy, UserName=name, PolicyArn=p["PolicyArn"])
        for k in paginate(iam, "list_access_keys", "AccessKeyMetadata", UserName=name):
            safe("delete key", iam.delete_access_key, UserName=name, AccessKeyId=k["AccessKeyId"])
        for g in paginate(iam, "list_groups_for_user", "Groups", UserName=name):
            safe("remove from group", iam.remove_user_from_group, GroupName=g["GroupName"], UserName=name)
        safe("login profile", iam.delete_login_profile, UserName=name)
        safe("delete user", iam.delete_user, UserName=name)
    for g in paginate(iam, "list_groups", "Groups"):
        name = g["GroupName"]
        if not ours(name):
            continue
        log(f"iam: deleting group {name}")
        for u in (safe("get group", iam.get_group, GroupName=name) or {}).get("Users", []):
            safe("remove user", iam.remove_user_from_group, GroupName=name, UserName=u["UserName"])
        for p in paginate(iam, "list_group_policies", "PolicyNames", GroupName=name):
            safe("delete group inline", iam.delete_group_policy, GroupName=name, PolicyName=p)
        for p in paginate(iam, "list_attached_group_policies", "AttachedPolicies", GroupName=name):
            safe("detach group", iam.detach_group_policy, GroupName=name, PolicyArn=p["PolicyArn"])
        safe("delete group", iam.delete_group, GroupName=name)
    for ip in paginate(iam, "list_instance_profiles", "InstanceProfiles"):
        if ours(ip["InstanceProfileName"]):
            for r in ip.get("Roles", []):
                safe("remove role", iam.remove_role_from_instance_profile,
                     InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
            safe("delete ip", iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
    for p in paginate(iam, "list_policies", "Policies", Scope="Local"):
        name, arn = p["PolicyName"], p["Arn"]
        if not ours(name):
            continue
        log(f"iam: deleting customer-managed policy {name}")
        ents = safe("entities", iam.list_entities_for_policy, PolicyArn=arn) or {}
        for r in ents.get("PolicyRoles", []):
            safe("detach role", iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
        for u in ents.get("PolicyUsers", []):
            safe("detach user", iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
        for g in ents.get("PolicyGroups", []):
            safe("detach group", iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
        for v in paginate(iam, "list_policy_versions", "Versions", PolicyArn=arn):
            if not v.get("IsDefaultVersion"):
                safe("delete version", iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
        safe("delete policy", iam.delete_policy, PolicyArn=arn)


# ------------------------------------------------------------------ logs ----
def sweep_logs():
    lg = c("logs")
    prefixes = [f"/clearledger/{PREFIX}", f"/aws/lambda/{PREFIX}", f"/ecs/{PREFIX}",
                f"/aws/ecs/{PREFIX}", f"/aws/vendedlogs/{PREFIX}", PREFIX]
    seen = set()
    for pfx in prefixes:
        for g in paginate(lg, "describe_log_groups", "logGroups", logGroupNamePrefix=pfx):
            n = g["logGroupName"]
            if n in seen:
                continue
            if n.startswith(f"/clearledger/{PREFIX}/") or n == f"/clearledger/{PREFIX}" or ours(n.split("/")[-1]) \
                    or ours(n):
                if BASELINE in n:
                    continue
                seen.add(n)
                log(f"logs: deleting log group {n}")
                safe("delete log group", lg.delete_log_group, logGroupName=n)


# ------------------------------------------------------------------- kms ----
def sweep_kms():
    kms = c("kms")
    targets = set()
    for a in paginate(kms, "list_aliases", "Aliases"):
        n = a.get("AliasName", "")
        if n.startswith("alias/") and ours(n[len("alias/"):]):
            log(f"kms: deleting alias {n}")
            if a.get("TargetKeyId"):
                targets.add(a["TargetKeyId"])
            safe("delete alias", kms.delete_alias, AliasName=n)
    for k in paginate(kms, "list_keys", "Keys"):
        kid = k["KeyId"]
        meta = (safe("describe key", kms.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
        if meta.get("KeyManager") == "AWS":
            continue
        tags = (safe("key tags", kms.list_resource_tags, KeyId=kid) or {}).get("Tags", [])
        desc = meta.get("Description") or ""
        if kid in targets or tagged([{"Key": t.get("TagKey"), "Value": t.get("TagValue")} for t in tags]) \
                or ours(desc.split(" ")[0] if desc else ""):
            if meta.get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
                continue
            log(f"kms: scheduling deletion of key {kid}")
            safe("schedule deletion", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)


# ------------------------------------------------------- secrets / ssm ----
def sweep_misc():
    sm = c("secretsmanager")
    for s in paginate(sm, "list_secrets", "SecretList"):
        if ours(s.get("Name")) or tagged(s.get("Tags")):
            log(f"secretsmanager: deleting {s['Name']}")
            safe("delete secret", sm.delete_secret, SecretId=s["ARN"], ForceDeleteWithoutRecovery=True)
    ssm = c("ssm")
    for p in paginate(ssm, "describe_parameters", "Parameters"):
        n = p.get("Name", "")
        if ours(n) or ours(n.lstrip("/")) or n.startswith(f"/clearledger/{PREFIX}/"):
            log(f"ssm: deleting {n}")
            safe("delete param", ssm.delete_parameter, Name=n)
    sns = c("sns")
    for t in paginate(sns, "list_topics", "Topics"):
        if ours(t["TopicArn"].split(":")[-1]):
            log(f"sns: deleting {t['TopicArn']}")
            safe("delete topic", sns.delete_topic, TopicArn=t["TopicArn"])


# ------------------------------------------------------------------- ec2 ----
def sweep_ec2():
    ec2 = c("ec2")
    vpcs = []
    for v in paginate(ec2, "describe_vpcs", "Vpcs"):
        name = next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), "")
        if v.get("IsDefault"):
            continue
        if tagged(v.get("Tags")) or ours(name):
            vpcs.append(v["VpcId"])
    # Stray security groups named with the prefix outside our VPCs.
    sgs = [g for g in paginate(ec2, "describe_security_groups", "SecurityGroups")
           if g.get("GroupName") != "default" and (g.get("VpcId") in vpcs or ours(g.get("GroupName"))
                                                    or tagged(g.get("Tags")))]
    for g in sgs:
        if g.get("IpPermissions"):
            safe("revoke ingress", ec2.revoke_security_group_ingress, GroupId=g["GroupId"],
                 IpPermissions=g["IpPermissions"])
        if g.get("IpPermissionsEgress"):
            safe("revoke egress", ec2.revoke_security_group_egress, GroupId=g["GroupId"],
                 IpPermissions=g["IpPermissionsEgress"])
    for vpc in vpcs:
        flt = [{"Name": "vpc-id", "Values": [vpc]}]
        for eni in paginate(ec2, "describe_network_interfaces", "NetworkInterfaces", Filters=flt):
            if eni.get("Attachment", {}).get("AttachmentId"):
                safe("detach eni", ec2.detach_network_interface, AttachmentId=eni["Attachment"]["AttachmentId"],
                     Force=True)
            safe("delete eni", ec2.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"])
        for ep in paginate(ec2, "describe_vpc_endpoints", "VpcEndpoints", Filters=flt):
            safe("delete endpoint", ec2.delete_vpc_endpoints, VpcEndpointIds=[ep["VpcEndpointId"]])
        for nat in paginate(ec2, "describe_nat_gateways", "NatGateways", Filters=flt):
            safe("delete nat", ec2.delete_nat_gateway, NatGatewayId=nat["NatGatewayId"])
    for g in sgs:
        log(f"ec2: deleting security group {g['GroupId']} ({g.get('GroupName')})")
        safe("delete sg", ec2.delete_security_group, GroupId=g["GroupId"])
    for vpc in vpcs:
        flt = [{"Name": "vpc-id", "Values": [vpc]}]
        for rt in paginate(ec2, "describe_route_tables", "RouteTables", Filters=flt):
            main = any(a.get("Main") for a in rt.get("Associations", []))
            for a in rt.get("Associations", []):
                if not a.get("Main"):
                    safe("disassociate rt", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            if not main:
                log(f"ec2: deleting route table {rt['RouteTableId']}")
                safe("delete rt", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        for igw in paginate(ec2, "describe_internet_gateways", "InternetGateways",
                            Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]):
            safe("detach igw", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
            log(f"ec2: deleting internet gateway {igw['InternetGatewayId']}")
            safe("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in paginate(ec2, "describe_subnets", "Subnets", Filters=flt):
            log(f"ec2: deleting subnet {sn['SubnetId']}")
            safe("delete subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
        for sg in paginate(ec2, "describe_security_groups", "SecurityGroups", Filters=flt):
            if sg.get("GroupName") != "default":
                safe("delete sg", ec2.delete_security_group, GroupId=sg["GroupId"])
        log(f"ec2: deleting vpc {vpc}")
        safe("delete vpc", ec2.delete_vpc, VpcId=vpc)
    # Detached, tagged internet gateways.
    for igw in paginate(ec2, "describe_internet_gateways", "InternetGateways"):
        if tagged(igw.get("Tags")) and not igw.get("Attachments"):
            safe("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])


def main():
    steps = [sweep_scheduler, sweep_lambda, sweep_ecs, sweep_elb, sweep_rds, sweep_elasticache,
             sweep_dynamodb, sweep_sqs, sweep_s3, sweep_cognito, sweep_iam, sweep_logs, sweep_misc,
             sweep_kms, sweep_ec2]
    for step in steps:
        try:
            step()
        except Exception as e:  # noqa: BLE001
            log(f"{step.__name__} failed: {e}")


if __name__ == "__main__":
    main()
