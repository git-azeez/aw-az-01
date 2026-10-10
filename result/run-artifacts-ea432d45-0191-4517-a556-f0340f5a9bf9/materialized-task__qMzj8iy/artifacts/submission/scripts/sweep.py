#!/usr/bin/env python3
"""Prefix-scoped cleanup used by destroy.sh.

Removes everything that belongs to the active resource_prefix (name prefix or the
ClearLedgerDeployment=<prefix> tag), including out-of-band resources and policy
attachments that Terraform does not know about. Resources of other deployments and
the cl-base-* baseline are never touched.

  pre     detach / delete IAM policies and empty versioned S3 buckets so that
          `terraform destroy` cannot be blocked by out-of-band objects
  all     delete every remaining resource of the prefix (dependency ordered)
  verify  list what is left (exit 1 if anything remains)
"""
import argparse
import json
import re
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

CFG = {}
PREFIX = ""
TAG = "ClearLedgerDeployment"
CLIENTS = {}
LEFTOVERS = []


def log(msg):
    print(f"[sweep] {msg}", flush=True)


def client(name):
    if name not in CLIENTS:
        CLIENTS[name] = boto3.client(
            name, endpoint_url=CFG["aws_endpoint_url"], region_name=CFG["region"],
            aws_access_key_id="test", aws_secret_access_key="test",
            config=Config(read_timeout=120, connect_timeout=10, retries={"max_attempts": 4, "mode": "standard"}),
        )
    return CLIENTS[name]


def name_match(name):
    if not name or name.startswith("cl-base"):
        return False
    return name == PREFIX or name.startswith(PREFIX + "-")


def tag_match(tags):
    if isinstance(tags, list):
        tags = {t.get("Key", t.get("key")): t.get("Value", t.get("value")) for t in tags}
    return bool(tags) and tags.get(TAG) == PREFIX


def loggroup_match(name):
    if name.startswith("cl-base") or "/cl-base" in name:
        return False
    return re.search(r"(^|/)" + re.escape(PREFIX) + r"(-|/|$)", name) is not None


def attempt(label, fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code and any(s in code for s in ("NotFound", "NoSuch", "ResourceNotFound", "DoesNotExist", "InvalidParameterValue.NotFound")):
            return None
        log(f"warn: {label}: {code}: {exc.response.get('Error', {}).get('Message', '')[:160]}")
    except Exception as exc:  # noqa: BLE001
        log(f"warn: {label}: {type(exc).__name__}: {str(exc)[:160]}")
    return None


def wait_until(label, predicate, timeout=240, step=4):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if predicate():
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(step)
    log(f"warn: timed out waiting for {label}")
    return False


# ----------------------------------------------------------------------------- IAM

def iam_roles():
    iam = client("iam")
    roles = []
    for page in iam.get_paginator("list_roles").paginate():
        for r in page["Roles"]:
            if r["RoleName"].startswith("cl-base"):
                continue
            if name_match(r["RoleName"]):
                roles.append(r["RoleName"])
                continue
            tags = attempt("list_role_tags", iam.list_role_tags, RoleName=r["RoleName"])
            if tags and tag_match(tags.get("Tags", [])):
                roles.append(r["RoleName"])
    return roles


def iam_policies():
    iam = client("iam")
    out = []
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            if p["PolicyName"].startswith("cl-base"):
                continue
            if name_match(p["PolicyName"]):
                out.append(p["Arn"])
                continue
            tags = attempt("list_policy_tags", iam.list_policy_tags, PolicyArn=p["Arn"])
            if tags and tag_match(tags.get("Tags", [])):
                out.append(p["Arn"])
    return out


def delete_policy(arn):
    iam = client("iam")
    for kind, lister, detach, key in (
        ("PolicyRoles", "RoleName", iam.detach_role_policy, "RoleName"),
        ("PolicyUsers", "UserName", iam.detach_user_policy, "UserName"),
        ("PolicyGroups", "GroupName", iam.detach_group_policy, "GroupName"),
    ):
        for page in iam.get_paginator("list_entities_for_policy").paginate(PolicyArn=arn):
            for ent in page[kind]:
                attempt("detach policy", detach, **{key: ent[lister], "PolicyArn": arn})
    for v in (attempt("list policy versions", iam.list_policy_versions, PolicyArn=arn) or {}).get("Versions", []):
        if not v["IsDefaultVersion"]:
            attempt("delete policy version", iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
    attempt("delete policy", iam.delete_policy, PolicyArn=arn)
    log(f"IAM policy deleted: {arn.rsplit('/', 1)[-1]}")


def clean_role(role, delete):
    iam = client("iam")
    for name in (attempt("list role policies", iam.list_role_policies, RoleName=role) or {}).get("PolicyNames", []):
        attempt("delete role policy", iam.delete_role_policy, RoleName=role, PolicyName=name)
    for pol in (attempt("list attached", iam.list_attached_role_policies, RoleName=role) or {}).get("AttachedPolicies", []):
        attempt("detach", iam.detach_role_policy, RoleName=role, PolicyArn=pol["PolicyArn"])
    if delete:
        for ip in (attempt("list instance profiles", iam.list_instance_profiles_for_role, RoleName=role) or {}).get("InstanceProfiles", []):
            attempt("remove from profile", iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=role)
            attempt("delete profile", iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
        attempt("delete role", iam.delete_role, RoleName=role)
        log(f"IAM role deleted: {role}")


def iam_pre():
    for role in iam_roles():
        clean_role(role, delete=False)
    for arn in iam_policies():
        delete_policy(arn)


def iam_all():
    for role in iam_roles():
        clean_role(role, delete=True)
    for arn in iam_policies():
        delete_policy(arn)


# ----------------------------------------------------------------------------- S3

def s3_buckets():
    s3 = client("s3")
    out = []
    for b in s3.list_buckets().get("Buckets", []):
        n = b["Name"]
        if n.startswith("cl-base"):
            continue
        if name_match(n):
            out.append(n)
            continue
        t = attempt("bucket tagging", s3.get_bucket_tagging, Bucket=n)
        if t and tag_match(t.get("TagSet", [])):
            out.append(n)
    return out


def empty_bucket(bucket):
    s3 = client("s3")
    total = 0
    while True:
        entries = []
        for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
            entries += [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in page.get("Versions", [])]
            entries += [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in page.get("DeleteMarkers", [])]
        if not entries:
            for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
                entries += [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if not entries:
            break
        for i in range(0, len(entries), 500):
            resp = s3.delete_objects(Bucket=bucket, Delete={"Objects": entries[i:i + 500], "Quiet": True})
            if resp.get("Errors"):
                raise RuntimeError(f"cannot empty {bucket}: {resp['Errors'][:2]}")
        total += len(entries)
    for page in s3.get_paginator("list_multipart_uploads").paginate(Bucket=bucket):
        for u in page.get("Uploads", []):
            attempt("abort upload", s3.abort_multipart_upload, Bucket=bucket, Key=u["Key"], UploadId=u["UploadId"])
    return total


def s3_pre():
    for b in s3_buckets():
        n = attempt(f"empty {b}", empty_bucket, b)
        log(f"S3 bucket {b} emptied ({n or 0} version(s)/object(s))")


def s3_all():
    s3 = client("s3")
    for b in s3_buckets():
        attempt(f"empty {b}", empty_bucket, b)
        attempt(f"delete bucket {b}", s3.delete_bucket, Bucket=b)
        log(f"S3 bucket deleted: {b}")


# ----------------------------------------------------------------------------- compute / messaging

def scheduler_all():
    sch = client("scheduler")
    groups = ["default"]
    for g in (attempt("list schedule groups", sch.list_schedule_groups) or {}).get("ScheduleGroups", []):
        if name_match(g["Name"]):
            groups.append(g["Name"])
    for g in groups:
        res = attempt("list schedules", sch.list_schedules, GroupName=g) or {}
        for s in res.get("Schedules", []):
            if name_match(s["Name"]) or g != "default":
                attempt("delete schedule", sch.delete_schedule, Name=s["Name"], GroupName=g)
                log(f"schedule deleted: {g}/{s['Name']}")
        if g != "default":
            attempt("delete schedule group", sch.delete_schedule_group, Name=g)


def lambda_all():
    lam = client("lambda")
    fns = []
    for page in lam.get_paginator("list_functions").paginate():
        for f in page["Functions"]:
            if f["FunctionName"].startswith("cl-base"):
                continue
            if name_match(f["FunctionName"]):
                fns.append(f)
                continue
            t = attempt("list tags", lam.list_tags, Resource=f["FunctionArn"])
            if t and tag_match(t.get("Tags", {})):
                fns.append(f)
    names = {f["FunctionName"] for f in fns} | {f["FunctionArn"] for f in fns}
    for page in lam.get_paginator("list_event_source_mappings").paginate():
        for m in page["EventSourceMappings"]:
            fn = m.get("FunctionArn", "")
            if fn in names or fn.rsplit(":", 1)[-1] in names or name_match(m.get("EventSourceArn", "").rsplit(":", 1)[-1]):
                attempt("delete ESM", lam.delete_event_source_mapping, UUID=m["UUID"])
                log(f"event source mapping deleted: {m['UUID']}")
    for f in fns:
        attempt("delete function", lam.delete_function, FunctionName=f["FunctionName"])
        log(f"lambda deleted: {f['FunctionName']}")


def ecs_all():
    ecs = client("ecs")
    arns = []
    for page in ecs.get_paginator("list_clusters").paginate():
        arns += page["clusterArns"]
    for arn in arns:
        name = arn.rsplit("/", 1)[-1]
        if name.startswith("cl-base"):
            continue
        mine = name_match(name)
        if not mine:
            t = attempt("cluster tags", ecs.list_tags_for_resource, resourceArn=arn)
            mine = bool(t) and tag_match(t.get("tags", []))
        if not mine:
            continue
        services = []
        for page in ecs.get_paginator("list_services").paginate(cluster=arn):
            services += page["serviceArns"]
        for s in services:
            attempt("scale service", ecs.update_service, cluster=arn, service=s, desiredCount=0)
            attempt("delete service", ecs.delete_service, cluster=arn, service=s, force=True)
        tasks = []
        for page in ecs.get_paginator("list_tasks").paginate(cluster=arn):
            tasks += page["taskArns"]
        for t in tasks:
            attempt("stop task", ecs.stop_task, cluster=arn, task=t, reason="destroy")
        attempt("delete cluster", ecs.delete_cluster, cluster=arn)
        log(f"ECS cluster deleted: {name}")
    families = (attempt("families", ecs.list_task_definition_families, status="ALL") or {}).get("families", [])
    for fam in families:
        if not name_match(fam):
            continue
        tds = []
        for page in ecs.get_paginator("list_task_definitions").paginate(familyPrefix=fam):
            tds += page["taskDefinitionArns"]
        for td in tds:
            attempt("deregister task def", ecs.deregister_task_definition, taskDefinition=td)
        for i in range(0, len(tds), 10):
            attempt("delete task defs", ecs.delete_task_definitions, taskDefinitions=tds[i:i + 10])
        log(f"task definition family removed: {fam}")


def elb_all():
    elb = client("elbv2")
    for page in elb.get_paginator("describe_load_balancers").paginate():
        for lb in page["LoadBalancers"]:
            mine = name_match(lb["LoadBalancerName"])
            if not mine:
                t = attempt("lb tags", elb.describe_tags, ResourceArns=[lb["LoadBalancerArn"]])
                mine = bool(t) and any(tag_match(d.get("Tags", [])) for d in t.get("TagDescriptions", []))
            if not mine:
                continue
            for l in (attempt("listeners", elb.describe_listeners, LoadBalancerArn=lb["LoadBalancerArn"]) or {}).get("Listeners", []):
                attempt("delete listener", elb.delete_listener, ListenerArn=l["ListenerArn"])
            attempt("delete LB", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
            log(f"load balancer deleted: {lb['LoadBalancerName']}")
    for page in elb.get_paginator("describe_target_groups").paginate():
        for tg in page["TargetGroups"]:
            mine = name_match(tg["TargetGroupName"])
            if not mine:
                t = attempt("tg tags", elb.describe_tags, ResourceArns=[tg["TargetGroupArn"]])
                mine = bool(t) and any(tag_match(d.get("Tags", [])) for d in t.get("TagDescriptions", []))
            if mine:
                attempt("delete TG", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])
                log(f"target group deleted: {tg['TargetGroupName']}")


def rds_all():
    rds = client("rds")
    ids = []
    for page in rds.get_paginator("describe_db_instances").paginate():
        for d in page["DBInstances"]:
            if name_match(d["DBInstanceIdentifier"]) or tag_match(d.get("TagList", [])):
                ids.append(d["DBInstanceIdentifier"])
    for i in ids:
        attempt("delete db", rds.delete_db_instance, DBInstanceIdentifier=i, SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
        log(f"RDS instance deletion requested: {i}")
    def db_gone(i):
        try:
            return not rds.describe_db_instances(DBInstanceIdentifier=i).get("DBInstances")
        except ClientError as exc:
            return "NotFound" in exc.response.get("Error", {}).get("Code", "")

    for i in ids:
        wait_until(f"RDS {i} deletion", lambda i=i: db_gone(i), timeout=240)
    for page in rds.get_paginator("describe_db_snapshots").paginate(SnapshotType="manual"):
        for s in page["DBSnapshots"]:
            if name_match(s["DBSnapshotIdentifier"]):
                attempt("delete snapshot", rds.delete_db_snapshot, DBSnapshotIdentifier=s["DBSnapshotIdentifier"])
    for page in rds.get_paginator("describe_db_subnet_groups").paginate():
        for g in page["DBSubnetGroups"]:
            if name_match(g["DBSubnetGroupName"]):
                attempt("delete db subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
                log(f"DB subnet group deleted: {g['DBSubnetGroupName']}")


def elasticache_all():
    ec = client("elasticache")
    rgs = [g["ReplicationGroupId"] for g in (attempt("rgs", ec.describe_replication_groups) or {}).get("ReplicationGroups", [])
           if name_match(g["ReplicationGroupId"])]
    for g in rgs:
        attempt("delete RG", ec.delete_replication_group, ReplicationGroupId=g)
        log(f"ElastiCache replication group deletion requested: {g}")
    for c in (attempt("clusters", ec.describe_cache_clusters) or {}).get("CacheClusters", []):
        if name_match(c["CacheClusterId"]) and not c.get("ReplicationGroupId"):
            attempt("delete cache cluster", ec.delete_cache_cluster, CacheClusterId=c["CacheClusterId"])

    def gone():
        left_rg = [g for g in ec.describe_replication_groups()["ReplicationGroups"] if name_match(g["ReplicationGroupId"])]
        left_c = [c for c in ec.describe_cache_clusters()["CacheClusters"] if name_match(c["CacheClusterId"])]
        return not left_rg and not left_c
    wait_until("ElastiCache deletion", gone, timeout=240)
    for g in (attempt("subnet groups", ec.describe_cache_subnet_groups) or {}).get("CacheSubnetGroups", []):
        if name_match(g["CacheSubnetGroupName"]):
            attempt("delete cache subnet group", ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])
            log(f"cache subnet group deleted: {g['CacheSubnetGroupName']}")


def dynamodb_all():
    ddb = client("dynamodb")
    for page in ddb.get_paginator("list_tables").paginate():
        for t in page["TableNames"]:
            if t.startswith("cl-base"):
                continue
            mine = name_match(t)
            if not mine:
                d = attempt("describe table", ddb.describe_table, TableName=t)
                if d:
                    tags = attempt("table tags", ddb.list_tags_of_resource, ResourceArn=d["Table"]["TableArn"])
                    mine = bool(tags) and tag_match(tags.get("Tags", []))
            if mine:
                attempt("delete table", ddb.delete_table, TableName=t)
                log(f"DynamoDB table deleted: {t}")


def sqs_all():
    sqs = client("sqs")
    urls = (attempt("list queues", sqs.list_queues) or {}).get("QueueUrls", [])
    for u in urls:
        n = u.rsplit("/", 1)[-1]
        if n.startswith("cl-base"):
            continue
        mine = name_match(n)
        if not mine:
            t = attempt("queue tags", sqs.list_queue_tags, QueueUrl=u)
            mine = bool(t) and tag_match(t.get("Tags", {}))
        if mine:
            attempt("delete queue", sqs.delete_queue, QueueUrl=u)
            log(f"SQS queue deleted: {n}")


def cognito_all():
    idp = client("cognito-idp")
    for page in idp.get_paginator("list_user_pools").paginate(MaxResults=60):
        for p in page["UserPools"]:
            if p["Name"].startswith("cl-base"):
                continue
            mine = name_match(p["Name"])
            if not mine:
                d = attempt("describe pool", idp.describe_user_pool, UserPoolId=p["Id"])
                mine = bool(d) and tag_match(d["UserPool"].get("UserPoolTags", {}))
            if not mine:
                continue
            dom = (attempt("describe pool", idp.describe_user_pool, UserPoolId=p["Id"]) or {}).get("UserPool", {}).get("Domain")
            if dom:
                attempt("delete domain", idp.delete_user_pool_domain, Domain=dom, UserPoolId=p["Id"])
            attempt("delete pool", idp.delete_user_pool, UserPoolId=p["Id"])
            log(f"Cognito user pool deleted: {p['Name']}")


def kms_all():
    kms = client("kms")
    candidates = set()
    for page in kms.get_paginator("list_aliases").paginate():
        for a in page["Aliases"]:
            if a["AliasName"].startswith("alias/cl-base"):
                continue
            if a["AliasName"].startswith(f"alias/{PREFIX}-") or a["AliasName"] == f"alias/{PREFIX}":
                if a.get("TargetKeyId"):
                    candidates.add(a["TargetKeyId"])
                attempt("delete alias", kms.delete_alias, AliasName=a["AliasName"])
                log(f"KMS alias deleted: {a['AliasName']}")
    for page in kms.get_paginator("list_keys").paginate():
        for k in page["Keys"]:
            kid = k["KeyId"]
            d = attempt("describe key", kms.describe_key, KeyId=kid)
            if not d or d["KeyMetadata"]["KeyState"] in ("PendingDeletion", "PendingReplicaDeletion"):
                continue
            if d["KeyMetadata"].get("KeyManager") == "AWS":
                continue
            mine = kid in candidates
            if not mine:
                t = attempt("key tags", kms.list_resource_tags, KeyId=kid)
                mine = bool(t) and tag_match(t.get("Tags", []))
            if mine:
                attempt("schedule key deletion", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)
                log(f"KMS key scheduled for deletion: {kid}")


def logs_all():
    logs = client("logs")
    for page in logs.get_paginator("describe_log_groups").paginate():
        for g in page["logGroups"]:
            if loggroup_match(g["logGroupName"]):
                attempt("delete log group", logs.delete_log_group, logGroupName=g["logGroupName"])
                log(f"log group deleted: {g['logGroupName']}")


# ----------------------------------------------------------------------------- EC2

def ec2_all():
    ec2 = client("ec2")

    def mine_ec2(res, name_key="Tags"):
        tags = {t["Key"]: t["Value"] for t in res.get(name_key, [])}
        return tags.get(TAG) == PREFIX or name_match(tags.get("Name", ""))

    vpcs = [v["VpcId"] for v in ec2.describe_vpcs()["Vpcs"] if not v.get("IsDefault") and mine_ec2(v)]
    # ENIs first (left behind by ECS tasks / endpoints), then NAT gateways
    for vpc in vpcs:
        for n in ec2.describe_nat_gateways(Filter=[{"Name": "vpc-id", "Values": [vpc]}])["NatGateways"]:
            if n["State"] not in ("deleted", "deleting"):
                attempt("delete NAT", ec2.delete_nat_gateway, NatGatewayId=n["NatGatewayId"])
        for ep in ec2.describe_vpc_endpoints(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["VpcEndpoints"]:
            attempt("delete endpoint", ec2.delete_vpc_endpoints, VpcEndpointIds=[ep["VpcEndpointId"]])
        for eni in ec2.describe_network_interfaces(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NetworkInterfaces"]:
            att = eni.get("Attachment")
            if att:
                attempt("detach eni", ec2.detach_network_interface, AttachmentId=att["AttachmentId"], Force=True)
            attempt("delete eni", ec2.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"])
        sgs = [g for g in ec2.describe_security_groups(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["SecurityGroups"]]
        for g in sgs:  # drop cross references before deleting
            if g["IpPermissions"]:
                attempt("revoke ingress", ec2.revoke_security_group_ingress, GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
            if g["IpPermissionsEgress"]:
                attempt("revoke egress", ec2.revoke_security_group_egress, GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
        for g in sgs:
            if g["GroupName"] != "default":
                attempt("delete SG", ec2.delete_security_group, GroupId=g["GroupId"])
                log(f"security group deleted: {g['GroupName']}")
        for rt in ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["RouteTables"]:
            if any(a.get("Main") for a in rt["Associations"]):
                continue
            for a in rt["Associations"]:
                attempt("disassociate rtb", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            attempt("delete rtb", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        for s in ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["Subnets"]:
            attempt("delete subnet", ec2.delete_subnet, SubnetId=s["SubnetId"])
        for ig in ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}])["InternetGateways"]:
            attempt("detach igw", ec2.detach_internet_gateway, InternetGatewayId=ig["InternetGatewayId"], VpcId=vpc)
            attempt("delete igw", ec2.delete_internet_gateway, InternetGatewayId=ig["InternetGatewayId"])
        for acl in ec2.describe_network_acls(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NetworkAcls"]:
            if not acl.get("IsDefault"):
                attempt("delete acl", ec2.delete_network_acl, NetworkAclId=acl["NetworkAclId"])
        attempt("delete vpc", ec2.delete_vpc, VpcId=vpc)
        log(f"VPC deleted: {vpc}")
    # strays that carry the tag but live in a surviving (default) VPC
    for g in ec2.describe_security_groups()["SecurityGroups"]:
        if g["GroupName"] != "default" and (name_match(g["GroupName"]) or mine_ec2(g)):
            attempt("delete stray SG", ec2.delete_security_group, GroupId=g["GroupId"])
    for s in ec2.describe_subnets()["Subnets"]:
        if not s.get("DefaultForAz") and mine_ec2(s):
            attempt("delete stray subnet", ec2.delete_subnet, SubnetId=s["SubnetId"])
    for ig in ec2.describe_internet_gateways()["InternetGateways"]:
        if mine_ec2(ig):
            for a in ig.get("Attachments", []):
                attempt("detach igw", ec2.detach_internet_gateway, InternetGatewayId=ig["InternetGatewayId"], VpcId=a["VpcId"])
            attempt("delete stray igw", ec2.delete_internet_gateway, InternetGatewayId=ig["InternetGatewayId"])
    for rt in ec2.describe_route_tables()["RouteTables"]:
        if mine_ec2(rt) and not any(a.get("Main") for a in rt["Associations"]):
            for a in rt["Associations"]:
                attempt("disassociate rtb", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            attempt("delete stray rtb", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
    # leftovers of VPCs that no longer exist (default SG / main route table are not cascaded by every backend)
    live = {v["VpcId"] for v in ec2.describe_vpcs()["Vpcs"]}
    for g in ec2.describe_security_groups()["SecurityGroups"]:
        if g.get("VpcId") and g["VpcId"] not in live:
            attempt("delete orphan SG", ec2.delete_security_group, GroupId=g["GroupId"])
            log(f"orphaned security group deleted: {g['GroupId']}")
    for rt in ec2.describe_route_tables()["RouteTables"]:
        if rt.get("VpcId") and rt["VpcId"] not in live:
            attempt("delete orphan rtb", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
            log(f"orphaned route table deleted: {rt['RouteTableId']}")
    for a in ec2.describe_addresses()["Addresses"]:
        if mine_ec2(a):
            attempt("release eip", ec2.release_address, AllocationId=a["AllocationId"])


# ----------------------------------------------------------------------------- verify

def verify():
    left = []
    ec2 = client("ec2")
    left += [f"vpc {v['VpcId']}" for v in ec2.describe_vpcs()["Vpcs"] if not v.get("IsDefault") and any(
        t["Key"] == TAG and t["Value"] == PREFIX or (t["Key"] == "Name" and name_match(t["Value"])) for t in v.get("Tags", []))]
    left += [f"sg {g['GroupName']}" for g in ec2.describe_security_groups()["SecurityGroups"] if name_match(g["GroupName"])]
    left += [f"role {r}" for r in iam_roles()]
    left += [f"policy {p}" for p in iam_policies()]
    left += [f"bucket {b}" for b in s3_buckets()]
    left += [f"table {t}" for t in client("dynamodb").list_tables()["TableNames"] if name_match(t)]
    left += [f"queue {u}" for u in (client("sqs").list_queues().get("QueueUrls") or []) if name_match(u.rsplit("/", 1)[-1])]
    left += [f"lambda {f['FunctionName']}" for f in client("lambda").list_functions()["Functions"] if name_match(f["FunctionName"])]
    left += [f"schedule {s['Name']}" for s in client("scheduler").list_schedules().get("Schedules", []) if name_match(s["Name"])]
    left += [f"alias {a['AliasName']}" for a in client("kms").list_aliases()["Aliases"] if a["AliasName"].startswith(f"alias/{PREFIX}-")]
    for page in client("logs").get_paginator("describe_log_groups").paginate():
        left += [f"log group {g['logGroupName']}" for g in page["logGroups"] if loggroup_match(g["logGroupName"])]
    left += [f"cluster {a}" for a in client("ecs").list_clusters()["clusterArns"] if name_match(a.rsplit('/', 1)[-1])]
    left += [f"db {d['DBInstanceIdentifier']}" for d in client("rds").describe_db_instances()["DBInstances"] if name_match(d["DBInstanceIdentifier"])]
    left += [f"cache {g['ReplicationGroupId']}" for g in client("elasticache").describe_replication_groups()["ReplicationGroups"] if name_match(g["ReplicationGroupId"])]
    left += [f"lb {l['LoadBalancerName']}" for l in client("elbv2").describe_load_balancers()["LoadBalancers"] if name_match(l["LoadBalancerName"])]
    left += [f"pool {p['Name']}" for p in client("cognito-idp").list_user_pools(MaxResults=60)["UserPools"] if name_match(p["Name"])]
    return left


PHASES = [
    ("scheduler", scheduler_all), ("lambda", lambda_all), ("ecs", ecs_all), ("elb", elb_all),
    ("rds", rds_all), ("elasticache", elasticache_all), ("dynamodb", dynamodb_all), ("sqs", sqs_all),
    ("s3", s3_all), ("cognito", cognito_all), ("iam", iam_all), ("kms", kms_all), ("logs", logs_all),
    ("ec2", ec2_all),
]


def main():
    global CFG, PREFIX
    ap = argparse.ArgumentParser()
    ap.add_argument("step", choices=["pre", "all", "verify"])
    ap.add_argument("--config", default="/workspace/config/config.json")
    args = ap.parse_args()
    CFG = json.load(open(args.config))
    PREFIX = CFG["resource_prefix"]
    if len(PREFIX) < 4 or "cl-base".startswith(PREFIX):
        print("refusing to run with an unsafe resource_prefix", file=sys.stderr)
        sys.exit(2)
    if args.step == "pre":
        attempt("iam pre", iam_pre)
        attempt("s3 pre", s3_pre)
    elif args.step == "all":
        for name, fn in PHASES:
            attempt(f"phase {name}", fn)
        # second pass: dependencies that were still draining on the first pass
        for name in ("elb", "ec2", "kms", "logs", "iam"):
            attempt(f"phase {name} (2)", dict(PHASES)[name])
    else:
        left = verify()
        for item in left:
            print(f"[sweep] remaining: {item}")
        sys.exit(1 if left else 0)


if __name__ == "__main__":
    main()
