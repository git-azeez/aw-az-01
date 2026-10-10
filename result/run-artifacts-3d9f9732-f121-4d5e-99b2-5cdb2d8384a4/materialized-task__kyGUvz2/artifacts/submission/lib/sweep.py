"""Prefix-scoped cleanup of out-of-band resources around `terraform destroy`.

Everything here is scoped by the `<resource_prefix>` name prefix (or the ClearLedgerDeployment tag); baseline
`cl-base-*` resources and other deployments are never touched.

Usage: sweep.py pre|post
"""
import sys

from botocore.exceptions import ClientError

from common import Aws, ROLE_KEYS, load_config, log


def code(exc):
    return exc.response.get("Error", {}).get("Code", "")


def safe(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except ClientError as exc:
        log(f"  ignored {code(exc)} from {getattr(fn, '__name__', fn)}")
        return None


def is_ours(name, prefix):
    """Name belongs to this deployment: `<prefix>` followed by a separator (never another prefix like cl-8a24661)."""
    return name == prefix or name.startswith(prefix + "-") or name.startswith(prefix + "_") or name.startswith(prefix + "/")


# --------------------------------------------------------------------------- S3
def empty_bucket(s3, bucket):
    removed = 0
    while True:
        page = s3.list_object_versions(Bucket=bucket, MaxKeys=1000)
        batch = [(v["Key"], v["VersionId"]) for v in page.get("Versions", [])]
        batch += [(m["Key"], m["VersionId"]) for m in page.get("DeleteMarkers", [])]
        if not batch:
            break
        for key, vid in batch:
            s3.delete_object(Bucket=bucket, Key=key, VersionId=vid)
            removed += 1
    # plain (unversioned) leftovers
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=obj["Key"])
            removed += 1
    return removed


def sweep_s3(aws, prefix, delete_buckets):
    s3 = aws.client("s3")
    for b in s3.list_buckets().get("Buckets", []):
        name = b["Name"]
        if not is_ours(name, prefix):
            continue
        n = safe(empty_bucket, s3, name)
        log(f"s3: emptied {name} ({n} version(s)/object(s) removed)")
        if delete_buckets:
            safe(s3.delete_bucket, Bucket=name)


# --------------------------------------------------------------------------- IAM
def strip_role(iam, role, keep_inline=()):
    for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
        for name in page["PolicyNames"]:
            if name not in keep_inline:
                log(f"iam: deleting inline policy {name} from {role}")
                iam.delete_role_policy(RoleName=role, PolicyName=name)
    for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
        for pol in page["AttachedPolicies"]:
            log(f"iam: detaching {pol['PolicyArn']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=pol["PolicyArn"])


def delete_role(iam, role):
    strip_role(iam, role)
    for page in iam.get_paginator("list_instance_profiles_for_role").paginate(RoleName=role):
        for ip in page["InstanceProfiles"]:
            safe(iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=role)
    iam.delete_role(RoleName=role)
    log(f"iam: deleted role {role}")


def delete_policy(iam, arn):
    for kind in ("Role", "User", "Group"):
        pages = iam.get_paginator("list_entities_for_policy").paginate(PolicyArn=arn, EntityFilter=kind)
        for page in pages:
            for r in page.get("PolicyRoles", []):
                iam.detach_role_policy(RoleName=r["RoleName"], PolicyArn=arn)
            for u in page.get("PolicyUsers", []):
                iam.detach_user_policy(UserName=u["UserName"], PolicyArn=arn)
            for g in page.get("PolicyGroups", []):
                iam.detach_group_policy(GroupName=g["GroupName"], PolicyArn=arn)
    versions = iam.list_policy_versions(PolicyArn=arn).get("Versions", [])
    for v in versions:
        if not v.get("IsDefaultVersion"):
            iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
    iam.delete_policy(PolicyArn=arn)
    log(f"iam: deleted policy {arn}")


def sweep_iam_pre(aws, prefix):
    iam = aws.client("iam")
    for k in ROLE_KEYS:
        role = f"{prefix}-{k}"
        try:
            strip_role(iam, role, keep_inline=(f"{role}-canonical",))
        except ClientError as exc:
            if code(exc) not in ("NoSuchEntity", "NoSuchEntityException"):
                raise


def sweep_iam_post(aws, prefix):
    iam = aws.client("iam")
    for page in iam.get_paginator("list_roles").paginate():
        for r in page["Roles"]:
            if is_ours(r["RoleName"], prefix):
                safe(delete_role, iam, r["RoleName"])
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            if is_ours(p["PolicyName"], prefix):
                safe(delete_policy, iam, p["Arn"])
    for page in iam.get_paginator("list_instance_profiles").paginate():
        for ip in page["InstanceProfiles"]:
            if is_ours(ip["InstanceProfileName"], prefix):
                for r in ip.get("Roles", []):
                    safe(iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
                safe(iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])


# --------------------------------------------------------------------------- the rest
def sweep_lambda(aws, prefix):
    lam = aws.client("lambda")
    for page in lam.get_paginator("list_functions").paginate():
        for fn in page["Functions"]:
            if is_ours(fn["FunctionName"], prefix):
                for m in lam.list_event_source_mappings(FunctionName=fn["FunctionName"]).get("EventSourceMappings", []):
                    safe(lam.delete_event_source_mapping, UUID=m["UUID"])
                safe(lam.delete_function, FunctionName=fn["FunctionName"])
                log(f"lambda: deleted {fn['FunctionName']}")


def sweep_scheduler(aws, prefix):
    sch = aws.client("scheduler")
    for g in sch.list_schedule_groups().get("ScheduleGroups", []):
        for page in sch.get_paginator("list_schedules").paginate(GroupName=g["Name"]):
            for s in page["Schedules"]:
                if is_ours(s["Name"], prefix):
                    safe(sch.delete_schedule, Name=s["Name"], GroupName=g["Name"])
                    log(f"scheduler: deleted schedule {s['Name']}")
        if g["Name"] != "default" and is_ours(g["Name"], prefix):
            safe(sch.delete_schedule_group, Name=g["Name"])


def sweep_sqs(aws, prefix):
    sqs = aws.client("sqs")
    for url in sqs.list_queues(QueueNamePrefix=prefix).get("QueueUrls", []) or []:
        if is_ours(url.rsplit("/", 1)[-1], prefix):
            safe(sqs.delete_queue, QueueUrl=url)
            log(f"sqs: deleted {url}")


def sweep_dynamodb(aws, prefix):
    ddb = aws.client("dynamodb")
    for page in ddb.get_paginator("list_tables").paginate():
        for name in page["TableNames"]:
            if is_ours(name, prefix):
                safe(ddb.delete_table, TableName=name)
                log(f"dynamodb: deleted table {name}")


def sweep_logs(aws, prefix):
    logs = aws.client("logs")
    bases = [
        (f"/clearledger/{prefix}", True),
        # groups the control plane creates on its own for this deployment's workloads
        (f"/aws/lambda/{prefix}-", False),
        (f"/aws/ecs/{prefix}-", False),
        (f"/ecs/{prefix}-", False),
        (f"/aws/rds/instance/{prefix}-", False),
        (f"/aws/elasticache/cluster/{prefix}-", False),
    ]
    for base, exact_or_child in bases:
        for page in logs.get_paginator("describe_log_groups").paginate(logGroupNamePrefix=base):
            for g in page["logGroups"]:
                name = g["logGroupName"]
                if exact_or_child and not (name == base or name.startswith(base + "/")):
                    continue
                safe(logs.delete_log_group, logGroupName=name)
                log(f"logs: deleted {name}")


def sweep_cognito(aws, prefix):
    cog = aws.client("cognito-idp")
    for page in cog.get_paginator("list_user_pools").paginate(MaxResults=60):
        for pool in page["UserPools"]:
            if is_ours(pool["Name"], prefix):
                safe(cog.delete_user_pool, UserPoolId=pool["Id"])
                log(f"cognito: deleted pool {pool['Name']}")


def sweep_kms(aws, prefix):
    kms = aws.client("kms")
    alias_prefix = f"alias/{prefix}-"
    key_ids = set()
    for page in kms.get_paginator("list_aliases").paginate():
        for a in page["Aliases"]:
            if a["AliasName"].startswith(alias_prefix):
                if a.get("TargetKeyId"):
                    key_ids.add(a["TargetKeyId"])
                safe(kms.delete_alias, AliasName=a["AliasName"])
                log(f"kms: deleted alias {a['AliasName']}")
    for page in kms.get_paginator("list_keys").paginate():
        for k in page["Keys"]:
            kid = k["KeyId"]
            try:
                tags = kms.list_resource_tags(KeyId=kid).get("Tags", [])
            except ClientError:
                continue
            if any(t["TagKey"] == "ClearLedgerDeployment" and t["TagValue"] == prefix for t in tags):
                key_ids.add(kid)
    for kid in key_ids:
        try:
            meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
        except ClientError:
            continue
        if meta.get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
            continue
        safe(kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=10)
        log(f"kms: scheduled deletion of key {kid}")


def main():
    phase = sys.argv[1]
    cfg = load_config()
    prefix = cfg["resource_prefix"]
    if not prefix or len(prefix) < 4:
        raise SystemExit("refusing to sweep with an empty/short resource_prefix")
    aws = Aws(cfg)
    if phase == "pre":
        sweep_s3(aws, prefix, delete_buckets=False)
        sweep_iam_pre(aws, prefix)
    elif phase == "post":
        sweep_scheduler(aws, prefix)
        sweep_lambda(aws, prefix)
        sweep_sqs(aws, prefix)
        sweep_dynamodb(aws, prefix)
        sweep_s3(aws, prefix, delete_buckets=True)
        sweep_iam_post(aws, prefix)
        sweep_logs(aws, prefix)
        sweep_cognito(aws, prefix)
        sweep_kms(aws, prefix)
    else:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
