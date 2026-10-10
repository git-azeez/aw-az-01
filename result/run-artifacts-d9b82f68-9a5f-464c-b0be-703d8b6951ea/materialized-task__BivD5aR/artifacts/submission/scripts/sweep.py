#!/usr/bin/env python3
"""Prefix-scoped clean-up used by destroy.sh.

  pre    make Terraform's life easy: empty the versioned audit bucket, detach
         out-of-band IAM policies, delete unattached customer-managed policies
  post   remove anything scoped to <resource_prefix> (name prefix or the
         ClearLedgerDeployment tag) that Terraform did not or could not remove

Resources whose names start with anything other than "<resource_prefix>-" (for
example the cl-base-* baseline) are never touched.
"""
import argparse
import json
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

TAG = "ClearLedgerDeployment"


def log(msg):
    print(f"[sweep] {msg}", flush=True)


class Sweep:
    def __init__(self, config_path):
        with open(config_path) as fh:
            self.cfg = json.load(fh)
        self.prefix = self.cfg["resource_prefix"]
        self.region = self.cfg["region"]
        self.endpoint = self.cfg["aws_endpoint_url"]
        self.account = "000000000000"
        self._cfg = Config(retries={"max_attempts": 6, "mode": "standard"}, s3={"addressing_style": "path"})

    def c(self, svc):
        return boto3.client(
            svc,
            endpoint_url=self.endpoint,
            region_name=self.region,
            aws_access_key_id="test",
            aws_secret_access_key="test",
            config=self._cfg,
        )

    def mine(self, name):
        return bool(name) and (name == self.prefix or name.startswith(self.prefix + "-"))

    def tagged(self, tags):
        if isinstance(tags, dict):
            return tags.get(TAG) == self.prefix
        return any(t.get("Key") == TAG and t.get("Value") == self.prefix for t in tags or [])

    def attempt(self, what, fn, *a, **kw):
        try:
            return fn(*a, **kw)
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code in ("NoSuchEntity", "NoSuchBucket", "ResourceNotFoundException", "NotFound", "404",
                        "QueueDoesNotExist", "AWS.SimpleQueueService.NonExistentQueue", "ClusterNotFoundException",
                        "LoadBalancerNotFound", "TargetGroupNotFound", "CacheClusterNotFound",
                        "ReplicationGroupNotFoundFault", "DBInstanceNotFound", "NotFoundException",
                        "InvalidVpcID.NotFound", "ServiceNotFoundException"):
                return None
            log(f"{what}: {exc}")
        except Exception as exc:  # noqa: BLE001
            log(f"{what}: {exc}")
        return None

    # ------------------------------------------------------------------ IAM
    def iam_policies(self):
        iam = self.c("iam")
        for role in self.paged(iam, "list_roles", "Roles"):
            if self.mine(role["RoleName"]):
                self.clean_role(iam, role["RoleName"], keep_canonical=False)
        for pol in self.paged(iam, "list_policies", "Policies", Scope="Local"):
            if self.mine(pol["PolicyName"]) and pol.get("AttachmentCount", 0) == 0:
                self.attempt("delete policy", self.del_policy, iam, pol["Arn"])

    def clean_role(self, iam, role, keep_canonical):
        canonical = f"{role}-policy"
        for name in iam.list_role_policies(RoleName=role)["PolicyNames"]:
            if keep_canonical and name == canonical:
                continue
            self.attempt(f"delete inline {role}/{name}", iam.delete_role_policy, RoleName=role, PolicyName=name)
        for pol in iam.list_attached_role_policies(RoleName=role)["AttachedPolicies"]:
            self.attempt(f"detach {pol['PolicyArn']}", iam.detach_role_policy, RoleName=role, PolicyArn=pol["PolicyArn"])

    @staticmethod
    def del_policy(iam, arn):
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v["IsDefaultVersion"]:
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
        iam.delete_policy(PolicyArn=arn)

    def iam_roles(self):
        iam = self.c("iam")
        for role in self.paged(iam, "list_roles", "Roles"):
            name = role["RoleName"]
            if not self.mine(name):
                continue
            self.clean_role(iam, name, keep_canonical=False)
            for prof in iam.list_instance_profiles_for_role(RoleName=name).get("InstanceProfiles", []):
                self.attempt("remove profile", iam.remove_role_from_instance_profile,
                             InstanceProfileName=prof["InstanceProfileName"], RoleName=name)
            log(f"iam: deleting role {name}")
            self.attempt(f"delete role {name}", iam.delete_role, RoleName=name)
        for pol in self.paged(iam, "list_policies", "Policies", Scope="Local"):
            if self.mine(pol["PolicyName"]):
                for ent in iam.list_entities_for_policy(PolicyArn=pol["Arn"]).get("PolicyRoles", []):
                    self.attempt("detach", iam.detach_role_policy, RoleName=ent["RoleName"], PolicyArn=pol["Arn"])
                log(f"iam: deleting policy {pol['PolicyName']}")
                self.attempt("delete policy", self.del_policy, iam, pol["Arn"])

    @staticmethod
    def paged(client, op, key, **kw):
        out = []
        token = {}
        while True:
            resp = getattr(client, op)(**kw, **token)
            out.extend(resp.get(key, []))
            if resp.get("IsTruncated") and resp.get("Marker"):
                token = {"Marker": resp["Marker"]}
            elif resp.get("NextToken"):
                token = {"NextToken": resp["NextToken"]}
            else:
                return out

    # ------------------------------------------------------------------- S3
    def s3_buckets(self, delete):
        s3 = self.c("s3")
        for b in s3.list_buckets().get("Buckets", []):
            name = b["Name"]
            if not self.mine(name):
                continue
            self.attempt(f"empty bucket {name}", self.empty_bucket, s3, name)
            if delete:
                log(f"s3: deleting bucket {name}")
                self.attempt(f"delete bucket {name}", s3.delete_bucket, Bucket=name)

    @staticmethod
    def empty_bucket(s3, bucket):
        n = 0
        while True:
            resp = s3.list_object_versions(Bucket=bucket)
            victims = [{"Key": v["Key"], "VersionId": v["VersionId"]}
                       for v in resp.get("Versions", []) + resp.get("DeleteMarkers", [])]
            if not victims:
                break
            for i in range(0, len(victims), 500):
                s3.delete_objects(Bucket=bucket, Delete={"Objects": victims[i:i + 500], "Quiet": True})
            n += len(victims)
            if not resp.get("IsTruncated"):
                break
        # unversioned leftovers (if versioning was suspended)
        token = None
        while True:
            kw = {"Bucket": bucket}
            if token:
                kw["ContinuationToken"] = token
            resp = s3.list_objects_v2(**kw)
            objs = [{"Key": o["Key"]} for o in resp.get("Contents", [])]
            if objs:
                s3.delete_objects(Bucket=bucket, Delete={"Objects": objs, "Quiet": True})
                n += len(objs)
            if not resp.get("IsTruncated"):
                break
            token = resp.get("NextContinuationToken")
        if n:
            log(f"s3: removed {n} object versions/markers from {bucket}")

    # ------------------------------------------------------------------ rest
    def ecs(self):
        ecs = self.c("ecs")
        arns = ecs.list_clusters().get("clusterArns", [])
        for arn in arns:
            name = arn.rsplit("/", 1)[-1]
            if not self.mine(name):
                continue
            for svc in ecs.list_services(cluster=arn).get("serviceArns", []):
                log(f"ecs: deleting service {svc}")
                self.attempt("scale service", ecs.update_service, cluster=arn, service=svc, desiredCount=0)
                self.attempt("delete service", ecs.delete_service, cluster=arn, service=svc, force=True)
            for t in ecs.list_tasks(cluster=arn).get("taskArns", []):
                self.attempt("stop task", ecs.stop_task, cluster=arn, task=t)
            log(f"ecs: deleting cluster {name}")
            self.attempt("delete cluster", ecs.delete_cluster, cluster=arn)
        for fam in ecs.list_task_definition_families(status="ACTIVE").get("families", []):
            if self.mine(fam):
                for td in ecs.list_task_definitions(familyPrefix=fam, status="ACTIVE").get("taskDefinitionArns", []):
                    self.attempt("deregister td", ecs.deregister_task_definition, taskDefinition=td)
                    self.attempt("delete td", ecs.delete_task_definitions, taskDefinitions=[td])

    def elb(self):
        elb = self.c("elbv2")
        for lb in elb.describe_load_balancers().get("LoadBalancers", []):
            if self.mine(lb["LoadBalancerName"]):
                for ls in elb.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", []):
                    self.attempt("delete listener", elb.delete_listener, ListenerArn=ls["ListenerArn"])
                log(f"elbv2: deleting load balancer {lb['LoadBalancerName']}")
                self.attempt("delete lb", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
        time.sleep(1)
        for tg in elb.describe_target_groups().get("TargetGroups", []):
            if self.mine(tg["TargetGroupName"]):
                log(f"elbv2: deleting target group {tg['TargetGroupName']}")
                self.attempt("delete tg", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])

    def scheduler(self):
        sch = self.c("scheduler")
        groups = [g["Name"] for g in sch.list_schedule_groups().get("ScheduleGroups", [])] or ["default"]
        for g in groups:
            for s in sch.list_schedules(GroupName=g).get("Schedules", []):
                if self.mine(s["Name"]):
                    log(f"scheduler: deleting schedule {g}/{s['Name']}")
                    self.attempt("delete schedule", sch.delete_schedule, Name=s["Name"], GroupName=g)

    def lam(self):
        lam = self.c("lambda")
        for fn in lam.list_functions().get("Functions", []):
            name = fn["FunctionName"]
            if not self.mine(name):
                continue
            for esm in lam.list_event_source_mappings(FunctionName=name).get("EventSourceMappings", []):
                log(f"lambda: deleting event source mapping {esm['UUID']}")
                self.attempt("delete esm", lam.delete_event_source_mapping, UUID=esm["UUID"])
            log(f"lambda: deleting function {name}")
            self.attempt("delete function", lam.delete_function, FunctionName=name)
        # mappings whose function is gone but whose queue is ours
        for esm in lam.list_event_source_mappings().get("EventSourceMappings", []):
            if f":{self.prefix}-" in esm.get("EventSourceArn", "") or f":function:{self.prefix}-" in esm.get("FunctionArn", ""):
                self.attempt("delete esm", lam.delete_event_source_mapping, UUID=esm["UUID"])

    def sqs(self):
        sqs = self.c("sqs")
        for url in sqs.list_queues().get("QueueUrls", []) or []:
            if self.mine(url.rsplit("/", 1)[-1]):
                log(f"sqs: deleting queue {url}")
                self.attempt("delete queue", sqs.delete_queue, QueueUrl=url)

    def dynamodb(self):
        ddb = self.c("dynamodb")
        for t in ddb.list_tables().get("TableNames", []):
            if self.mine(t):
                log(f"dynamodb: deleting table {t}")
                self.attempt("delete table", ddb.delete_table, TableName=t)

    def elasticache(self):
        ec = self.c("elasticache")
        for rg in ec.describe_replication_groups().get("ReplicationGroups", []):
            if self.mine(rg["ReplicationGroupId"]):
                log(f"elasticache: deleting replication group {rg['ReplicationGroupId']}")
                self.attempt("delete rg", ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"])
        for cc in ec.describe_cache_clusters().get("CacheClusters", []):
            if self.mine(cc["CacheClusterId"]):
                self.attempt("delete cc", ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])
        self.wait(lambda: not [r for r in ec.describe_replication_groups().get("ReplicationGroups", [])
                               if self.mine(r["ReplicationGroupId"])], 120)
        for sg in ec.describe_cache_subnet_groups().get("CacheSubnetGroups", []):
            if self.mine(sg["CacheSubnetGroupName"]):
                log(f"elasticache: deleting subnet group {sg['CacheSubnetGroupName']}")
                self.attempt("delete csg", ec.delete_cache_subnet_group, CacheSubnetGroupName=sg["CacheSubnetGroupName"])

    def rds(self):
        rds = self.c("rds")
        for db in rds.describe_db_instances().get("DBInstances", []):
            if self.mine(db["DBInstanceIdentifier"]):
                log(f"rds: deleting instance {db['DBInstanceIdentifier']}")
                self.attempt("delete db", rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                             SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
        self.wait(lambda: not [d for d in rds.describe_db_instances().get("DBInstances", [])
                               if self.mine(d["DBInstanceIdentifier"])], 240)
        for sg in rds.describe_db_subnet_groups().get("DBSubnetGroups", []):
            if self.mine(sg["DBSubnetGroupName"]):
                log(f"rds: deleting subnet group {sg['DBSubnetGroupName']}")
                self.attempt("delete dbsg", rds.delete_db_subnet_group, DBSubnetGroupName=sg["DBSubnetGroupName"])

    def cognito(self):
        cg = self.c("cognito-idp")
        pools = []
        kw = {"MaxResults": 60}
        while True:
            resp = cg.list_user_pools(**kw)
            pools.extend(resp.get("UserPools", []))
            if not resp.get("NextToken"):
                break
            kw["NextToken"] = resp["NextToken"]
        for p in pools:
            if self.mine(p["Name"]):
                pid = p["Id"]
                d = self.attempt("describe pool", cg.describe_user_pool, UserPoolId=pid) or {}
                dom = d.get("UserPool", {}).get("Domain")
                if dom:
                    self.attempt("delete domain", cg.delete_user_pool_domain, Domain=dom, UserPoolId=pid)
                log(f"cognito: deleting user pool {p['Name']} ({pid})")
                self.attempt("delete pool", cg.delete_user_pool, UserPoolId=pid)

    def kms(self):
        kms = self.c("kms")
        aliases = kms.list_aliases().get("Aliases", [])
        for a in aliases:
            if a["AliasName"].startswith(f"alias/{self.prefix}-"):
                log(f"kms: deleting alias {a['AliasName']}")
                self.attempt("delete alias", kms.delete_alias, AliasName=a["AliasName"])
        marker = {}
        keys = []
        while True:
            resp = kms.list_keys(**marker)
            keys.extend(resp.get("Keys", []))
            if not resp.get("Truncated"):
                break
            marker = {"Marker": resp["NextMarker"]}
        for k in keys:
            kid = k["KeyId"]
            meta = self.attempt("describe key", kms.describe_key, KeyId=kid)
            if not meta or meta["KeyMetadata"].get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
                continue
            tags = self.attempt("list tags", kms.list_resource_tags, KeyId=kid) or {}
            if self.tagged(tags.get("Tags", [])) or any(
                    t.get("TagKey") == TAG and t.get("TagValue") == self.prefix for t in tags.get("Tags", [])):
                log(f"kms: scheduling deletion of key {kid}")
                self.attempt("schedule key deletion", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=10)

    def logs(self):
        logs = self.c("logs")
        token = {}
        groups = []
        while True:
            resp = logs.describe_log_groups(**token)
            groups.extend(resp.get("logGroups", []))
            if not resp.get("nextToken"):
                break
            token = {"nextToken": resp["nextToken"]}
        for g in groups:
            name = g["logGroupName"]
            if (f"/{self.prefix}/" in name or name.endswith(f"/{self.prefix}")
                    or f"/{self.prefix}-" in name or name.startswith(self.prefix)):
                log(f"logs: deleting log group {name}")
                self.attempt("delete log group", logs.delete_log_group, logGroupName=name)

    def ec2(self):
        ec2 = self.c("ec2")
        vpcs = []
        for v in ec2.describe_vpcs().get("Vpcs", []):
            if v.get("IsDefault"):
                continue
            tags = v.get("Tags", [])
            name = next((t["Value"] for t in tags if t["Key"] == "Name"), "")
            if self.tagged(tags) or self.mine(name):
                vpcs.append(v["VpcId"])
        # security groups outside VPC clean-up that are ours
        for vpc in vpcs:
            f = [{"Name": "vpc-id", "Values": [vpc]}]
            for eni in ec2.describe_network_interfaces(Filters=f).get("NetworkInterfaces", []):
                self.attempt("delete eni", ec2.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"])
            sgs = ec2.describe_security_groups(Filters=f).get("SecurityGroups", [])
            for sg in sgs:
                if sg["GroupName"] != "default":
                    if sg.get("IpPermissions"):
                        self.attempt("revoke ingress", ec2.revoke_security_group_ingress, GroupId=sg["GroupId"],
                                     IpPermissions=sg["IpPermissions"])
                    if sg.get("IpPermissionsEgress"):
                        self.attempt("revoke egress", ec2.revoke_security_group_egress, GroupId=sg["GroupId"],
                                     IpPermissions=sg["IpPermissionsEgress"])
            for sg in sgs:
                if sg["GroupName"] != "default":
                    log(f"ec2: deleting security group {sg['GroupName']}")
                    self.attempt("delete sg", ec2.delete_security_group, GroupId=sg["GroupId"])
            for sn in ec2.describe_subnets(Filters=f).get("Subnets", []):
                log(f"ec2: deleting subnet {sn['SubnetId']}")
                self.attempt("delete subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
            for rt in ec2.describe_route_tables(Filters=f).get("RouteTables", []):
                if any(a.get("Main") for a in rt.get("Associations", [])):
                    continue
                for a in rt.get("Associations", []):
                    self.attempt("disassociate", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
                log(f"ec2: deleting route table {rt['RouteTableId']}")
                self.attempt("delete rt", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
            for igw in ec2.describe_internet_gateways(
                    Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]).get("InternetGateways", []):
                self.attempt("detach igw", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
                log(f"ec2: deleting internet gateway {igw['InternetGatewayId']}")
                self.attempt("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
            log(f"ec2: deleting vpc {vpc}")
            self.attempt("delete vpc", ec2.delete_vpc, VpcId=vpc)
        # stray gateways / groups tagged for this deployment outside the vpcs above
        for igw in ec2.describe_internet_gateways().get("InternetGateways", []):
            if self.tagged(igw.get("Tags", [])) and not igw.get("Attachments"):
                self.attempt("delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])

    @staticmethod
    def wait(pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if pred():
                    return True
            except Exception:  # noqa: BLE001
                return True
            time.sleep(3)
        return False

    # ----------------------------------------------------------------- modes
    def pre(self):
        self.s3_buckets(delete=False)
        self.iam_policies()

    def post(self):
        steps = [
            ("scheduler", self.scheduler), ("lambda", self.lam), ("ecs", self.ecs), ("elb", self.elb),
            ("sqs", self.sqs), ("dynamodb", self.dynamodb), ("elasticache", self.elasticache), ("rds", self.rds),
            ("cognito", self.cognito), ("s3", lambda: self.s3_buckets(delete=True)), ("iam", self.iam_roles),
            ("logs", self.logs), ("ec2", self.ec2), ("kms", self.kms),
        ]
        for name, fn in steps:
            try:
                fn()
            except Exception as exc:  # noqa: BLE001
                log(f"{name}: sweep step failed: {exc}")
        # a second ec2 pass picks up dependencies released by earlier steps
        try:
            self.ec2()
        except Exception as exc:  # noqa: BLE001
            log(f"ec2: second pass failed: {exc}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["pre", "post"])
    ap.add_argument("--config", default="/workspace/config/config.json")
    args = ap.parse_args()
    sw = Sweep(args.config)
    getattr(sw, args.mode)()


if __name__ == "__main__":
    sys.exit(main())
