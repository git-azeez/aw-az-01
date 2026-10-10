#!/usr/bin/env python3
"""Delete every resource scoped to the deployment prefix that is still around.

Scope = name carries the resource prefix (as a whole token) or the resource is
tagged ClearLedgerDeployment=<prefix>. Anything else - in particular the
cl-base-* baseline - is never touched.

Usage: sweep.py <config.json>      (exit 0: nothing left, 1: leftovers)
"""
import re
import sys
import time

from botocore.exceptions import ClientError

from common import client, load_json, log

CFG = load_json(sys.argv[1])
P = CFG["resource_prefix"]
TAG = "ClearLedgerDeployment"
TOKEN = re.compile(r"(?<![A-Za-z0-9])" + re.escape(P) + r"(?![A-Za-z0-9])")


def scoped(name):
    return bool(name) and bool(TOKEN.search(name))


def tagged(tags):
    """tags: list of {Key, Value} / {key, value} dicts or a plain dict"""
    if not tags:
        return False
    if isinstance(tags, dict):
        return tags.get(TAG) == P
    for t in tags:
        k = t.get("Key", t.get("key", t.get("TagKey")))
        v = t.get("Value", t.get("value", t.get("TagValue")))
        if k == TAG and v == P:
            return True
    return False


DELETED = 0


def attempt(desc, fn, *a, **kw):
    """Run fn; True when it succeeded or the resource is already gone."""
    global DELETED
    try:
        fn(*a, **kw)
        DELETED += 1
        log(f"deleted {desc}")
        return True
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("NotFound", "ResourceNotFoundException", "NoSuchEntity", "QueueDoesNotExist",
                    "AWS.SimpleQueueService.NonExistentQueue", "NoSuchBucket", "NotFoundException",
                    "DBInstanceNotFound", "DBInstanceNotFoundFault", "DBSubnetGroupNotFoundFault",
                    "ReplicationGroupNotFoundFault", "CacheClusterNotFound", "CacheSubnetGroupNotFoundFault",
                    "LoadBalancerNotFound", "TargetGroupNotFound", "ListenerNotFound",
                    "NotFoundException", "ClusterNotFoundException", "ServiceNotFoundException",
                    "InvalidVpcID.NotFound", "InvalidGroup.NotFound", "InvalidSubnetID.NotFound",
                    "InvalidRouteTableID.NotFound", "InvalidInternetGatewayID.NotFound",
                    "ResourceNotFoundFault", "ScheduleNotFound", "UserPoolNotFound"):
            return True
        log(f"could not delete {desc}: {code or exc}")
        return False
    except Exception as exc:  # noqa: BLE001
        log(f"could not delete {desc}: {exc}")
        return False


def paged(fn, key, **kw):
    out, token = [], None
    while True:
        args = dict(kw)
        if token:
            args["NextToken"] = token
        resp = fn(**args)
        out += resp.get(key, [])
        token = resp.get("NextToken")
        if not token:
            return out


# ------------------------------------------------------------------ scheduler
def sweep_scheduler():
    c = client(CFG, "scheduler")
    left = 0
    try:
        groups = [g["Name"] for g in paged(c.list_schedule_groups, "ScheduleGroups")]
    except ClientError:
        return 0
    for g in groups:
        for s in paged(c.list_schedules, "Schedules", GroupName=g):
            if scoped(s["Name"]):
                if not attempt(f"schedule {g}/{s['Name']}", c.delete_schedule, Name=s["Name"], GroupName=g):
                    left += 1
        if g != "default" and scoped(g):
            if not attempt(f"schedule group {g}", c.delete_schedule_group, Name=g):
                left += 1
    return left


# ---------------------------------------------------------------------- lambda
def sweep_lambda():
    c = client(CFG, "lambda")
    left = 0
    for m in c.list_event_source_mappings().get("EventSourceMappings", []):
        if scoped(m.get("FunctionArn", "")) or scoped(m.get("EventSourceArn", "")):
            if not attempt(f"event source mapping {m['UUID']}", c.delete_event_source_mapping, UUID=m["UUID"]):
                left += 1
    marker = None
    while True:
        resp = c.list_functions(**({"Marker": marker} if marker else {}))
        for f in resp.get("Functions", []):
            if scoped(f["FunctionName"]):
                if not attempt(f"lambda {f['FunctionName']}", c.delete_function, FunctionName=f["FunctionName"]):
                    left += 1
        marker = resp.get("NextMarker")
        if not marker:
            return left


# ------------------------------------------------------------------------- ecs
def sweep_ecs():
    c = client(CFG, "ecs")
    left = 0
    arns = paged(c.list_clusters, "clusterArns")
    for arn in arns:
        name = arn.rsplit("/", 1)[-1]
        try:
            desc = c.describe_clusters(clusters=[arn], include=["TAGS"])["clusters"][0]
        except (ClientError, IndexError):
            continue
        if not (scoped(name) or tagged(desc.get("tags"))):
            continue
        for svc in paged(c.list_services, "serviceArns", cluster=arn):
            attempt(f"ecs service {svc}", c.update_service, cluster=arn, service=svc, desiredCount=0)
            if not attempt(f"ecs service {svc}", c.delete_service, cluster=arn, service=svc, force=True):
                left += 1
        for task in paged(c.list_tasks, "taskArns", cluster=arn):
            attempt(f"ecs task {task}", c.stop_task, cluster=arn, task=task)
        if not attempt(f"ecs cluster {name}", c.delete_cluster, cluster=arn):
            left += 1
    # services of clusters that are not scoped but carry a scoped service are ignored on purpose
    fams = set()
    for status in ("ACTIVE", "INACTIVE"):
        for arn in paged(c.list_task_definitions, "taskDefinitionArns", status=status):
            fam = arn.rsplit("/", 1)[-1].rsplit(":", 1)[0]
            if scoped(fam):
                fams.add(fam)
                if status == "ACTIVE":
                    if not attempt(f"task definition {arn}", c.deregister_task_definition, taskDefinition=arn):
                        left += 1
    try:
        inactive = [a for a in paged(c.list_task_definitions, "taskDefinitionArns", status="INACTIVE")
                    if scoped(a.rsplit("/", 1)[-1])]
        for i in range(0, len(inactive), 10):
            c.delete_task_definitions(taskDefinitions=inactive[i:i + 10])
    except Exception:  # noqa: BLE001 - optional API
        pass
    return left


# ------------------------------------------------------------------------ elbv2
def sweep_elb():
    c = client(CFG, "elbv2")
    left = 0
    for lb in c.describe_load_balancers().get("LoadBalancers", []):
        if not scoped(lb["LoadBalancerName"]):
            continue
        for lis in c.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", []):
            attempt(f"listener {lis['ListenerArn']}", c.delete_listener, ListenerArn=lis["ListenerArn"])
        if not attempt(f"load balancer {lb['LoadBalancerName']}", c.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"]):
            left += 1
    for tg in c.describe_target_groups().get("TargetGroups", []):
        if scoped(tg["TargetGroupName"]):
            if not attempt(f"target group {tg['TargetGroupName']}", c.delete_target_group, TargetGroupArn=tg["TargetGroupArn"]):
                left += 1
    return left


# -------------------------------------------------------------------------- rds
def sweep_rds():
    c = client(CFG, "rds")
    left = 0
    for db in c.describe_db_instances().get("DBInstances", []):
        if scoped(db["DBInstanceIdentifier"]):
            try:
                c.modify_db_instance(DBInstanceIdentifier=db["DBInstanceIdentifier"], DeletionProtection=False, ApplyImmediately=True)
            except ClientError:
                pass
            if not attempt(f"db instance {db['DBInstanceIdentifier']}", c.delete_db_instance,
                           DBInstanceIdentifier=db["DBInstanceIdentifier"], SkipFinalSnapshot=True, DeleteAutomatedBackups=True):
                left += 1
    try:
        for snap in c.describe_db_snapshots().get("DBSnapshots", []):
            if scoped(snap["DBSnapshotIdentifier"]) or scoped(snap.get("DBInstanceIdentifier", "")):
                if snap.get("SnapshotType", "manual") == "manual":
                    attempt(f"db snapshot {snap['DBSnapshotIdentifier']}", c.delete_db_snapshot, DBSnapshotIdentifier=snap["DBSnapshotIdentifier"])
    except ClientError:
        pass
    # subnet groups can only go once the instances are gone
    if left == 0:
        for g in c.describe_db_subnet_groups().get("DBSubnetGroups", []):
            if scoped(g["DBSubnetGroupName"]):
                if not attempt(f"db subnet group {g['DBSubnetGroupName']}", c.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"]):
                    left += 1
    else:
        left += sum(1 for g in c.describe_db_subnet_groups().get("DBSubnetGroups", []) if scoped(g["DBSubnetGroupName"]))
    return left


# ------------------------------------------------------------------ elasticache
def sweep_elasticache():
    c = client(CFG, "elasticache")
    left = 0
    for rg in c.describe_replication_groups().get("ReplicationGroups", []):
        if scoped(rg["ReplicationGroupId"]):
            if not attempt(f"replication group {rg['ReplicationGroupId']}", c.delete_replication_group,
                           ReplicationGroupId=rg["ReplicationGroupId"], RetainPrimaryCluster=False):
                left += 1
    for cc in c.describe_cache_clusters().get("CacheClusters", []):
        if scoped(cc["CacheClusterId"]):
            if not attempt(f"cache cluster {cc['CacheClusterId']}", c.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"]):
                left += 1
    if left == 0:
        for g in c.describe_cache_subnet_groups().get("CacheSubnetGroups", []):
            if scoped(g["CacheSubnetGroupName"]):
                if not attempt(f"cache subnet group {g['CacheSubnetGroupName']}", c.delete_cache_subnet_group,
                               CacheSubnetGroupName=g["CacheSubnetGroupName"]):
                    left += 1
    else:
        left += sum(1 for g in c.describe_cache_subnet_groups().get("CacheSubnetGroups", []) if scoped(g["CacheSubnetGroupName"]))
    return left


# --------------------------------------------------------------------- dynamodb
def sweep_dynamodb():
    c = client(CFG, "dynamodb")
    left = 0
    names, start = [], None
    while True:
        resp = c.list_tables(**({"ExclusiveStartTableName": start} if start else {}))
        names += resp.get("TableNames", [])
        start = resp.get("LastEvaluatedTableName")
        if not start:
            break
    for name in names:
        if scoped(name):
            try:
                c.update_table(TableName=name, DeletionProtectionEnabled=False)
            except ClientError:
                pass
            if not attempt(f"dynamodb table {name}", c.delete_table, TableName=name):
                left += 1
    return left


# --------------------------------------------------------------------------- s3
def empty_and_delete_bucket(c, name):
    kwargs = {"Bucket": name}
    while True:
        page = c.list_object_versions(**kwargs)
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in page.get("Versions", [])]
        objs += [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in page.get("DeleteMarkers", [])]
        for i in range(0, len(objs), 500):
            c.delete_objects(Bucket=name, Delete={"Objects": objs[i:i + 500], "Quiet": True})
        if not page.get("IsTruncated"):
            break
        kwargs["KeyMarker"] = page.get("NextKeyMarker")
        if page.get("NextVersionIdMarker"):
            kwargs["VersionIdMarker"] = page["NextVersionIdMarker"]
    token = None
    while True:
        page = c.list_objects_v2(Bucket=name, **({"ContinuationToken": token} if token else {}))
        objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if objs:
            c.delete_objects(Bucket=name, Delete={"Objects": objs, "Quiet": True})
        token = page.get("NextContinuationToken")
        if not token:
            break
    try:
        c.delete_bucket_policy(Bucket=name)
    except ClientError:
        pass
    c.delete_bucket(Bucket=name)


def sweep_s3():
    c = client(CFG, "s3")
    left = 0
    for b in c.list_buckets().get("Buckets", []):
        name = b["Name"]
        hit = scoped(name)
        if not hit:
            try:
                hit = tagged(c.get_bucket_tagging(Bucket=name).get("TagSet"))
            except ClientError:
                hit = False
        if hit:
            if not attempt(f"s3 bucket {name}", empty_and_delete_bucket, c, name):
                left += 1
    return left


# -------------------------------------------------------------------------- sqs
def sweep_sqs():
    c = client(CFG, "sqs")
    left = 0
    urls = c.list_queues(QueueNamePrefix=P).get("QueueUrls", []) or []
    for u in c.list_queues().get("QueueUrls", []) or []:
        if u not in urls and scoped(u.rsplit("/", 1)[-1]):
            urls.append(u)
    for url in urls:
        if scoped(url.rsplit("/", 1)[-1]):
            if not attempt(f"sqs queue {url}", c.delete_queue, QueueUrl=url):
                left += 1
    return left


# ---------------------------------------------------------------------- cognito
def sweep_cognito():
    c = client(CFG, "cognito-idp")
    left = 0
    for pool in paged(c.list_user_pools, "UserPools", MaxResults=60):
        if scoped(pool["Name"]):
            try:
                detail = c.describe_user_pool(UserPoolId=pool["Id"])["UserPool"]
                if detail.get("Domain"):
                    c.delete_user_pool_domain(Domain=detail["Domain"], UserPoolId=pool["Id"])
                if detail.get("CustomDomain"):
                    c.delete_user_pool_domain(Domain=detail["CustomDomain"], UserPoolId=pool["Id"])
            except ClientError:
                pass
            if not attempt(f"user pool {pool['Name']}", c.delete_user_pool, UserPoolId=pool["Id"]):
                left += 1
    return left


# -------------------------------------------------------------------------- iam
def sweep_iam():
    c = client(CFG, "iam")
    left = 0
    for page in c.get_paginator("list_roles").paginate():
        for role in page["Roles"]:
            name = role["RoleName"]
            if not scoped(name):
                continue
            for pn in c.list_role_policies(RoleName=name)["PolicyNames"]:
                attempt(f"inline policy {name}/{pn}", c.delete_role_policy, RoleName=name, PolicyName=pn)
            for ap in c.list_attached_role_policies(RoleName=name)["AttachedPolicies"]:
                attempt(f"attachment {name}/{ap['PolicyArn']}", c.detach_role_policy, RoleName=name, PolicyArn=ap["PolicyArn"])
            for ip in c.list_instance_profiles_for_role(RoleName=name)["InstanceProfiles"]:
                attempt(f"instance profile membership {ip['InstanceProfileName']}", c.remove_role_from_instance_profile,
                        InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
            if not attempt(f"iam role {name}", c.delete_role, RoleName=name):
                left += 1
    for page in c.get_paginator("list_policies").paginate(Scope="Local"):
        for pol in page["Policies"]:
            if not scoped(pol["PolicyName"]):
                continue
            arn = pol["Arn"]
            ents = c.list_entities_for_policy(PolicyArn=arn)
            for r in ents.get("PolicyRoles", []):
                attempt(f"attachment {r['RoleName']}/{arn}", c.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
            for u in ents.get("PolicyUsers", []):
                attempt(f"attachment {u['UserName']}/{arn}", c.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
            for g in ents.get("PolicyGroups", []):
                attempt(f"attachment {g['GroupName']}/{arn}", c.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
            for ver in c.list_policy_versions(PolicyArn=arn)["Versions"]:
                if not ver["IsDefaultVersion"]:
                    attempt(f"policy version {arn}:{ver['VersionId']}", c.delete_policy_version, PolicyArn=arn, VersionId=ver["VersionId"])
            if not attempt(f"iam policy {arn}", c.delete_policy, PolicyArn=arn):
                left += 1
    for page in c.get_paginator("list_instance_profiles").paginate():
        for ip in page["InstanceProfiles"]:
            if scoped(ip["InstanceProfileName"]):
                attempt(f"instance profile {ip['InstanceProfileName']}", c.delete_instance_profile,
                        InstanceProfileName=ip["InstanceProfileName"])
    return left


# -------------------------------------------------------------------------- kms
def sweep_kms():
    c = client(CFG, "kms")
    left = 0
    key_ids = set()
    for page in c.get_paginator("list_aliases").paginate():
        for a in page["Aliases"]:
            if scoped(a["AliasName"].replace("alias/", "", 1)):
                if a.get("TargetKeyId"):
                    key_ids.add(a["TargetKeyId"])
                if not attempt(f"kms alias {a['AliasName']}", c.delete_alias, AliasName=a["AliasName"]):
                    left += 1
    for page in c.get_paginator("list_keys").paginate():
        for k in page["Keys"]:
            kid = k["KeyId"]
            try:
                meta = c.describe_key(KeyId=kid)["KeyMetadata"]
            except ClientError:
                continue
            if meta.get("KeyManager") == "AWS":
                continue
            if kid in key_ids or tagged(_key_tags(c, kid)):
                key_ids.add(kid)
    for kid in key_ids:
        try:
            state = c.describe_key(KeyId=kid)["KeyMetadata"]["KeyState"]
        except ClientError:
            continue
        if state in ("PendingDeletion", "PendingReplicaDeletion"):
            continue
        if not attempt(f"kms key {kid}", c.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7):
            left += 1
    return left


def _key_tags(c, kid):
    try:
        return c.list_resource_tags(KeyId=kid).get("Tags", [])
    except ClientError:
        return []


# ------------------------------------------------------------------------- logs
def sweep_logs():
    c = client(CFG, "logs")
    left = 0
    for page in c.get_paginator("describe_log_groups").paginate():
        for g in page["logGroups"]:
            if scoped(g["logGroupName"]):
                if not attempt(f"log group {g['logGroupName']}", c.delete_log_group, logGroupName=g["logGroupName"]):
                    left += 1
    return left


# -------------------------------------------------------------------------- ec2
def sweep_ec2():
    c = client(CFG, "ec2")
    left = 0
    tag_filter = [{"Name": f"tag:{TAG}", "Values": [P]}]

    vpcs = {}
    for v in c.describe_vpcs().get("Vpcs", []):
        if v.get("IsDefault"):
            continue
        name = next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), "")
        if scoped(name) or tagged(v.get("Tags")):
            vpcs[v["VpcId"]] = v

    def in_scope(obj_vpc, obj_tags, obj_name=""):
        return obj_vpc in vpcs or tagged(obj_tags) or scoped(obj_name)

    # network interfaces
    for eni in c.describe_network_interfaces().get("NetworkInterfaces", []):
        if eni["VpcId"] in vpcs or tagged(eni.get("TagSet")):
            att = eni.get("Attachment")
            if att and att.get("AttachmentId"):
                attempt(f"eni attachment {att['AttachmentId']}", c.detach_network_interface, AttachmentId=att["AttachmentId"], Force=True)
            if not attempt(f"network interface {eni['NetworkInterfaceId']}", c.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"]):
                left += 1

    # security groups: strip rules first so mutual references do not block deletion
    sgs = [g for g in c.describe_security_groups().get("SecurityGroups", [])
           if g["GroupName"] != "default" and in_scope(g["VpcId"], g.get("Tags"), g["GroupName"])]
    for g in sgs:
        for fn, perms, key in ((c.revoke_security_group_ingress, g.get("IpPermissions"), "ingress"),
                               (c.revoke_security_group_egress, g.get("IpPermissionsEgress"), "egress")):
            if perms:
                try:
                    fn(GroupId=g["GroupId"], IpPermissions=perms)
                except ClientError:
                    pass
    for g in sgs:
        if not attempt(f"security group {g['GroupName']} ({g['GroupId']})", c.delete_security_group, GroupId=g["GroupId"]):
            left += 1

    # route tables
    for rt in c.describe_route_tables().get("RouteTables", []):
        if rt["VpcId"] not in vpcs and not tagged(rt.get("Tags")):
            continue
        if any(a.get("Main") for a in rt.get("Associations", [])):
            continue
        for a in rt.get("Associations", []):
            attempt(f"route table association {a['RouteTableAssociationId']}", c.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
        if not attempt(f"route table {rt['RouteTableId']}", c.delete_route_table, RouteTableId=rt["RouteTableId"]):
            left += 1

    # subnets
    for sn in c.describe_subnets().get("Subnets", []):
        if sn["VpcId"] in vpcs or tagged(sn.get("Tags")):
            if not attempt(f"subnet {sn['SubnetId']}", c.delete_subnet, SubnetId=sn["SubnetId"]):
                left += 1

    # internet gateways
    for ig in c.describe_internet_gateways().get("InternetGateways", []):
        attached = [a["VpcId"] for a in ig.get("Attachments", [])]
        if any(v in vpcs for v in attached) or tagged(ig.get("Tags")):
            for v in attached:
                attempt(f"igw detach {ig['InternetGatewayId']}", c.detach_internet_gateway, InternetGatewayId=ig["InternetGatewayId"], VpcId=v)
            if not attempt(f"internet gateway {ig['InternetGatewayId']}", c.delete_internet_gateway, InternetGatewayId=ig["InternetGatewayId"]):
                left += 1

    # network ACLs (non-default)
    try:
        for acl in c.describe_network_acls().get("NetworkAcls", []):
            if acl["VpcId"] in vpcs and not acl.get("IsDefault"):
                attempt(f"network acl {acl['NetworkAclId']}", c.delete_network_acl, NetworkAclId=acl["NetworkAclId"])
    except ClientError:
        pass

    for vid in vpcs:
        if not attempt(f"vpc {vid}", c.delete_vpc, VpcId=vid):
            left += 1
    return left


STEPS = [
    ("scheduler", sweep_scheduler), ("lambda", sweep_lambda), ("ecs", sweep_ecs), ("elbv2", sweep_elb),
    ("rds", sweep_rds), ("elasticache", sweep_elasticache), ("dynamodb", sweep_dynamodb), ("s3", sweep_s3),
    ("sqs", sweep_sqs), ("cognito", sweep_cognito), ("iam", sweep_iam), ("kms", sweep_kms),
    ("logs", sweep_logs), ("ec2", sweep_ec2),
]


def main():
    global DELETED
    leftovers = {}
    for round_no in range(1, 9):
        leftovers = {}
        DELETED = 0
        for name, fn in STEPS:
            try:
                n = fn()
            except Exception as exc:  # noqa: BLE001
                log(f"{name}: sweep error: {exc}")
                n = 1
            if n:
                leftovers[name] = n
        if not leftovers and DELETED == 0:
            log(f"sweep round {round_no}: nothing left")
            return 0
        log(f"sweep round {round_no}: deleted {DELETED}, leftovers {leftovers}")
        time.sleep(3)
    log(f"ERROR: resources remain: {leftovers}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
