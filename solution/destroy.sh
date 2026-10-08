#!/usr/bin/env bash
set -euo pipefail

unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy
export PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export NO_PROXY="localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
export no_proxy="localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
export AWS_EC2_METADATA_DISABLED="true"

CONFIG_FILE="/workspace/config/config.json"
SUBMISSION_DIR="/workspace/submission"
INFRA_DIR="${SUBMISSION_DIR}/infra"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
TFVARS_FILE="${INFRA_DIR}/config.auto.tfvars.json"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing ${CONFIG_FILE}" >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
  IAC_BIN="tofu"
else
  echo "Neither terraform nor tofu is available" >&2
  exit 1
fi

export AWS_REGION="$(jq -r '.region' "${CONFIG_FILE}")"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_ENDPOINT_URL="$(jq -r '.aws_endpoint_url' "${CONFIG_FILE}")"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export TF_IN_AUTOMATION=1

cp "${CONFIG_FILE}" "${TFVARS_FILE}"

/opt/venv/bin/python3 - <<'PY'
import json
import boto3

with open("/workspace/config/config.json", encoding="utf-8") as f:
    cfg = json.load(f)

prefix = cfg["resource_prefix"]
kwargs = {
    "region_name": cfg["region"],
    "endpoint_url": cfg["aws_endpoint_url"],
    "aws_access_key_id": "test",
    "aws_secret_access_key": "test",
}
iam = boto3.client("iam", **kwargs)
for role in iam.list_roles().get("Roles", []):
    rname = role["RoleName"]
    if rname.startswith(prefix):
        for pname in iam.list_role_policies(RoleName=rname).get("PolicyNames", []):
            try:
                iam.delete_role_policy(RoleName=rname, PolicyName=pname)
            except Exception:
                pass
        for ap in iam.list_attached_role_policies(RoleName=rname).get("AttachedPolicies", []):
            try:
                iam.detach_role_policy(RoleName=rname, PolicyArn=ap["PolicyArn"])
            except Exception:
                pass

for pol in iam.list_policies(Scope="Local").get("Policies", []):
    if pol.get("PolicyName", "").startswith(prefix):
        parn = pol["Arn"]
        try:
            for ver in iam.list_policy_versions(PolicyArn=parn).get("Versions", []):
                if not ver.get("IsDefaultVersion"):
                    try:
                        iam.delete_policy_version(PolicyArn=parn, VersionId=ver["VersionId"])
                    except Exception:
                        pass
            iam.delete_policy(PolicyArn=parn)
        except Exception:
            pass

s3 = boto3.client("s3", **kwargs)
for b in s3.list_buckets().get("Buckets", []):
    bname = b["Name"]
    if bname.startswith(prefix):
        try:
            vers = s3.list_object_versions(Bucket=bname)
            for item in (vers.get("Versions") or []) + (vers.get("DeleteMarkers") or []):
                try:
                    s3.delete_object(Bucket=bname, Key=item["Key"], VersionId=item["VersionId"])
                except Exception:
                    pass
            objs = s3.list_objects_v2(Bucket=bname).get("Contents", [])
            for obj in objs:
                try:
                    s3.delete_object(Bucket=bname, Key=obj["Key"])
                except Exception:
                    pass
        except Exception:
            pass
PY

pushd "${INFRA_DIR}" >/dev/null

"${IAC_BIN}" init -input=false -no-color >/dev/null

"${IAC_BIN}" destroy \
  -input=false \
  -auto-approve \
  -no-color \
  -state="${STATE_FILE}"

remaining="$("${IAC_BIN}" state list -state="${STATE_FILE}" 2>/dev/null || true)"
if [[ -n "${remaining}" ]]; then
  echo "Managed resources remain in state after destroy:" >&2
  echo "${remaining}" >&2
  exit 1
fi

popd >/dev/null

/opt/venv/bin/python3 - <<'PY'
import json
import boto3

with open("/workspace/config/config.json", encoding="utf-8") as f:
    cfg = json.load(f)

prefix = cfg["resource_prefix"]
kwargs = {
    "region_name": cfg["region"],
    "endpoint_url": cfg["aws_endpoint_url"],
    "aws_access_key_id": "test",
    "aws_secret_access_key": "test",
}
sqs = boto3.client("sqs", **kwargs)
for qurl in sqs.list_queues().get("QueueUrls", []):
    qname = qurl.rsplit("/", 1)[-1]
    if qname.startswith(prefix):
        try:
            sqs.delete_queue(QueueUrl=qurl)
        except Exception:
            pass

ddb = boto3.client("dynamodb", **kwargs)
for tname in ddb.list_tables().get("TableNames", []):
    if tname.startswith(prefix):
        try:
            ddb.delete_table(TableName=tname)
        except Exception:
            pass

s3 = boto3.client("s3", **kwargs)
for b in s3.list_buckets().get("Buckets", []):
    bname = b["Name"]
    if bname.startswith(prefix):
        try:
            vers = s3.list_object_versions(Bucket=bname)
            for item in (vers.get("Versions") or []) + (vers.get("DeleteMarkers") or []):
                try:
                    s3.delete_object(Bucket=bname, Key=item["Key"], VersionId=item["VersionId"])
                except Exception:
                    pass
            objs = s3.list_objects_v2(Bucket=bname).get("Contents", [])
            for obj in objs:
                try:
                    s3.delete_object(Bucket=bname, Key=obj["Key"])
                except Exception:
                    pass
            s3.delete_bucket(Bucket=bname)
        except Exception:
            pass

logs = boto3.client("logs", **kwargs)
for lg in logs.describe_log_groups(logGroupNamePrefix=f"/clearledger/{prefix}").get("logGroups", []):
    try:
        logs.delete_log_group(logGroupName=lg["logGroupName"])
    except Exception:
        pass

scheduler = boto3.client("scheduler", **kwargs)
for sched in scheduler.list_schedules().get("Schedules", []):
    sname = sched.get("Name", "")
    if sname.startswith(prefix):
        try:
            scheduler.delete_schedule(Name=sname)
        except Exception:
            pass

kms = boto3.client("kms", **kwargs)
for al in kms.list_aliases().get("Aliases", []):
    aname = al.get("AliasName", "")
    if aname.startswith(f"alias/{prefix}"):
        try:
            kms.delete_alias(AliasName=aname)
        except Exception:
            pass

for kentry in kms.list_keys().get("Keys", []):
    kid = kentry.get("KeyId")
    if not kid:
        continue
    try:
        meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
        if meta.get("KeyManager") == "AWS" or meta.get("KeyState") in {"PendingDeletion", "PendingReplicaDeletion"}:
            continue
        tags = kms.list_resource_tags(KeyId=kid).get("Tags", [])
        if any(t.get("TagKey") == "ClearLedgerDeployment" and t.get("TagValue") == prefix for t in tags):
            kms.schedule_key_deletion(KeyId=kid, PendingWindowInDays=7)
    except Exception:
        pass

iam = boto3.client("iam", **kwargs)
for role in iam.list_roles().get("Roles", []):
    rname = role["RoleName"]
    if rname.startswith(prefix):
        for pname in iam.list_role_policies(RoleName=rname).get("PolicyNames", []):
            try:
                iam.delete_role_policy(RoleName=rname, PolicyName=pname)
            except Exception:
                pass
        for ap in iam.list_attached_role_policies(RoleName=rname).get("AttachedPolicies", []):
            try:
                iam.detach_role_policy(RoleName=rname, PolicyArn=ap["PolicyArn"])
            except Exception:
                pass
        try:
            iam.delete_role(RoleName=rname)
        except Exception:
            pass

for pol in iam.list_policies(Scope="Local").get("Policies", []):
    if pol.get("PolicyName", "").startswith(prefix):
        parn = pol["Arn"]
        try:
            for ver in iam.list_policy_versions(PolicyArn=parn).get("Versions", []):
                if not ver.get("IsDefaultVersion"):
                    try:
                        iam.delete_policy_version(PolicyArn=parn, VersionId=ver["VersionId"])
                    except Exception:
                        pass
            iam.delete_policy(PolicyArn=parn)
        except Exception:
            pass
PY

rm -f "${MANIFEST_FILE}"
echo "ClearLedger deployment destroyed"
