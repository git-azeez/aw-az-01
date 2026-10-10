#!/usr/bin/env python3
"""Prefix-scoped cleanup helpers for destroy.sh.

Everything is scoped to the active resource_prefix, either by name (``<prefix>-...``,
``/clearledger/<prefix>/...``, ``alias/<prefix>-...``) or by the tag
``ClearLedgerDeployment = <prefix>``.  Baseline ``cl-base-*`` resources are never touched.

Sub-commands:
  pre     detach out-of-band IAM policies and empty versioned buckets before terraform destroy
  sweep   remove every remaining prefix-scoped resource after terraform destroy
  verify  print leftovers; exit 1 when any remain
"""
import json
import os
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_PATH = os.environ.get("CLEARLEDGER_CONFIG", "/workspace/config/config.json")
CFG = json.load(open(CONFIG_PATH))
REGION = CFG["region"]
ENDPOINT = CFG["aws_endpoint_url"]
PREFIX = CFG["resource_prefix"]
TAG_KEY = "ClearLedgerDeployment"

if not PREFIX or PREFIX.startswith("cl-base"):
    sys.exit("refusing to run cleanup for an empty or baseline resource prefix")


def log(msg):
    print(f"[cleanup] {msg}", flush=True)


_clients = {}


def client(name):
    if name not in _clients:
        cfg = Config(retries={"max_attempts": 5, "mode": "standard"}, read_timeout=120, connect_timeout=10)
        _clients[name] = boto3.client(name, region_name=REGION, endpoint_url=ENDPOINT, aws_access_key_id="test",
                                      aws_secret_access_key="test", config=cfg)
    return _clients[name]


def scoped_name(name):
    return bool(name) and (name == PREFIX or name.startswith(PREFIX + "-"))


def scoped_log_group(name):
    """/clearledger/<prefix>[/...] plus service-created groups such as /aws/lambda/<prefix>-fn."""
    if name == f"/clearledger/{PREFIX}" or name.startswith(f"/clearledger/{PREFIX}/"):
        return True
    return name.startswith(("/aws/", "/ecs/")) and any(scoped_name(seg) for seg in name.split("/") if seg)


def tags_match(tags):
    """tags: dict, list of {Key,Value}, list of {key,value} or list of {TagKey,TagValue}."""
    if not tags:
        return False
    if isinstance(tags, dict):
        return tags.get(TAG_KEY) == PREFIX
    for t in tags:
        k = t.get("Key") or t.get("key") or t.get("TagKey")
        v = t.get("Value") if "Value" in t else t.get("value", t.get("TagValue"))
        if k == TAG_KEY and v == PREFIX:
            return True
    return False


def attempt(desc, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("NoSuchEntity", "NoSuchBucket", "ResourceNotFoundException", "NotFoundException",
                    "QueueDoesNotExist", "AWS.SimpleQueueService.NonExistentQueue", "NoSuchEntityException",
                    "ClusterNotFoundException", "ServiceNotFoundException", "DBInstanceNotFound",
                    "DBInstanceNotFoundFault", "ReplicationGroupNotFoundFault", "LoadBalancerNotFound",
                    "TargetGroupNotFound", "ListenerNotFound", "InvalidGroup.NotFound", "InvalidVpcID.NotFound",
                    "InvalidSubnetID.NotFound", "InvalidRouteTableID.NotFound", "InvalidInternetGatewayID.NotFound",
                    "ResourceNotFoundFault", "DBSubnetGroupNotFoundFault", "CacheSubnetGroupNotFoundFault",
                    "NotFoundException", "NoSuchKey"):
            return None
        log(f"{desc}: {code}: {exc.response.get('Error', {}).get('Message', '')[:200]}")
        return None
    except Exception as exc:  # noqa: BLE001
        log(f"{desc}: {type(exc).__name__}: {str(exc)[:200]}")
        return None


# ------------------------------------------------------------------------------------------- IAM
def iam_roles():
    iam = client("iam")
    out = []
    for page in iam.get_paginator("list_roles").paginate():
        for r in page["Roles"]:
            name = r["RoleName"]
            if name.startswith("cl-base"):
                continue
            if scoped_name(name):
                out.append(name)
                continue
            tags = attempt("list_role_tags", iam.list_role_tags, RoleName=name) or {}
            if tags_match(tags.get("Tags", [])):
                out.append(name)
    return out


def strip_role(name, keep_canonical=False):
    iam = client("iam")
    canonical = f"{name}-policy"
    for page in iam.get_paginator("list_role_policies").paginate(RoleName=name):
        for pn in page["PolicyNames"]:
            if keep_canonical and pn == canonical:
                continue
            log(f"deleting inline policy {pn} from role {name}")
            attempt("delete_role_policy", iam.delete_role_policy, RoleName=name, PolicyName=pn)
    for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=name):
        for ap in page["AttachedPolicies"]:
            log(f"detaching {ap['PolicyArn']} from role {name}")
            attempt("detach_role_policy", iam.detach_role_policy, RoleName=name, PolicyArn=ap["PolicyArn"])


def delete_role(name):
    iam = client("iam")
    strip_role(name)
    for page in iam.get_paginator("list_instance_profiles_for_role").paginate(RoleName=name):
        for ip in page["InstanceProfiles"]:
            attempt("remove_role_from_instance_profile", iam.remove_role_from_instance_profile,
                    InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
            attempt("delete_instance_profile", iam.delete_instance_profile,
                    InstanceProfileName=ip["InstanceProfileName"])
    log(f"deleting IAM role {name}")
    attempt("delete_role", iam.delete_role, RoleName=name)


def iam_policies():
    iam = client("iam")
    out = []
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            name = p["PolicyName"]
            if name.startswith("cl-base"):
                continue
            if scoped_name(name):
                out.append(p)
                continue
            tags = attempt("list_policy_tags", iam.list_policy_tags, PolicyArn=p["Arn"]) or {}
            if tags_match(tags.get("Tags", [])):
                out.append(p)
    return out


def delete_policy(p):
    iam = client("iam")
    arn = p["Arn"]
    ents = attempt("list_entities_for_policy", iam.list_entities_for_policy, PolicyArn=arn) or {}
    for r in ents.get("PolicyRoles", []):
        attempt("detach_role_policy", iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
    for u in ents.get("PolicyUsers", []):
        attempt("detach_user_policy", iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
    for g in ents.get("PolicyGroups", []):
        attempt("detach_group_policy", iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
    vers = attempt("list_policy_versions", iam.list_policy_versions, PolicyArn=arn) or {}
    for v in vers.get("Versions", []):
        if not v.get("IsDefaultVersion"):
            attempt("delete_policy_version", iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
    log(f"deleting IAM policy {arn}")
    attempt("delete_policy", iam.delete_policy, PolicyArn=arn)


# -------------------------------------------------------------------------------------------- S3
def scoped_buckets():
    s3 = client("s3")
    out = []
    for b in s3.list_buckets().get("Buckets", []):
        name = b["Name"]
        if name.startswith("cl-base"):
            continue
        if scoped_name(name):
            out.append(name)
            continue
        t = attempt("get_bucket_tagging", s3.get_bucket_tagging, Bucket=name)
        if t and tags_match(t.get("TagSet", [])):
            out.append(name)
    return out


def empty_bucket(bucket):
    s3 = client("s3")
    total = 0
    while True:
        r = attempt("list_object_versions", s3.list_object_versions, Bucket=bucket) or {}
        entries = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in r.get("Versions", [])]
        entries += [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in r.get("DeleteMarkers", [])]
        if not entries:
            break
        for i in range(0, len(entries), 500):
            d = attempt("delete_objects", s3.delete_objects, Bucket=bucket,
                        Delete={"Objects": entries[i:i + 500], "Quiet": True})
            if d and d.get("Errors"):
                log(f"delete_objects errors in {bucket}: {d['Errors'][:2]}")
        total += len(entries)
        if not r.get("IsTruncated") and total > 0:
            # one more listing to confirm that the bucket is really empty
            continue
    # unversioned leftovers (e.g. versioning suspended)
    while True:
        r = attempt("list_objects_v2", s3.list_objects_v2, Bucket=bucket) or {}
        keys = [{"Key": o["Key"]} for o in r.get("Contents", [])]
        if not keys:
            break
        attempt("delete_objects", s3.delete_objects, Bucket=bucket, Delete={"Objects": keys, "Quiet": True})
    if total:
        log(f"emptied bucket {bucket} ({total} version(s)/delete marker(s))")


# ------------------------------------------------------------------------------------------ pre
def pre():
    for name in iam_roles():
        strip_role(name, keep_canonical=True)
    for b in scoped_buckets():
        empty_bucket(b)


# ----------------------------------------------------------------------------------------- sweep
def sweep_scheduler():
    sch = client("scheduler")
    groups = [g["Name"] for g in (attempt("list_schedule_groups", sch.list_schedule_groups) or {}).get("ScheduleGroups", [])]
    for g in groups or ["default"]:
        kw = {"GroupName": g}
        for s in (attempt("list_schedules", sch.list_schedules, **kw) or {}).get("Schedules", []):
            if scoped_name(s["Name"]):
                log(f"deleting schedule {g}/{s['Name']}")
                attempt("delete_schedule", sch.delete_schedule, Name=s["Name"], GroupName=g)
        if g != "default" and scoped_name(g):
            attempt("delete_schedule_group", sch.delete_schedule_group, Name=g)


def sweep_lambda():
    lam = client("lambda")
    fns = []
    for page in lam.get_paginator("list_functions").paginate():
        fns += [f["FunctionName"] for f in page["Functions"] if scoped_name(f["FunctionName"])]
    for fn in fns:
        for m in (attempt("list_event_source_mappings", lam.list_event_source_mappings, FunctionName=fn) or {}).get("EventSourceMappings", []):
            log(f"deleting event source mapping {m['UUID']}")
            attempt("delete_event_source_mapping", lam.delete_event_source_mapping, UUID=m["UUID"])
        log(f"deleting lambda function {fn}")
        attempt("delete_function", lam.delete_function, FunctionName=fn)
    # mappings whose source queue is scoped but whose function is gone
    for m in (attempt("list_event_source_mappings", lam.list_event_source_mappings) or {}).get("EventSourceMappings", []):
        src = m.get("EventSourceArn", "")
        if src.rsplit(":", 1)[-1].startswith(PREFIX + "-"):
            attempt("delete_event_source_mapping", lam.delete_event_source_mapping, UUID=m["UUID"])


def sweep_ecs():
    ecs = client("ecs")
    clusters = (attempt("list_clusters", ecs.list_clusters) or {}).get("clusterArns", [])
    for c in clusters:
        cname = c.rsplit("/", 1)[-1]
        if not scoped_name(cname):
            continue
        svcs = (attempt("list_services", ecs.list_services, cluster=c) or {}).get("serviceArns", [])
        for s in svcs:
            log(f"deleting ECS service {s}")
            attempt("update_service", ecs.update_service, cluster=c, service=s, desiredCount=0)
            attempt("delete_service", ecs.delete_service, cluster=c, service=s, force=True)
        for t in (attempt("list_tasks", ecs.list_tasks, cluster=c) or {}).get("taskArns", []):
            attempt("stop_task", ecs.stop_task, cluster=c, task=t, reason="destroy")
        log(f"deleting ECS cluster {cname}")
        attempt("delete_cluster", ecs.delete_cluster, cluster=c)
    arns = []
    for page in ecs.get_paginator("list_task_definitions").paginate():
        arns += page.get("taskDefinitionArns", [])
    fam = [a for a in arns if scoped_name(a.rsplit("/", 1)[-1].rsplit(":", 1)[0])]
    for a in fam:
        attempt("deregister_task_definition", ecs.deregister_task_definition, taskDefinition=a)
    if fam and hasattr(ecs, "delete_task_definitions"):
        for i in range(0, len(fam), 10):
            attempt("delete_task_definitions", ecs.delete_task_definitions, taskDefinitions=fam[i:i + 10])


def sweep_elb():
    elb = client("elbv2")
    lbs = [lb for lb in (attempt("describe_load_balancers", elb.describe_load_balancers) or {}).get("LoadBalancers", [])
           if scoped_name(lb["LoadBalancerName"])]
    for lb in lbs:
        for l in (attempt("describe_listeners", elb.describe_listeners, LoadBalancerArn=lb["LoadBalancerArn"]) or {}).get("Listeners", []):
            attempt("delete_listener", elb.delete_listener, ListenerArn=l["ListenerArn"])
        log(f"deleting load balancer {lb['LoadBalancerName']}")
        attempt("delete_load_balancer", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    time.sleep(2)
    for tg in (attempt("describe_target_groups", elb.describe_target_groups) or {}).get("TargetGroups", []):
        if scoped_name(tg["TargetGroupName"]):
            log(f"deleting target group {tg['TargetGroupName']}")
            attempt("delete_target_group", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])


def sweep_rds():
    rds = client("rds")
    for db in (attempt("describe_db_instances", rds.describe_db_instances) or {}).get("DBInstances", []):
        if scoped_name(db["DBInstanceIdentifier"]):
            log(f"deleting RDS instance {db['DBInstanceIdentifier']}")
            attempt("modify_db_instance", rds.modify_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                    DeletionProtection=False, ApplyImmediately=True)
            attempt("delete_db_instance", rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                    SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    deadline = time.time() + 120
    while time.time() < deadline:
        left = [d for d in (attempt("describe_db_instances", rds.describe_db_instances) or {}).get("DBInstances", [])
                if scoped_name(d["DBInstanceIdentifier"])]
        if not left:
            break
        time.sleep(3)
    for g in (attempt("describe_db_subnet_groups", rds.describe_db_subnet_groups) or {}).get("DBSubnetGroups", []):
        if scoped_name(g["DBSubnetGroupName"]):
            attempt("delete_db_subnet_group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    for s in (attempt("describe_db_snapshots", rds.describe_db_snapshots) or {}).get("DBSnapshots", []):
        if scoped_name(s.get("DBInstanceIdentifier", "")) or scoped_name(s["DBSnapshotIdentifier"]):
            attempt("delete_db_snapshot", rds.delete_db_snapshot, DBSnapshotIdentifier=s["DBSnapshotIdentifier"])


def sweep_elasticache():
    ec = client("elasticache")
    for rg in (attempt("describe_replication_groups", ec.describe_replication_groups) or {}).get("ReplicationGroups", []):
        if scoped_name(rg["ReplicationGroupId"]):
            log(f"deleting replication group {rg['ReplicationGroupId']}")
            attempt("delete_replication_group", ec.delete_replication_group,
                    ReplicationGroupId=rg["ReplicationGroupId"], RetainPrimaryCluster=False)
    for c in (attempt("describe_cache_clusters", ec.describe_cache_clusters) or {}).get("CacheClusters", []):
        if scoped_name(c["CacheClusterId"]):
            attempt("delete_cache_cluster", ec.delete_cache_cluster, CacheClusterId=c["CacheClusterId"])
    deadline = time.time() + 90
    while time.time() < deadline:
        left = [r for r in (attempt("describe_replication_groups", ec.describe_replication_groups) or {}).get("ReplicationGroups", [])
                if scoped_name(r["ReplicationGroupId"])]
        if not left:
            break
        time.sleep(3)
    for g in (attempt("describe_cache_subnet_groups", ec.describe_cache_subnet_groups) or {}).get("CacheSubnetGroups", []):
        if scoped_name(g["CacheSubnetGroupName"]):
            attempt("delete_cache_subnet_group", ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])


def sweep_sqs():
    sqs = client("sqs")
    for u in (attempt("list_queues", sqs.list_queues, QueueNamePrefix=PREFIX) or {}).get("QueueUrls", []):
        if scoped_name(u.rsplit("/", 1)[-1]):
            log(f"deleting queue {u}")
            attempt("delete_queue", sqs.delete_queue, QueueUrl=u)


def sweep_dynamodb():
    ddb = client("dynamodb")
    names = []
    for page in ddb.get_paginator("list_tables").paginate():
        names += [n for n in page["TableNames"] if scoped_name(n)]
    for n in names:
        log(f"deleting DynamoDB table {n}")
        attempt("update_table", ddb.update_table, TableName=n, DeletionProtectionEnabled=False)
        attempt("delete_table", ddb.delete_table, TableName=n)


def sweep_s3():
    s3 = client("s3")
    for b in scoped_buckets():
        empty_bucket(b)
        log(f"deleting bucket {b}")
        attempt("delete_bucket", s3.delete_bucket, Bucket=b)


def sweep_cognito():
    cog = client("cognito-idp")
    pools = []
    for page in cog.get_paginator("list_user_pools").paginate(MaxResults=60):
        pools += page["UserPools"]
    for p in pools:
        if not scoped_name(p["Name"]):
            continue
        d = (attempt("describe_user_pool", cog.describe_user_pool, UserPoolId=p["Id"]) or {}).get("UserPool", {})
        if d.get("Domain"):
            attempt("delete_user_pool_domain", cog.delete_user_pool_domain, Domain=d["Domain"], UserPoolId=p["Id"])
        for c in (attempt("list_user_pool_clients", cog.list_user_pool_clients, UserPoolId=p["Id"], MaxResults=60) or {}).get("UserPoolClients", []):
            attempt("delete_user_pool_client", cog.delete_user_pool_client, UserPoolId=p["Id"], ClientId=c["ClientId"])
        log(f"deleting user pool {p['Name']}")
        attempt("delete_user_pool", cog.delete_user_pool, UserPoolId=p["Id"])


def sweep_logs():
    logs = client("logs")
    for page in logs.get_paginator("describe_log_groups").paginate():
        for g in page["logGroups"]:
            n = g["logGroupName"]
            if scoped_log_group(n):
                log(f"deleting log group {n}")
                attempt("delete_log_group", logs.delete_log_group, logGroupName=n)


def sweep_kms():
    kms = client("kms")
    targets = set()
    aliases = []
    for page in kms.get_paginator("list_aliases").paginate():
        aliases += page["Aliases"]
    for a in aliases:
        if a["AliasName"].startswith(f"alias/{PREFIX}-"):
            log(f"deleting KMS alias {a['AliasName']}")
            attempt("delete_alias", kms.delete_alias, AliasName=a["AliasName"])
            if a.get("TargetKeyId"):
                targets.add(a["TargetKeyId"])
    keys = []
    for page in kms.get_paginator("list_keys").paginate():
        keys += [k["KeyId"] for k in page["Keys"]]
    for kid in keys:
        meta = (attempt("describe_key", kms.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
        if meta.get("KeyManager") == "AWS":
            continue
        tags = (attempt("list_resource_tags", kms.list_resource_tags, KeyId=kid) or {}).get("Tags", [])
        if kid in targets or tags_match(tags):
            if meta.get("KeyState") == "PendingDeletion":
                continue
            log(f"scheduling deletion of KMS key {kid}")
            attempt("schedule_key_deletion", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)


def sweep_ec2():
    ec2 = client("ec2")
    flt = [{"Name": f"tag:{TAG_KEY}", "Values": [PREFIX]}]

    def scoped(res):
        name = next((t["Value"] for t in res.get("Tags", []) if t["Key"] == "Name"), "")
        return tags_match(res.get("Tags", [])) or scoped_name(name)

    vpcs = [v for v in ec2.describe_vpcs()["Vpcs"] if not v.get("IsDefault") and scoped(v)]
    vpc_ids = [v["VpcId"] for v in vpcs]
    for eni in (attempt("describe_network_interfaces", ec2.describe_network_interfaces) or {}).get("NetworkInterfaces", []):
        if eni.get("VpcId") in vpc_ids or tags_match(eni.get("TagSet", [])):
            attempt("delete_network_interface", ec2.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"])
    sgs = [g for g in ec2.describe_security_groups()["SecurityGroups"]
           if g["GroupName"] != "default" and (g["VpcId"] in vpc_ids or scoped(g) or scoped_name(g["GroupName"]))]
    # drop rules first so that cross references cannot block deletion
    for g in sgs:
        if g.get("IpPermissions"):
            attempt("revoke_security_group_ingress", ec2.revoke_security_group_ingress, GroupId=g["GroupId"],
                    IpPermissions=g["IpPermissions"])
        if g.get("IpPermissionsEgress"):
            attempt("revoke_security_group_egress", ec2.revoke_security_group_egress, GroupId=g["GroupId"],
                    IpPermissions=g["IpPermissionsEgress"])
    for g in sgs:
        log(f"deleting security group {g['GroupId']}")
        attempt("delete_security_group", ec2.delete_security_group, GroupId=g["GroupId"])
    for v in vpc_ids:
        vf = [{"Name": "vpc-id", "Values": [v]}]
        for rt in ec2.describe_route_tables(Filters=vf)["RouteTables"]:
            for assoc in rt.get("Associations", []):
                if not assoc.get("Main"):
                    attempt("disassociate_route_table", ec2.disassociate_route_table, AssociationId=assoc["RouteTableAssociationId"])
            if not any(a.get("Main") for a in rt.get("Associations", [])):
                attempt("delete_route_table", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        for igw in ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [v]}])["InternetGateways"]:
            attempt("detach_internet_gateway", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=v)
            attempt("delete_internet_gateway", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in ec2.describe_subnets(Filters=vf)["Subnets"]:
            attempt("delete_subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
        log(f"deleting VPC {v}")
        attempt("delete_vpc", ec2.delete_vpc, VpcId=v)
    # detached tagged leftovers outside of a scoped VPC
    for igw in ec2.describe_internet_gateways(Filters=flt)["InternetGateways"]:
        for a in igw.get("Attachments", []):
            attempt("detach_internet_gateway", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=a["VpcId"])
        attempt("delete_internet_gateway", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
    for sn in ec2.describe_subnets(Filters=flt)["Subnets"]:
        attempt("delete_subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
    for rt in ec2.describe_route_tables(Filters=flt)["RouteTables"]:
        for assoc in rt.get("Associations", []):
            if not assoc.get("Main"):
                attempt("disassociate_route_table", ec2.disassociate_route_table, AssociationId=assoc["RouteTableAssociationId"])
        attempt("delete_route_table", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])


def sweep_iam():
    for name in iam_roles():
        delete_role(name)
    for p in iam_policies():
        delete_policy(p)


def sweep():
    # order matters: consumers first, then the stores, then networking and identity
    for fn in (sweep_scheduler, sweep_lambda, sweep_ecs, sweep_elb, sweep_rds, sweep_elasticache, sweep_sqs,
               sweep_dynamodb, sweep_s3, sweep_cognito, sweep_ec2, sweep_logs, sweep_iam, sweep_kms):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            log(f"{fn.__name__} failed: {type(exc).__name__}: {str(exc)[:300]}")


# ---------------------------------------------------------------------------------------- verify
def verify():
    left = []
    try:
        left += [f"iam role {n}" for n in iam_roles()]
        left += [f"iam policy {p['PolicyName']}" for p in iam_policies()]
        left += [f"s3 bucket {b}" for b in scoped_buckets()]
        sqs = client("sqs")
        left += [f"queue {u}" for u in (sqs.list_queues(QueueNamePrefix=PREFIX).get("QueueUrls", []))]
        ddb = client("dynamodb")
        left += [f"dynamodb table {n}" for n in ddb.list_tables()["TableNames"] if scoped_name(n)]
        lam = client("lambda")
        left += [f"lambda {f['FunctionName']}" for f in lam.list_functions()["Functions"] if scoped_name(f["FunctionName"])]
        sch = client("scheduler")
        left += [f"schedule {s['Name']}" for s in sch.list_schedules().get("Schedules", []) if scoped_name(s["Name"])]
        logs = client("logs")
        for page in logs.get_paginator("describe_log_groups").paginate():
            left += [f"log group {g['logGroupName']}" for g in page["logGroups"] if scoped_log_group(g["logGroupName"])]
        kms = client("kms")
        for page in kms.get_paginator("list_aliases").paginate():
            left += [f"kms alias {a['AliasName']}" for a in page["Aliases"] if a["AliasName"].startswith(f"alias/{PREFIX}-")]
        ec2 = client("ec2")
        left += [f"vpc {v['VpcId']}" for v in ec2.describe_vpcs(Filters=[{"Name": f"tag:{TAG_KEY}", "Values": [PREFIX]}])["Vpcs"]]
        left += [f"security group {g['GroupId']}" for g in ec2.describe_security_groups(Filters=[{"Name": f"tag:{TAG_KEY}", "Values": [PREFIX]}])["SecurityGroups"]]
        ecs = client("ecs")
        left += [f"ecs cluster {c}" for c in ecs.list_clusters().get("clusterArns", []) if scoped_name(c.rsplit("/", 1)[-1])]
        rds = client("rds")
        left += [f"rds {d['DBInstanceIdentifier']}" for d in rds.describe_db_instances().get("DBInstances", []) if scoped_name(d["DBInstanceIdentifier"])]
        elb = client("elbv2")
        left += [f"load balancer {l['LoadBalancerName']}" for l in elb.describe_load_balancers().get("LoadBalancers", []) if scoped_name(l["LoadBalancerName"])]
        ec = client("elasticache")
        left += [f"valkey {r['ReplicationGroupId']}" for r in ec.describe_replication_groups().get("ReplicationGroups", []) if scoped_name(r["ReplicationGroupId"])]
        cog = client("cognito-idp")
        left += [f"user pool {p['Name']}" for p in cog.list_user_pools(MaxResults=60).get("UserPools", []) if scoped_name(p["Name"])]
    except Exception as exc:  # noqa: BLE001
        log(f"verify error: {type(exc).__name__}: {exc}")
        left.append(f"verification error: {exc}")
    for item in left:
        log(f"LEFTOVER: {item}")
    return 1 if left else 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "pre":
        pre()
    elif cmd == "sweep":
        sweep()
    elif cmd == "verify":
        sys.exit(verify())
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
