"""Out-of-band drift repair that Terraform cannot express (extra IAM policies, open security-group egress)
and verification of the projector event source mapping."""
import sys

from botocore.exceptions import ClientError

from common import Aws, ROLE_KEYS, load_config, load_manifest, log


def role_names(prefix):
    return [f"{prefix}-{k}" for k in ROLE_KEYS]


def clean_iam(aws, prefix):
    iam = aws.client("iam")
    changed = 0
    for role in role_names(prefix):
        canonical = f"{role}-canonical"
        try:
            names = []
            for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
                names += page["PolicyNames"]
            attached = []
            for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
                attached += page["AttachedPolicies"]
        except ClientError as exc:
            if exc.response["Error"]["Code"] in ("NoSuchEntity", "NoSuchEntityException"):
                continue
            raise
        for name in names:
            if name != canonical:
                log(f"iam: deleting out-of-band inline policy {name} from {role}")
                iam.delete_role_policy(RoleName=role, PolicyName=name)
                changed += 1
        for pol in attached:
            log(f"iam: detaching out-of-band policy {pol['PolicyArn']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=pol["PolicyArn"])
            changed += 1
    return changed


def _is_open(rule):
    for r in rule.get("IpRanges", []):
        if r.get("CidrIp") == "0.0.0.0/0":
            return True
    for r in rule.get("Ipv6Ranges", []):
        if r.get("CidrIpv6") == "::/0":
            return True
    return False


def clean_sg_egress(aws, manifest):
    ec2 = aws.client("ec2")
    changed = 0
    sgs = manifest["network"]["security_group_ids"]
    for name in ("alb", "rds", "valkey"):
        sg_id = sgs[name]
        try:
            groups = ec2.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"]
        except ClientError:
            continue
        for sg in groups:
            for rule in sg.get("IpPermissionsEgress", []):
                if _is_open(rule):
                    perm = {"IpProtocol": rule["IpProtocol"]}
                    if "FromPort" in rule:
                        perm["FromPort"] = rule["FromPort"]
                    if "ToPort" in rule:
                        perm["ToPort"] = rule["ToPort"]
                    perm["IpRanges"] = [r for r in rule.get("IpRanges", []) if r.get("CidrIp") == "0.0.0.0/0"]
                    perm["Ipv6Ranges"] = [r for r in rule.get("Ipv6Ranges", []) if r.get("CidrIpv6") == "::/0"]
                    perm = {k: v for k, v in perm.items() if v != []}
                    log(f"sg: revoking unrestricted egress {rule.get('IpProtocol')} on {name} ({sg_id})")
                    ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=[perm])
                    changed += 1
    return changed


def esm_ok(aws, manifest):
    """True when exactly one enabled projector mapping exists for the main queue and matches the manifest."""
    lam = aws.client("lambda")
    fn = manifest["workers"]["projector"]["function_name"]
    queue_arn = manifest["messaging"]["queue_arn"]
    try:
        mappings = lam.list_event_source_mappings(FunctionName=fn)["EventSourceMappings"]
    except ClientError:
        return False
    good = [
        m
        for m in mappings
        if m.get("EventSourceArn") == queue_arn
        and m.get("State") in ("Enabled", "Enabling")
        and m.get("BatchSize") == 5
        and "ReportBatchItemFailures" in (m.get("FunctionResponseTypes") or [])
    ]
    if len(good) != 1 or len(mappings) != 1:
        return False
    return good[0]["UUID"] == manifest["messaging"]["event_source_mapping_uuid"]


def prune_esm(aws, manifest):
    """Delete projector mappings that Terraform does not track (duplicates / stale queue bindings)."""
    lam = aws.client("lambda")
    fn = manifest["workers"]["projector"]["function_name"]
    keep = manifest["messaging"]["event_source_mapping_uuid"]
    removed = 0
    try:
        mappings = lam.list_event_source_mappings(FunctionName=fn)["EventSourceMappings"]
    except ClientError:
        return 0
    for m in mappings:
        if m["UUID"] != keep:
            log(f"esm: deleting untracked mapping {m['UUID']} ({m.get('EventSourceArn')})")
            try:
                lam.delete_event_source_mapping(UUID=m["UUID"])
                removed += 1
            except ClientError as exc:
                log(f"esm: delete failed: {exc}")
    return removed


def main():
    cmd = sys.argv[1]
    aws = Aws()
    cfg = load_config()
    if cmd == "iam":
        n = clean_iam(aws, cfg["resource_prefix"])
        log(f"iam: {n} out-of-band attachment(s)/policy(ies) removed")
    elif cmd == "sg":
        n = clean_sg_egress(aws, load_manifest())
        log(f"sg: {n} unrestricted egress rule(s) revoked")
    elif cmd == "esm-prune":
        prune_esm(aws, load_manifest())
    elif cmd == "esm":
        sys.exit(0 if esm_ok(aws, load_manifest()) else 3)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
