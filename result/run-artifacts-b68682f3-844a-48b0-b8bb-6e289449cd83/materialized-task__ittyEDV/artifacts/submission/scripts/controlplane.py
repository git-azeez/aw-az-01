#!/usr/bin/env python3
"""Control-plane drift repair that Terraform cannot express.

* Security group rules outside the canonical set are revoked.
* IAM roles keep only their canonical inline policy; stray inline policies and
  attached managed policies are removed and orphaned prefix-scoped customer
  managed policies are deleted.
"""
import sys

from botocore.exceptions import ClientError

from common import client, load_json, log

def flatten(perms, egress):
    """Split IpPermissions into one record per (range / group) source."""
    rules = []
    for p in perms:
        base = {"IsEgress": egress, "IpProtocol": p.get("IpProtocol"),
                "FromPort": p.get("FromPort"), "ToPort": p.get("ToPort")}
        for r in p.get("IpRanges", []):
            rules.append({**base, "CidrIpv4": r["CidrIp"]})
        for r in p.get("Ipv6Ranges", []):
            rules.append({**base, "CidrIpv6": r["CidrIpv6"]})
        for r in p.get("UserIdGroupPairs", []):
            rules.append({**base, "Ref": r["GroupId"]})
        for r in p.get("PrefixListIds", []):
            rules.append({**base, "PrefixList": r["PrefixListId"]})
        if not any(k in p for k in ("IpRanges", "Ipv6Ranges", "UserIdGroupPairs", "PrefixListIds")):
            rules.append(dict(base))
    return rules


def revoke(ec2, sg_id, rule):
    perm = {"IpProtocol": rule["IpProtocol"]}
    if rule.get("FromPort") is not None and rule["IpProtocol"] != "-1":
        perm["FromPort"] = rule["FromPort"]
        perm["ToPort"] = rule["ToPort"]
    if rule.get("CidrIpv4"):
        perm["IpRanges"] = [{"CidrIp": rule["CidrIpv4"]}]
    elif rule.get("CidrIpv6"):
        perm["Ipv6Ranges"] = [{"CidrIpv6": rule["CidrIpv6"]}]
    elif rule.get("Ref"):
        perm["UserIdGroupPairs"] = [{"GroupId": rule["Ref"]}]
    elif rule.get("PrefixList"):
        perm["PrefixListIds"] = [{"PrefixListId": rule["PrefixList"]}]
    fn = ec2.revoke_security_group_egress if rule["IsEgress"] else ec2.revoke_security_group_ingress
    fn(GroupId=sg_id, IpPermissions=[perm])
    log(f"revoked {'egress' if rule['IsEgress'] else 'ingress'} rule on {sg_id}: "
        f"{rule['IpProtocol']} {rule.get('FromPort')}-{rule.get('ToPort')} "
        f"{rule.get('CidrIpv4') or rule.get('CidrIpv6') or rule.get('Ref') or rule.get('PrefixList')}")


def converge_security_groups(cfg, mf):
    ec2 = client(cfg, "ec2")
    sgs = mf["network"]["security_group_ids"]
    vpc_id = mf["network"]["vpc_id"]
    vpc_cidr = ec2.describe_vpcs(VpcIds=[vpc_id])["Vpcs"][0]["CidrBlock"]

    def tcp(rule, port):
        return rule["IpProtocol"] == "tcp" and rule.get("FromPort") == port and rule.get("ToPort") == port

    def allowed(name, rule):
        egress = rule["IsEgress"]
        if name == "alb":
            if not egress:
                return tcp(rule, 80) and rule.get("CidrIpv4") == "0.0.0.0/0"
            return tcp(rule, 8080) and (rule.get("CidrIpv4") == vpc_cidr or rule.get("Ref") == sgs["ecs"])
        if name == "ecs":
            if not egress:
                return tcp(rule, 8080) and rule.get("Ref") == sgs["alb"]
            if tcp(rule, 5432) or tcp(rule, 6379):
                return rule.get("CidrIpv4") == vpc_cidr
            return (tcp(rule, 443) or tcp(rule, 4566)) and rule.get("CidrIpv4") == "0.0.0.0/0"
        if name in ("rds", "valkey"):
            port = 5432 if name == "rds" else 6379
            if egress:
                return False
            return tcp(rule, port) and (rule.get("Ref") == sgs["ecs"] or rule.get("CidrIpv4") == vpc_cidr)
        return True

    for name, sg_id in sgs.items():
        group = ec2.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
        rules = flatten(group.get("IpPermissions", []), False) + flatten(group.get("IpPermissionsEgress", []), True)
        for rule in rules:
            if not allowed(name, rule):
                try:
                    revoke(ec2, sg_id, rule)
                except ClientError as exc:
                    log(f"WARN: could not revoke rule on {name}: {exc}")


def converge_iam(cfg, mf):
    iam = client(cfg, "iam")
    prefix = cfg["resource_prefix"]
    roles = {
        "ecs_execution": mf["iam"]["ecs_execution_role_arn"],
        "ecs_task": mf["iam"]["ecs_task_role_arn"],
        "projector": mf["iam"]["projector_role_arn"],
        "relay": mf["iam"]["relay_role_arn"],
        "archiver": mf["iam"]["archiver_role_arn"],
        "scheduler": mf["iam"]["scheduler_role_arn"],
    }
    for key, arn in roles.items():
        role = arn.rsplit("/", 1)[-1]
        canonical = f"{prefix}-{key.replace('_', '-')}-policy"
        try:
            inline = iam.list_role_policies(RoleName=role)["PolicyNames"]
            attached = iam.list_attached_role_policies(RoleName=role)["AttachedPolicies"]
        except ClientError as exc:
            log(f"WARN: cannot inspect role {role}: {exc}")
            continue
        for name in inline:
            if name != canonical:
                iam.delete_role_policy(RoleName=role, PolicyName=name)
                log(f"removed out-of-band inline policy {name} from {role}")
        for pol in attached:
            iam.detach_role_policy(RoleName=role, PolicyArn=pol["PolicyArn"])
            log(f"detached managed policy {pol['PolicyArn']} from {role}")

    # Orphaned, prefix-scoped customer managed policies.
    paginator = iam.get_paginator("list_policies")
    for page in paginator.paginate(Scope="Local"):
        for pol in page["Policies"]:
            if not (pol["PolicyName"] == prefix or pol["PolicyName"].startswith(prefix + "-")):
                continue
            arn = pol["Arn"]
            try:
                entities = iam.list_entities_for_policy(PolicyArn=arn)
                if any(entities.get(k) for k in ("PolicyGroups", "PolicyUsers", "PolicyRoles")):
                    continue
                for ver in iam.list_policy_versions(PolicyArn=arn)["Versions"]:
                    if not ver["IsDefaultVersion"]:
                        iam.delete_policy_version(PolicyArn=arn, VersionId=ver["VersionId"])
                iam.delete_policy(PolicyArn=arn)
                log(f"deleted orphaned managed policy {arn}")
            except ClientError as exc:
                log(f"WARN: could not delete policy {arn}: {exc}")


def main():
    cfg = load_json(sys.argv[1])
    mf = load_json(sys.argv[2])
    converge_security_groups(cfg, mf)
    converge_iam(cfg, mf)
    log("control-plane backstop complete")


if __name__ == "__main__":
    main()
