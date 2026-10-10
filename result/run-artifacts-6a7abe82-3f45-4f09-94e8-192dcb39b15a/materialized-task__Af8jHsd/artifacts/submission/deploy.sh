#!/usr/bin/env bash
# ClearLedger deployment / convergence script.
#  * terraform apply of ./infra (local state at ./infra/terraform.tfstate)
#  * PostgreSQL schema / constraints / triggers / indexes enforcement
#  * manifest.json export
#  * readiness wait on <service_url>/health/ready
#  * data-plane convergence (outbox, DynamoDB, S3 audit archive, Valkey)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_FILE="${SCRIPT_DIR}/manifest.json"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "${CONFIG_FILE}" ] || die "config file ${CONFIG_FILE} not found"
command -v jq >/dev/null || die "jq is required"

PREFIX="$(jq -r '.resource_prefix' "${CONFIG_FILE}")"
REGION="$(jq -r '.region // "us-east-1"' "${CONFIG_FILE}")"
ENDPOINT="$(jq -r '.aws_endpoint_url // "http://aws:4566"' "${CONFIG_FILE}")"
DB_NAME="$(jq -r '.db_name' "${CONFIG_FILE}")"
DB_USER="$(jq -r '.db_username' "${CONFIG_FILE}")"
DB_PASS="$(jq -r '.db_password' "${CONFIG_FILE}")"

export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1
export TF_INPUT=0
export CL_TFSTATE="${STATE_FILE}"

if command -v terraform >/dev/null 2>&1; then
  TF=terraform
elif command -v tofu >/dev/null 2>&1; then
  TF=tofu
else
  die "neither terraform nor tofu is installed"
fi

WORK="$(mktemp -d /tmp/clearledger-deploy.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

tf() { "${TF}" -chdir="${INFRA_DIR}" "$@"; }

# Filter Terraform output so secrets in plan diffs never reach the console.
tf_filter() {
  grep -E --line-buffered '(: (Creation|Modifications|Destruction) complete|: (Creating|Modifying|Destroying)\.\.\.|Apply complete|Destroy complete|Error|error|Warning: [A-Z]|No changes|Plan:)' \
    | grep -v -F "${DB_PASS}" || true
}

log "deployment ${PREFIX} (${REGION}) via ${TF} against ${ENDPOINT}"

# ---------------------------------------------------------------------------
# Embedded helper programs
# ---------------------------------------------------------------------------
cat >"${WORK}/prerepair.py" <<'__CLEARLEDGER_EOF__'
"""Pre-apply control-plane repairs that Terraform cannot express on its own.

* KMS keys of this deployment that were disabled or scheduled for deletion are
  restored in place (otherwise Terraform would replace them and re-key data).
* Out-of-band inline / managed IAM policies on the six ClearLedger roles are
  removed and unattached prefix-scoped customer managed policies are deleted.
Usage: prerepair.py <resource_prefix> <region>
"""
import os
import sys

import boto3
from botocore.config import Config

PREFIX = sys.argv[1]
REGION = sys.argv[2]
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://aws:4566")
CFG = Config(retries={"max_attempts": 5, "mode": "standard"})


def client(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION, config=CFG,
                        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
                        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"))


def log(msg):
    print(f"[pre-repair] {msg}", flush=True)


ROLE_SUFFIXES = ["ecs-execution", "ecs-task", "projector", "relay", "archiver", "scheduler"]


def repair_kms():
    kms = client("kms")
    key_ids = set()
    try:
        for page in kms.get_paginator("list_aliases").paginate():
            for a in page.get("Aliases", []):
                if a.get("AliasName", "").startswith(f"alias/{PREFIX}-") and a.get("TargetKeyId"):
                    key_ids.add(a["TargetKeyId"])
    except Exception as exc:  # noqa: BLE001
        log(f"list aliases failed: {exc}")
    try:
        for page in kms.get_paginator("list_keys").paginate():
            for k in page.get("Keys", []):
                kid = k["KeyId"]
                if kid in key_ids:
                    continue
                try:
                    tags = kms.list_resource_tags(KeyId=kid).get("Tags", [])
                except Exception:  # noqa: BLE001
                    continue
                if any(t.get("TagKey") == "ClearLedgerDeployment" and t.get("TagValue") == PREFIX for t in tags):
                    key_ids.add(kid)
    except Exception as exc:  # noqa: BLE001
        log(f"list keys failed: {exc}")
    # keys referenced by the Terraform state
    state_file = os.environ.get("CL_TFSTATE")
    if state_file and os.path.exists(state_file):
        try:
            import json
            st = json.load(open(state_file))
            for res in st.get("resources", []):
                if res.get("type") == "aws_kms_key" and res.get("mode") == "managed":
                    for inst in res.get("instances", []):
                        kid = inst.get("attributes", {}).get("id")
                        if kid:
                            key_ids.add(kid)
        except Exception as exc:  # noqa: BLE001
            log(f"state parse failed: {exc}")
    for kid in sorted(key_ids):
        try:
            meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
        except Exception as exc:  # noqa: BLE001
            log(f"describe {kid} failed: {exc}")
            continue
        state = meta.get("KeyState")
        if state == "PendingDeletion":
            log(f"cancelling scheduled deletion of KMS key {kid}")
            kms.cancel_key_deletion(KeyId=kid)
            state = kms.describe_key(KeyId=kid)["KeyMetadata"].get("KeyState")
        if state == "Disabled":
            log(f"re-enabling KMS key {kid}")
            kms.enable_key(KeyId=kid)
        try:
            if not kms.get_key_rotation_status(KeyId=kid).get("KeyRotationEnabled"):
                log(f"re-enabling rotation on KMS key {kid}")
                kms.enable_key_rotation(KeyId=kid)
        except Exception as exc:  # noqa: BLE001
            log(f"rotation check failed for {kid}: {exc}")


def repair_iam():
    iam = client("iam")
    for suffix in ROLE_SUFFIXES:
        role = f"{PREFIX}-{suffix}"
        canonical = f"{role}-policy"
        try:
            iam.get_role(RoleName=role)
        except iam.exceptions.NoSuchEntityException:
            continue
        except Exception as exc:  # noqa: BLE001
            log(f"get_role {role} failed: {exc}")
            continue
        try:
            for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
                for name in page.get("PolicyNames", []):
                    if name != canonical:
                        log(f"removing out-of-band inline policy {name} from {role}")
                        iam.delete_role_policy(RoleName=role, PolicyName=name)
        except Exception as exc:  # noqa: BLE001
            log(f"inline policy sweep on {role} failed: {exc}")
        try:
            for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
                for pol in page.get("AttachedPolicies", []):
                    log(f"detaching out-of-band managed policy {pol['PolicyArn']} from {role}")
                    iam.detach_role_policy(RoleName=role, PolicyArn=pol["PolicyArn"])
        except Exception as exc:  # noqa: BLE001
            log(f"managed policy sweep on {role} failed: {exc}")
    # unattached prefix-scoped customer managed policies
    try:
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            for pol in page.get("Policies", []):
                if not pol["PolicyName"].startswith(PREFIX):
                    continue
                arn = pol["Arn"]
                try:
                    attached = iam.get_policy(PolicyArn=arn)["Policy"].get("AttachmentCount", 0)
                except Exception:  # noqa: BLE001
                    attached = pol.get("AttachmentCount", 0)
                if attached:
                    log(f"leaving attached customer managed policy {arn} in place")
                    continue
                for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
                    if not v.get("IsDefaultVersion"):
                        iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
                log(f"deleting out-of-band customer managed policy {arn}")
                iam.delete_policy(PolicyArn=arn)
    except Exception as exc:  # noqa: BLE001
        log(f"customer managed policy sweep failed: {exc}")


def main():
    repair_kms()
    repair_iam()


if __name__ == "__main__":
    main()
__CLEARLEDGER_EOF__

cat >"${WORK}/manifest.py" <<'__CLEARLEDGER_EOF__'
"""Build /workspace/submission/manifest.json from the Terraform manifest output."""
import json
import os
import sys
import urllib.parse
import urllib.request

raw = json.load(open(sys.argv[1]))
manifest = raw.get("value", raw) if isinstance(raw, dict) and "value" in raw and "sensitive" in raw else raw

endpoint = os.environ.get("AWS_ENDPOINT_URL", "http://aws:4566")
endpoint_host = urllib.parse.urlparse(endpoint).hostname or "aws"
dns = manifest["ingress"]["alb_dns_name"]
candidates = [f"http://{dns}", f"http://{endpoint_host}:80"]


def alive(url):
    try:
        with urllib.request.urlopen(url + "/health/live", timeout=4) as r:
            return r.status < 500
    except urllib.error.HTTPError as e:
        return e.code < 500
    except Exception:  # noqa: BLE001
        return False


chosen = None
for c in candidates:
    if alive(c):
        chosen = c
        break
manifest["service_url"] = chosen or candidates[-1]

schema_path = "/workspace/contracts/schemas/manifest.schema.json"
if os.path.exists(schema_path):
    try:
        import jsonschema
        jsonschema.validate(manifest, json.load(open(schema_path)))
    except ImportError:
        pass

tmp = sys.argv[2] + ".tmp"
with open(tmp, "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=False)
    fh.write("\n")
os.replace(tmp, sys.argv[2])
print(f"[manifest] service_url={manifest['service_url']}")
__CLEARLEDGER_EOF__

cat >"${WORK}/functions.sql" <<'__CLEARLEDGER_EOF__'
-- ClearLedger canonical PL/pgSQL functions (idempotent: CREATE OR REPLACE)
CREATE SCHEMA IF NOT EXISTS clearledger;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(v jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND jsonb_typeof(v) = 'string'
     AND (v #>> '{}') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

CREATE OR REPLACE FUNCTION clearledger.is_trimmed_text(v jsonb, min_len integer, max_len integer) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND jsonb_typeof(v) = 'string'
     AND (v #>> '{}') = btrim(v #>> '{}')
     AND char_length(v #>> '{}') BETWEEN min_len AND max_len
$$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s
    WHEN 'INITIATED' THEN 0
    WHEN 'VALIDATED' THEN 1
    WHEN 'RESERVED' THEN 2
    WHEN 'CLEARED' THEN 3
    WHEN 'SETTLED' THEN 4
    WHEN 'RECONCILED' THEN 5
    ELSE NULL END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_valid_transition(old_status text, new_status text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF old_status IS NULL OR new_status IS NULL THEN
    RETURN false;
  END IF;
  IF new_status NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN
    RETURN false;
  END IF;
  IF old_status = 'RECONCILED' THEN
    RETURN false;
  END IF;
  IF old_status = 'DISPUTED' THEN
    RETURN new_status IN ('DISPUTED', 'RECONCILED');
  END IF;
  IF clearledger.status_rank(old_status) IS NULL THEN
    RETURN false;
  END IF;
  IF new_status = 'DISPUTED' THEN
    RETURN true;
  END IF;
  RETURN clearledger.status_rank(new_status) >= clearledger.status_rank(old_status);
END
$$;

-- Strict structural validation of a ClearLedgerDomainEventEnvelope
CREATE OR REPLACE FUNCTION clearledger.is_valid_envelope(p jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d jsonb;
  v integer;
  ts timestamptz;
  env_keys text[] := ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                           'aggregateVersion','occurredAt','correlationId','idempotencyKey','data'];
  data_keys text[] := ARRAY['kind','accountId','reference','debitParty','creditParty','entryId',
                            'status','clearingStage','memo'];
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  -- closed envelope: exactly the required keys
  IF NOT (ARRAY(SELECT jsonb_object_keys(p)) <@ env_keys) THEN RETURN false; END IF;
  IF NOT (p ?& env_keys) THEN RETURN false; END IF;

  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_text(p->'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string'
     OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_text(p->'aggregateId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number'
     OR (p->>'aggregateVersion') !~ '^[0-9]+$' THEN RETURN false; END IF;
  IF length(p->>'aggregateVersion') > 9 THEN RETURN false; END IF;
  v := (p->>'aggregateVersion')::integer;
  IF v < 1 THEN RETURN false; END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string'
     OR (p->>'occurredAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$'
  THEN RETURN false; END IF;
  BEGIN
    ts := (p->>'occurredAt')::timestamptz;
  EXCEPTION WHEN others THEN
    RETURN false;
  END;
  IF NOT clearledger.is_trimmed_text(p->'correlationId', 4, 128) THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(p->'idempotencyKey', 8, 128) THEN RETURN false; END IF;

  d := p->'data';
  IF d IS NULL OR jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  IF NOT (ARRAY(SELECT jsonb_object_keys(d)) <@ data_keys) THEN RETURN false; END IF;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'kind') <> 'string' OR d->>'kind' NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(d->'accountId', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(d->'reference', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(d->'debitParty', 2, 64) THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(d->'creditParty', 2, 64) THEN RETURN false; END IF;
  IF d->>'debitParty' = d->>'creditParty' THEN RETURN false; END IF;
  IF jsonb_typeof(d->'status') <> 'string'
     OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'clearingStage') <> 'string' THEN RETURN false; END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null'
     AND NOT clearledger.is_trimmed_text(d->'memo', 1, 256) THEN RETURN false; END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null'
     AND NOT clearledger.is_uuid_text(d->'entryId') THEN RETURN false; END IF;

  -- version / kind / status / entryId coupling
  IF v = 1 THEN
    IF p->>'eventType' <> 'SettlementInitiated' OR d->>'kind' <> 'settlementInitiated' THEN RETURN false; END IF;
    IF d->>'status' <> 'INITIATED' THEN RETURN false; END IF;
    IF d->>'clearingStage' IS DISTINCT FROM ('INITIATED@' || (d->>'debitParty')) THEN RETURN false; END IF;
    IF (d->>'memo') IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
    IF (d->>'entryId') IS NOT NULL THEN RETURN false; END IF;
  ELSE
    IF p->>'eventType' <> 'LedgerEntryRecorded' OR d->>'kind' <> 'ledgerEntryRecorded' THEN RETURN false; END IF;
    IF d->>'status' = 'INITIATED' THEN RETURN false; END IF;
    IF NOT clearledger.is_trimmed_text(d->'clearingStage', 2, 64) THEN RETURN false; END IF;
    IF (d->>'entryId') IS NULL THEN RETURN false; END IF;
  END IF;
  RETURN true;
END
$$;

-- Envelope validation plus column-to-envelope equality for clearledger.events
CREATE OR REPLACE FUNCTION clearledger.is_valid_event_row(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_event_type text,
  c_correlation_id text, c_idempotency_key text, c_occurred_at timestamptz) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.is_valid_envelope(p) THEN RETURN false; END IF;
  IF (p->>'eventId')::uuid IS DISTINCT FROM c_event_id THEN RETURN false; END IF;
  IF (p->>'aggregateId')::uuid IS DISTINCT FROM c_settlement_id THEN RETURN false; END IF;
  IF (p->>'aggregateVersion')::integer IS DISTINCT FROM c_version THEN RETURN false; END IF;
  IF p->>'eventType' IS DISTINCT FROM c_event_type THEN RETURN false; END IF;
  IF p->>'correlationId' IS DISTINCT FROM c_correlation_id THEN RETURN false; END IF;
  IF p->>'idempotencyKey' IS DISTINCT FROM c_idempotency_key THEN RETURN false; END IF;
  IF (p->>'occurredAt')::timestamptz IS DISTINCT FROM c_occurred_at THEN RETURN false; END IF;
  RETURN true;
END
$$;

-- Envelope validation plus column-to-envelope equality for clearledger.outbox
CREATE OR REPLACE FUNCTION clearledger.is_valid_outbox_row(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation_id text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.is_valid_envelope(p) THEN RETURN false; END IF;
  IF (p->>'eventId')::uuid IS DISTINCT FROM c_event_id THEN RETURN false; END IF;
  IF (p->>'aggregateId')::uuid IS DISTINCT FROM c_settlement_id THEN RETURN false; END IF;
  IF (p->>'aggregateVersion')::integer IS DISTINCT FROM c_version THEN RETURN false; END IF;
  IF p->>'correlationId' IS DISTINCT FROM c_correlation_id THEN RETURN false; END IF;
  RETURN true;
END
$$;

-- Closed-schema WriteAcceptedResponse validation for clearledger.idempotency_keys
CREATE OR REPLACE FUNCTION clearledger.is_valid_idempotency_row(
  c_scope text, c_status_code integer, r jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v integer;
BEGIN
  IF c_scope IS NULL OR c_scope !~ '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN false;
  END IF;
  IF r IS NULL OR jsonb_typeof(r) <> 'object' THEN RETURN false; END IF;
  IF NOT (ARRAY(SELECT jsonb_object_keys(r)) <@ ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF NOT (r ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_text(r->'settlementId') THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_text(r->'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(r->'version') <> 'number' OR (r->>'version') !~ '^[0-9]{1,9}$' THEN RETURN false; END IF;
  IF jsonb_typeof(r->'accepted') <> 'boolean' OR (r->'accepted') <> 'true'::jsonb THEN RETURN false; END IF;
  IF jsonb_typeof(r->'idempotentReplay') <> 'boolean' OR (r->'idempotentReplay') <> 'false'::jsonb THEN RETURN false; END IF;
  v := (r->>'version')::integer;
  IF split_part(c_scope, ':', 2) <> (r->>'settlementId') THEN RETURN false; END IF;
  IF split_part(c_scope, ':', 1) = 'create' THEN
    RETURN c_status_code = 201 AND v = 1;
  ELSE
    RETURN c_status_code = 202 AND v >= 2;
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'clearledger.%: % is not permitted (append-only ledger)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'P0001';
END
$$;

CREATE OR REPLACE FUNCTION clearledger.settlements_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.version IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'settlement must be initiated at version 1' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED (terminal)', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  NEW.last_memo := COALESCE(NEW.last_memo, OLD.last_memo);
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement version must advance by exactly 1 (% -> %)', OLD.version, NEW.version USING ERRCODE = 'P0001';
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement entry_count must advance by exactly 1' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.updated_at IS NULL OR NOT (NEW.updated_at > OLD.updated_at) THEN
    RAISE EXCEPTION 'settlement updated_at must strictly increase' USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.is_valid_transition(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'invalid settlement status transition % -> %', OLD.current_status, NEW.current_status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.events_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d jsonb;
  prev_max integer;
  prev_occurred timestamptz;
  prev_status text;
  expected_memo text;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'clearledger.events is append-only (% rejected)', TG_OP USING ERRCODE = 'P0001';
  END IF;

  IF NOT clearledger.is_valid_event_row(NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version,
        NEW.event_type, NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
    RAISE EXCEPTION 'event payload does not conform to ClearLedgerDomainEventEnvelope' USING ERRCODE = '23514';
  END IF;
  d := NEW.payload->'data';

  SELECT max(aggregate_version) INTO prev_max FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(prev_max, 0) + 1 THEN
    RAISE EXCEPTION 'event aggregate_version % is not contiguous (expected %)', NEW.aggregate_version, COALESCE(prev_max, 0) + 1
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.event_type = 'LedgerEntryRecorded' AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id
          AND e.event_type = 'LedgerEntryRecorded'
          AND (e.payload->'data'->>'entryId') = (d->>'entryId')) THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement', d->>'entryId' USING ERRCODE = '23505';
  END IF;

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  IF s.account_id IS DISTINCT FROM d->>'accountId'
     OR s.reference IS DISTINCT FROM d->>'reference'
     OR s.debit_party IS DISTINCT FROM d->>'debitParty'
     OR s.credit_party IS DISTINCT FROM d->>'creditParty'
     OR s.current_status IS DISTINCT FROM d->>'status'
     OR s.current_stage IS DISTINCT FROM d->>'clearingStage'
     OR s.last_entry_id IS DISTINCT FROM (d->>'entryId')::uuid
     OR s.version IS DISTINCT FROM NEW.aggregate_version
     OR s.updated_at IS DISTINCT FROM NEW.occurred_at THEN
    RAISE EXCEPTION 'event does not match settlement aggregate row' USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF s.created_at IS DISTINCT FROM NEW.occurred_at THEN
      RAISE EXCEPTION 'initiation event occurred_at must equal settlement created_at' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT e.occurred_at, e.payload->'data'->>'status' INTO prev_occurred, prev_status
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.aggregate_version = NEW.aggregate_version - 1;
    IF NOT (NEW.occurred_at > prev_occurred) THEN
      RAISE EXCEPTION 'event occurred_at must be strictly after the preceding event' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.is_valid_transition(prev_status, d->>'status') THEN
      RAISE EXCEPTION 'invalid event status transition % -> %', prev_status, d->>'status' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF (d->>'memo') IS NOT NULL THEN
    expected_memo := d->>'memo';
  ELSE
    SELECT e.payload->'data'->>'memo' INTO expected_memo
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id
       AND e.aggregate_version < NEW.aggregate_version
       AND (e.payload->'data'->>'memo') IS NOT NULL
     ORDER BY e.aggregate_version DESC
     LIMIT 1;
  END IF;
  IF s.last_memo IS DISTINCT FROM expected_memo THEN
    RAISE EXCEPTION 'settlement last_memo does not match event memo history' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  ev clearledger.events%ROWTYPE;
  prev_max integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted' USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT * INTO ev FROM clearledger.events WHERE event_id = NEW.event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'outbox event % does not exist in clearledger.events', NEW.event_id USING ERRCODE = '23503';
    END IF;
    IF ev.settlement_id IS DISTINCT FROM NEW.settlement_id
       OR ev.aggregate_version IS DISTINCT FROM NEW.aggregate_version
       OR ev.correlation_id IS DISTINCT FROM NEW.correlation_id
       OR ev.payload IS DISTINCT FROM NEW.payload THEN
      RAISE EXCEPTION 'outbox row must exactly mirror clearledger.events' USING ERRCODE = 'P0001';
    END IF;
    SELECT max(aggregate_version) INTO prev_max FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version IS DISTINCT FROM COALESCE(prev_max, 0) + 1 THEN
      RAISE EXCEPTION 'outbox aggregate_version % is not contiguous', NEW.aggregate_version USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.seq IS DISTINCT FROM OLD.seq
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease' USING ERRCODE = 'P0001';
  END IF;

  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    -- publishing an unpublished row
    IF NOT (NEW.attempts > OLD.attempts) THEN
      RAISE EXCEPTION 'publishing an outbox row must increment attempts' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'an outbox row cannot be archived while being published' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox delivery columns are immutable' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at cannot be rewritten without first being reset' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    -- operational replay reset
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'replay reset requires archived_at = NULL' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    -- still unpublished: failed delivery bookkeeping only
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'unpublished outbox rows cannot be archived' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  r jsonb;
  ev_ok boolean;
  ob_ok boolean;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'clearledger.idempotency_keys is immutable (% rejected)', TG_OP USING ERRCODE = 'P0001';
  END IF;
  r := NEW.response_body;
  IF NOT clearledger.is_valid_idempotency_row(NEW.scope, NEW.status_code, r) THEN
    RAISE EXCEPTION 'idempotency record does not conform to WriteAcceptedResponse' USING ERRCODE = '23514';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM clearledger.events e
     WHERE e.event_id = (r->>'eventId')::uuid
       AND e.settlement_id = (r->>'settlementId')::uuid
       AND e.aggregate_version = (r->>'version')::integer
       AND e.idempotency_key = NEW.idempotency_key) INTO ev_ok;
  IF NOT ev_ok THEN
    RAISE EXCEPTION 'idempotency record references an unknown event' USING ERRCODE = '23503';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM clearledger.outbox o
     WHERE o.event_id = (r->>'eventId')::uuid
       AND o.settlement_id = (r->>'settlementId')::uuid
       AND o.aggregate_version = (r->>'version')::integer) INTO ob_ok;
  IF NOT ob_ok THEN
    RAISE EXCEPTION 'idempotency record references an event missing from the outbox' USING ERRCODE = '23503';
  END IF;
  IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys k
              WHERE (k.response_body->>'eventId') = (r->>'eventId')
                 OR ((k.response_body->>'settlementId') = (r->>'settlementId')
                     AND (k.response_body->>'version') = (r->>'version'))) THEN
    RAISE EXCEPTION 'idempotency record duplicates an existing event response' USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END
$$;
__CLEARLEDGER_EOF__

cat >"${WORK}/schema.py" <<'__CLEARLEDGER_EOF__'
"""Idempotently create and enforce the ClearLedger PostgreSQL schema.

Usage: schema.py <functions.sql>
Connection parameters come from PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE.
"""
import os
import sys
import time

import psycopg2

FUNCTIONS_SQL = open(sys.argv[1]).read()

TABLES = {
    "settlements": """
        CREATE TABLE IF NOT EXISTS clearledger.settlements (
          settlement_id UUID NOT NULL,
          account_id TEXT NOT NULL,
          reference TEXT NOT NULL,
          debit_party TEXT NOT NULL,
          credit_party TEXT NOT NULL,
          current_status TEXT NOT NULL,
          current_stage TEXT NOT NULL,
          last_entry_id UUID NULL,
          last_memo TEXT NOT NULL,
          version INTEGER NOT NULL,
          entry_count INTEGER NOT NULL DEFAULT 0,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          CONSTRAINT settlements_pkey PRIMARY KEY (settlement_id)
        )""",
    "events": """
        CREATE TABLE IF NOT EXISTS clearledger.events (
          seq BIGSERIAL NOT NULL,
          event_id UUID NOT NULL,
          settlement_id UUID NOT NULL,
          aggregate_version INTEGER NOT NULL,
          event_type TEXT NOT NULL,
          correlation_id TEXT NOT NULL,
          idempotency_key TEXT NOT NULL,
          occurred_at TIMESTAMPTZ NOT NULL,
          payload JSONB NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          CONSTRAINT events_pkey PRIMARY KEY (seq)
        )""",
    "outbox": """
        CREATE TABLE IF NOT EXISTS clearledger.outbox (
          seq BIGSERIAL NOT NULL,
          event_id UUID NOT NULL,
          settlement_id UUID NOT NULL,
          aggregate_version INTEGER NOT NULL,
          correlation_id TEXT NOT NULL,
          payload JSONB NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          published_at TIMESTAMPTZ NULL,
          archived_at TIMESTAMPTZ NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT NULL,
          CONSTRAINT outbox_pkey PRIMARY KEY (seq)
        )""",
    "idempotency_keys": """
        CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
          scope TEXT NOT NULL,
          idempotency_key TEXT NOT NULL,
          request_hash TEXT NOT NULL,
          status_code INTEGER NOT NULL,
          response_body JSONB NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          CONSTRAINT idempotency_keys_pkey PRIMARY KEY (scope, idempotency_key)
        )""",
}

# (column, type, not_null, default)
COLUMNS = {
    "settlements": [
        ("settlement_id", "uuid", True, None),
        ("account_id", "text", True, None),
        ("reference", "text", True, None),
        ("debit_party", "text", True, None),
        ("credit_party", "text", True, None),
        ("current_status", "text", True, None),
        ("current_stage", "text", True, None),
        ("last_entry_id", "uuid", False, None),
        ("last_memo", "text", True, None),
        ("version", "integer", True, None),
        ("entry_count", "integer", True, "0"),
        ("created_at", "timestamp with time zone", True, "now()"),
        ("updated_at", "timestamp with time zone", True, "now()"),
    ],
    "events": [
        ("seq", "bigint", True, "SERIAL"),
        ("event_id", "uuid", True, None),
        ("settlement_id", "uuid", True, None),
        ("aggregate_version", "integer", True, None),
        ("event_type", "text", True, None),
        ("correlation_id", "text", True, None),
        ("idempotency_key", "text", True, None),
        ("occurred_at", "timestamp with time zone", True, None),
        ("payload", "jsonb", True, None),
        ("created_at", "timestamp with time zone", True, "now()"),
    ],
    "outbox": [
        ("seq", "bigint", True, "SERIAL"),
        ("event_id", "uuid", True, None),
        ("settlement_id", "uuid", True, None),
        ("aggregate_version", "integer", True, None),
        ("correlation_id", "text", True, None),
        ("payload", "jsonb", True, None),
        ("created_at", "timestamp with time zone", True, "now()"),
        ("published_at", "timestamp with time zone", False, None),
        ("archived_at", "timestamp with time zone", False, None),
        ("attempts", "integer", True, "0"),
        ("last_error", "text", False, None),
    ],
    "idempotency_keys": [
        ("scope", "text", True, None),
        ("idempotency_key", "text", True, None),
        ("request_hash", "text", True, None),
        ("status_code", "integer", True, None),
        ("response_body", "jsonb", True, None),
        ("created_at", "timestamp with time zone", True, "now()"),
    ],
}

STATUSES = "('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')"


def trimmed(col, lo, hi):
    return f"({col} = btrim({col}) AND char_length({col}) >= {lo} AND char_length({col}) <= {hi})"


# Canonical constraints: name -> (kind, definition used in ALTER TABLE ADD CONSTRAINT)
# kind: p (primary key), u (unique), c (check), f (foreign key)
CONSTRAINTS = {
    "settlements": [
        ("settlements_pkey", "p", "PRIMARY KEY (settlement_id)"),
        ("ck_settlements_account_id", "c", f"CHECK {trimmed('account_id', 3, 64)}"),
        ("ck_settlements_reference", "c", f"CHECK {trimmed('reference', 3, 64)}"),
        ("ck_settlements_debit_party", "c", f"CHECK {trimmed('debit_party', 2, 64)}"),
        ("ck_settlements_credit_party", "c", f"CHECK {trimmed('credit_party', 2, 64)}"),
        ("ck_settlements_parties_distinct", "c", "CHECK (debit_party <> credit_party)"),
        ("ck_settlements_status", "c", f"CHECK (current_status IN {STATUSES})"),
        ("ck_settlements_stage", "c",
         "CHECK (current_stage = btrim(current_stage) AND ("
         "(version = 1 AND current_stage = ('INITIATED@' || debit_party)) OR "
         "(version > 1 AND char_length(current_stage) >= 2 AND char_length(current_stage) <= 64)))"),
        ("ck_settlements_last_memo", "c",
         "CHECK (last_memo IS NOT NULL AND last_memo = btrim(last_memo) AND char_length(last_memo) >= 1 AND char_length(last_memo) <= 256)"),
        ("ck_settlements_version", "c", "CHECK (version >= 1)"),
        ("ck_settlements_entry_count", "c", "CHECK (entry_count >= 0 AND entry_count = version - 1)"),
        ("ck_settlements_initiation", "c",
         "CHECK (version <> 1 OR (entry_count = 0 AND current_status = 'INITIATED' "
         "AND current_stage = ('INITIATED@' || debit_party) AND last_entry_id IS NULL "
         "AND last_memo = 'Settlement initiated' AND updated_at = created_at))"),
        ("ck_settlements_progression", "c",
         "CHECK (version = 1 OR (entry_count = version - 1 AND current_status <> 'INITIATED' "
         "AND last_entry_id IS NOT NULL AND last_memo IS NOT NULL AND updated_at > created_at))"),
    ],
    "events": [
        ("events_pkey", "p", "PRIMARY KEY (seq)"),
        ("events_event_id_key", "u", "UNIQUE (event_id)"),
        ("events_settlement_version_key", "u", "UNIQUE (settlement_id, aggregate_version)"),
        ("events_settlement_idempotency_key", "u", "UNIQUE (settlement_id, idempotency_key)"),
        ("events_settlement_id_fkey", "f",
         "FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE"),
        ("ck_events_correlation_id", "c", f"CHECK {trimmed('correlation_id', 4, 128)}"),
        ("ck_events_idempotency_key", "c", f"CHECK {trimmed('idempotency_key', 8, 128)}"),
        ("ck_events_event_type", "c", "CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded'))"),
        ("ck_events_version", "c",
         "CHECK (aggregate_version >= 1 AND ((aggregate_version = 1 AND event_type = 'SettlementInitiated') "
         "OR (aggregate_version > 1 AND event_type = 'LedgerEntryRecorded')))"),
        ("ck_events_payload", "c",
         "CHECK (clearledger.is_valid_event_row(payload, event_id, settlement_id, aggregate_version, "
         "event_type, correlation_id, idempotency_key, occurred_at))"),
    ],
    "outbox": [
        ("outbox_pkey", "p", "PRIMARY KEY (seq)"),
        ("outbox_event_id_key", "u", "UNIQUE (event_id)"),
        ("outbox_settlement_version_key", "u", "UNIQUE (settlement_id, aggregate_version)"),
        ("outbox_event_id_fkey", "f",
         "FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE"),
        ("outbox_settlement_id_fkey", "f",
         "FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE"),
        ("outbox_event_version_fkey", "f",
         "FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE"),
        ("ck_outbox_correlation_id", "c", f"CHECK {trimmed('correlation_id', 4, 128)}"),
        ("ck_outbox_version", "c", "CHECK (aggregate_version >= 1)"),
        ("ck_outbox_payload", "c",
         "CHECK (clearledger.is_valid_outbox_row(payload, event_id, settlement_id, aggregate_version, correlation_id))"),
        ("ck_outbox_attempts", "c", "CHECK (attempts >= 0)"),
        ("ck_outbox_unattempted", "c", "CHECK (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))"),
        ("ck_outbox_published", "c",
         "CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))"),
        ("ck_outbox_last_error", "c",
         "CHECK (last_error IS NULL OR (published_at IS NULL AND attempts >= 1 "
         "AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))"),
        ("ck_outbox_archived", "c",
         "CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))"),
    ],
    "idempotency_keys": [
        ("idempotency_keys_pkey", "p", "PRIMARY KEY (scope, idempotency_key)"),
        ("ck_idempotency_scope", "c",
         "CHECK (scope ~ '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"),
        ("ck_idempotency_key", "c", f"CHECK {trimmed('idempotency_key', 8, 128)}"),
        ("ck_idempotency_request_hash", "c", "CHECK (request_hash ~ '^[0-9a-f]{64}$')"),
        ("ck_idempotency_status_code", "c",
         "CHECK ((status_code = 201 AND scope LIKE 'create:%') OR (status_code = 202 AND scope LIKE 'entry:%'))"),
        ("ck_idempotency_response_body", "c",
         "CHECK (clearledger.is_valid_idempotency_row(scope, status_code, response_body))"),
    ],
}

TRIGGERS = {
    "settlements": [
        ("trg_settlements_guard", "BEFORE INSERT OR UPDATE", "ROW", "clearledger.settlements_guard()"),
        ("trg_settlements_no_delete", "BEFORE DELETE", "ROW", "clearledger.reject_mutation()"),
        ("trg_settlements_no_truncate", "BEFORE TRUNCATE", "STATEMENT", "clearledger.reject_mutation()"),
    ],
    "events": [
        ("trg_events_guard", "BEFORE INSERT OR DELETE OR UPDATE", "ROW", "clearledger.events_guard()"),
        ("trg_events_no_truncate", "BEFORE TRUNCATE", "STATEMENT", "clearledger.reject_mutation()"),
    ],
    "outbox": [
        ("trg_outbox_guard", "BEFORE INSERT OR DELETE OR UPDATE", "ROW", "clearledger.outbox_guard()"),
        ("trg_outbox_no_truncate", "BEFORE TRUNCATE", "STATEMENT", "clearledger.reject_mutation()"),
    ],
    "idempotency_keys": [
        ("trg_idempotency_guard", "BEFORE INSERT OR DELETE OR UPDATE", "ROW", "clearledger.idempotency_guard()"),
        ("trg_idempotency_no_truncate", "BEFORE TRUNCATE", "STATEMENT", "clearledger.reject_mutation()"),
    ],
}

INDEXES = [
    ("idx_clearledger_outbox_unpublished",
     "CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox USING btree (seq) WHERE (published_at IS NULL)"),
    ("idx_clearledger_outbox_unarchived",
     "CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox USING btree (seq) WHERE ((published_at IS NOT NULL) AND (archived_at IS NULL))"),
    ("idx_clearledger_events_settlement_version",
     "CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events USING btree (settlement_id, aggregate_version)"),
    ("idx_clearledger_idempotency_event",
     "CREATE UNIQUE INDEX idx_clearledger_idempotency_event ON clearledger.idempotency_keys USING btree ((((response_body ->> 'eventId'::text))::uuid))"),
    ("idx_clearledger_idempotency_version",
     "CREATE UNIQUE INDEX idx_clearledger_idempotency_version ON clearledger.idempotency_keys USING btree ((((response_body ->> 'settlementId'::text))::uuid), (((response_body ->> 'version'::text))::integer))"),
    ("idx_clearledger_entry_id",
     "CREATE UNIQUE INDEX idx_clearledger_entry_id ON clearledger.events USING btree (settlement_id, ((((payload -> 'data'::text) ->> 'entryId'::text))::uuid)) WHERE (event_type = 'LedgerEntryRecorded'::text)"),
]


def log(msg):
    print(f"[schema] {msg}", flush=True)


def connect():
    deadline = time.time() + 300
    last = None
    while time.time() < deadline:
        try:
            conn = psycopg2.connect(connect_timeout=5)
            return conn
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(3)
    raise SystemExit(f"cannot connect to PostgreSQL: {last}")


def q(cur, sql, args=None):
    cur.execute(sql, args)
    try:
        return cur.fetchall()
    except psycopg2.ProgrammingError:
        return None


def ensure_columns(cur):
    for table, cols in COLUMNS.items():
        existing = {r[0]: r for r in q(cur, """
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid)
              FROM pg_attribute a
              LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
             WHERE a.attrelid = %s::regclass AND a.attnum > 0 AND NOT a.attisdropped""",
            (f"clearledger.{table}",))}
        for name, typ, notnull, default in cols:
            if name not in existing:
                coltype = "bigserial" if default == "SERIAL" else typ
                log(f"re-adding missing column {table}.{name}")
                cur.execute(f"ALTER TABLE clearledger.{table} ADD COLUMN {name} {coltype}"
                            + (f" DEFAULT {default}" if default and default != "SERIAL" else ""))
                existing[name] = (name, typ, False, None)
            _, curtype, curnn, curdef = existing[name]
            if curtype != typ:
                log(f"restoring column type {table}.{name}: {curtype} -> {typ}")
                cur.execute(f"ALTER TABLE clearledger.{table} ALTER COLUMN {name} TYPE {typ} USING {name}::{typ}")
            if default == "SERIAL":
                if not curdef or "nextval" not in curdef:
                    seq = f"clearledger.{table}_{name}_seq"
                    cur.execute(f"CREATE SEQUENCE IF NOT EXISTS {seq} OWNED BY clearledger.{table}.{name}")
                    cur.execute(f"SELECT setval('{seq}', GREATEST((SELECT COALESCE(max({name}), 0) FROM clearledger.{table}), 1))")
                    cur.execute(f"ALTER TABLE clearledger.{table} ALTER COLUMN {name} SET DEFAULT nextval('{seq}'::regclass)")
            elif default is not None:
                if (curdef or "").lower() != default:
                    cur.execute(f"ALTER TABLE clearledger.{table} ALTER COLUMN {name} SET DEFAULT {default}")
            elif curdef is not None:
                cur.execute(f"ALTER TABLE clearledger.{table} ALTER COLUMN {name} DROP DEFAULT")
            if notnull and not curnn:
                log(f"restoring NOT NULL on {table}.{name}")
                cur.execute(f"ALTER TABLE clearledger.{table} ALTER COLUMN {name} SET NOT NULL")
            if not notnull and curnn:
                log(f"dropping non-canonical NOT NULL on {table}.{name}")
                cur.execute(f"ALTER TABLE clearledger.{table} ALTER COLUMN {name} DROP NOT NULL")


def canonical_defs(cur, table):
    """Normalise canonical constraint definitions through PostgreSQL itself."""
    tmp = f"cl_canon_{table}"
    cur.execute(f"DROP TABLE IF EXISTS pg_temp.{tmp}")
    cur.execute(f"CREATE TEMP TABLE {tmp} (LIKE clearledger.{table} INCLUDING DEFAULTS) ON COMMIT DROP")
    expected = {}
    for name, kind, definition in CONSTRAINTS[table]:
        if kind == "f":
            continue
        cur.execute(f"ALTER TABLE pg_temp.{tmp} ADD CONSTRAINT {name} {definition}")
    for name, kind, ddef in q(cur, """
        SELECT conname, contype, pg_get_constraintdef(oid) FROM pg_constraint
         WHERE conrelid = %s::regclass""", (f"pg_temp.{tmp}",)):
        if kind == "n":
            continue
        expected[name] = (kind, ddef)
    for name, kind, definition in CONSTRAINTS[table]:
        if kind == "f":
            expected[name] = (kind, definition)
    return expected


def ensure_constraints(cur):
    expected = {t: canonical_defs(cur, t) for t in CONSTRAINTS}
    changed = False
    # pass 1: drop anything non-canonical (FKs first so dependent drops are safe)
    for kinds in (("f",), ("c",), ("u", "p", "x")):
        for table in CONSTRAINTS:
            actual = q(cur, """
                SELECT conname, contype, pg_get_constraintdef(oid) FROM pg_constraint
                 WHERE conrelid = %s::regclass AND contype IN %s""",
                (f"clearledger.{table}", kinds))
            for name, kind, ddef in actual:
                exp = expected[table].get(name)
                if exp and exp[0] == kind and exp[1] == ddef:
                    continue
                log(f"dropping non-canonical constraint {table}.{name}: {ddef}")
                cur.execute(f'ALTER TABLE clearledger.{table} DROP CONSTRAINT IF EXISTS "{name}" CASCADE')
                changed = True
    # pass 2: add any missing canonical constraint in dependency order
    for kinds in (("p",), ("u",), ("c",), ("f",)):
        for table, items in CONSTRAINTS.items():
            present = {r[0] for r in q(cur, "SELECT conname FROM pg_constraint WHERE conrelid = %s::regclass",
                                       (f"clearledger.{table}",))}
            for name, kind, definition in items:
                if kind in kinds and name not in present:
                    log(f"adding canonical constraint {table}.{name}")
                    cur.execute(f"ALTER TABLE clearledger.{table} ADD CONSTRAINT {name} {definition}")
                    changed = True
    # make sure every constraint is validated
    for table in CONSTRAINTS:
        for (name,) in q(cur, "SELECT conname FROM pg_constraint WHERE conrelid = %s::regclass AND NOT convalidated",
                         (f"clearledger.{table}",)):
            log(f"validating constraint {table}.{name}")
            cur.execute(f'ALTER TABLE clearledger.{table} VALIDATE CONSTRAINT "{name}"')
    return changed


def ensure_triggers(cur):
    for table, trigs in TRIGGERS.items():
        canonical = {}
        for name, timing, level, func in trigs:
            canonical[name] = (f"CREATE TRIGGER {name} {timing} ON clearledger.{table} "
                               f"FOR EACH {level} EXECUTE FUNCTION {func}")
        actual = {r[0]: (r[1], r[2]) for r in q(cur, """
            SELECT tgname, pg_get_triggerdef(oid), tgenabled FROM pg_trigger
             WHERE tgrelid = %s::regclass AND NOT tgisinternal""", (f"clearledger.{table}",))}
        for name in actual:
            if name not in canonical:
                log(f"dropping non-canonical trigger {table}.{name}")
                cur.execute(f'DROP TRIGGER IF EXISTS "{name}" ON clearledger.{table}')
        for name, ddl in canonical.items():
            cur_def = actual.get(name)
            if cur_def is None or cur_def[0] != ddl:
                log(f"(re)creating trigger {table}.{name}")
                cur.execute(ddl.replace("CREATE TRIGGER", "CREATE OR REPLACE TRIGGER", 1))
                cur_def = (ddl, "?")
            if cur_def[1] != "O":
                if cur_def[1] != "?":
                    log(f"enabling trigger {table}.{name}")
                cur.execute(f'ALTER TABLE clearledger.{table} ENABLE TRIGGER "{name}"')
        # internal (FK) triggers must be enabled as well
        disabled_internal = q(cur, """
            SELECT count(*) FROM pg_trigger WHERE tgrelid = %s::regclass AND tgisinternal AND tgenabled <> 'O'""",
            (f"clearledger.{table}",))[0][0]
        if disabled_internal:
            log(f"enabling internal triggers on {table}")
            cur.execute(f"ALTER TABLE clearledger.{table} ENABLE TRIGGER ALL")


def ensure_indexes(cur):
    canonical = dict(INDEXES)
    constraint_indexes = {r[0] for r in q(cur, """
        SELECT conindid::regclass::text FROM pg_constraint c
          JOIN pg_namespace n ON n.oid = c.connamespace
         WHERE n.nspname = 'clearledger' AND conindid <> 0""")}
    actual = {r[0]: (r[1], r[2]) for r in q(cur, """
        SELECT ic.relname, pg_get_indexdef(i.indexrelid), i.indisvalid AND i.indisready
          FROM pg_index i
          JOIN pg_class ic ON ic.oid = i.indexrelid
          JOIN pg_class tc ON tc.oid = i.indrelid
          JOIN pg_namespace n ON n.oid = tc.relnamespace
         WHERE n.nspname = 'clearledger'""")}
    for name, (ddef, valid) in actual.items():
        if name in canonical:
            if ddef != canonical[name] or not valid:
                log(f"rebuilding non-canonical index {name}")
                cur.execute(f'DROP INDEX IF EXISTS clearledger."{name}"')
        elif name not in constraint_indexes and f"clearledger.{name}" not in constraint_indexes:
            log(f"dropping non-canonical index {name}: {ddef}")
            cur.execute(f'DROP INDEX IF EXISTS clearledger."{name}"')
    present = {r[0] for r in q(cur, """
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'clearledger' AND c.relkind = 'i'""")}
    for name, ddl in INDEXES:
        if name not in present:
            log(f"creating index {name}")
            cur.execute(ddl)


def main():
    conn = connect()
    conn.autocommit = True
    cur = conn.cursor()
    dbname = q(cur, "SELECT current_database()")[0][0]
    user = q(cur, "SELECT current_user")[0][0]
    # Triggers must fire for ordinary sessions
    for stmt in (f'ALTER DATABASE "{dbname}" RESET session_replication_role',
                 f'ALTER ROLE "{user}" RESET session_replication_role',
                 f'ALTER ROLE "{user}" IN DATABASE "{dbname}" RESET session_replication_role'):
        try:
            cur.execute(stmt)
        except Exception as exc:  # noqa: BLE001
            log(f"note: {stmt}: {exc}")
    q(cur, "SELECT pg_advisory_lock(842017)")
    attempt = 0
    while True:
        attempt += 1
        try:
            conn.autocommit = False
            cur.execute("SET LOCAL lock_timeout = '20s'")
            cur.execute("SET LOCAL session_replication_role = 'origin'")
            cur.execute("SET LOCAL search_path = pg_catalog, public")
            cur.execute("CREATE SCHEMA IF NOT EXISTS clearledger")
            for ddl in TABLES.values():
                cur.execute(ddl)
            ensure_columns(cur)
            cur.execute(FUNCTIONS_SQL)
            ensure_constraints(cur)
            ensure_triggers(cur)
            ensure_indexes(cur)
            conn.commit()
            break
        except psycopg2.errors.LockNotAvailable as exc:
            conn.rollback()
            if attempt >= 8:
                raise
            log(f"lock timeout, retrying ({exc})")
            time.sleep(2)
        except psycopg2.errors.DeadlockDetected as exc:
            conn.rollback()
            if attempt >= 8:
                raise
            log(f"deadlock, retrying ({exc})")
            time.sleep(2)
    conn.autocommit = True
    q(cur, "SELECT pg_advisory_unlock(842017)")
    # report
    for table in TRIGGERS:
        n = q(cur, "SELECT count(*) FROM pg_trigger WHERE tgrelid = %s::regclass AND NOT tgisinternal AND tgenabled = 'O'",
              (f"clearledger.{table}",))[0][0]
        log(f"{table}: {n} enabled user triggers")
    log("schema converged")


if __name__ == "__main__":
    main()
__CLEARLEDGER_EOF__

cat >"${WORK}/posthygiene.py" <<'__CLEARLEDGER_EOF__'
"""Apply 14-day retention to runtime-created log groups of this deployment."""
import os
import sys

import boto3

PREFIX, REGION = sys.argv[1], sys.argv[2]
logs = boto3.client("logs", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"), region_name=REGION)
for page in logs.get_paginator("describe_log_groups").paginate():
    for g in page.get("logGroups", []):
        name = g["logGroupName"]
        if PREFIX in name and (g.get("retentionInDays") or 0) < 14:
            try:
                logs.put_retention_policy(logGroupName=name, retentionInDays=14)
                print(f"[hygiene] retention 14d on {name}")
            except Exception as exc:  # noqa: BLE001
                print(f"[hygiene] cannot set retention on {name}: {exc}")
__CLEARLEDGER_EOF__

cat >"${WORK}/reconcile.py" <<'__CLEARLEDGER_EOF__'
"""Converge ClearLedger derived data stores against PostgreSQL (system of record).

Usage: reconcile.py <manifest.json>
Environment: AWS_ENDPOINT_URL, PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE.
"""
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal

import boto3
import psycopg2
import psycopg2.extras
import redis
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.config import Config

MANIFEST = json.load(open(sys.argv[1]))
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://aws:4566")
REGION = MANIFEST["region"]
BOTO_CFG = Config(retries={"max_attempts": 6, "mode": "standard"}, read_timeout=180, connect_timeout=10)


def client(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION,
                        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
                        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
                        config=BOTO_CFG)


s3 = client("s3")
ddb = client("dynamodb")
sqs = client("sqs")
lam = client("lambda")

TABLE = MANIFEST["projections"]["table_name"]
BUCKET = MANIFEST["audit"]["bucket_name"]
PREFIX = MANIFEST["audit"]["prefix"]
QUEUE_URL = MANIFEST["messaging"]["queue_url"]
RELAY_FN = MANIFEST["workers"]["outbox_relay"]["function_name"]
ESM_UUID = MANIFEST["messaging"]["event_source_mapping_uuid"]
SERVICE_URL = MANIFEST["service_url"].rstrip("/")
AUDIT_BATCH = 100

ENV_KEYS = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId", "aggregateVersion",
            "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_KEYS = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId", "status",
             "clearingStage", "memo"]
KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")
CACHE_RE = re.compile(r"^clearledger:settlement:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")

deser = TypeDeserializer()
ser = TypeSerializer()


def log(msg):
    print(f"[reconcile] {msg}", flush=True)


def pg():
    deadline = time.time() + 120
    while True:
        try:
            return psycopg2.connect(connect_timeout=5)
        except Exception:  # noqa: BLE001
            if time.time() > deadline:
                raise
            time.sleep(3)


def canonical_envelope(payload):
    data = payload.get("data") or {}
    out = {k: payload[k] for k in ENV_KEYS if k in payload and k != "data"}
    out["data"] = {k: data[k] for k in DATA_KEYS if k in data and data[k] is not None}
    # keep canonical ordering (data is last in the envelope)
    ordered = {}
    for k in ENV_KEYS:
        if k in out:
            ordered[k] = out[k]
    return json.dumps(ordered, separators=(",", ":"), ensure_ascii=False)


def ts_projection(s):
    return s[:-1] + "+00:00" if s.endswith("Z") else s


def ts_api(s):
    return s[:-6] + "Z" if s.endswith("+00:00") else s


# ---------------------------------------------------------------------------
# 1. Outbox relay convergence
# ---------------------------------------------------------------------------
def unpublished_count(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
        return cur.fetchone()[0]


def direct_publish(conn):
    with conn.cursor() as cur:
        cur.execute("""SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NULL
                        ORDER BY seq LIMIT 500 FOR UPDATE SKIP LOCKED""")
        rows = cur.fetchall()
        for seq, payload in rows:
            sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=canonical_envelope(payload))
            cur.execute("""UPDATE clearledger.outbox
                              SET published_at = GREATEST(clock_timestamp(), created_at),
                                  attempts = attempts + 1, last_error = NULL
                            WHERE seq = %s AND published_at IS NULL""", (seq,))
    conn.commit()
    return len(rows)


def converge_outbox(conn):
    for _ in range(30):
        n = unpublished_count(conn)
        conn.commit()
        if n == 0:
            log("outbox: no unpublished rows")
            return
        log(f"outbox: {n} unpublished rows, invoking relay")
        progressed = False
        try:
            resp = lam.invoke(FunctionName=RELAY_FN, InvocationType="RequestResponse", Payload=b"{}")
            body = resp["Payload"].read()
            log(f"relay: {body[:300]!r}")
            n2 = unpublished_count(conn)
            conn.commit()
            progressed = n2 < n
        except Exception as exc:  # noqa: BLE001
            log(f"relay invoke failed: {exc}")
        if not progressed:
            moved = direct_publish(conn)
            log(f"outbox: published {moved} rows directly")
    log(f"outbox: {unpublished_count(conn)} rows still unpublished")
    conn.commit()


def ensure_esm_enabled():
    try:
        esm = lam.get_event_source_mapping(UUID=ESM_UUID)
        if esm.get("State") not in ("Enabled", "Enabling", "Updating", "Creating"):
            log(f"event source mapping state {esm.get('State')}, enabling")
            lam.update_event_source_mapping(UUID=ESM_UUID, Enabled=True)
    except Exception as exc:  # noqa: BLE001
        log(f"event source mapping check failed: {exc}")


def wait_queue_drain(timeout=120):
    deadline = time.time() + timeout
    zero_streak = 0
    while time.time() < deadline:
        try:
            attrs = sqs.get_queue_attributes(QueueUrl=QUEUE_URL, AttributeNames=[
                "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
                "ApproximateNumberOfMessagesDelayed"])["Attributes"]
            pending = sum(int(attrs.get(k, 0)) for k in attrs)
        except Exception as exc:  # noqa: BLE001
            log(f"queue attributes failed: {exc}")
            pending = -1
        if pending == 0:
            zero_streak += 1
            if zero_streak >= 2:
                log("queue drained")
                return True
        else:
            zero_streak = 0
        time.sleep(2)
    log("queue did not fully drain before timeout; continuing")
    return False


# ---------------------------------------------------------------------------
# 2. DynamoDB projection convergence
# ---------------------------------------------------------------------------
def load_ledger(conn, settlement_ids=None):
    with conn.cursor() as cur:
        if settlement_ids is None:
            cur.execute("""SELECT settlement_id::text, aggregate_version, payload FROM clearledger.events
                            ORDER BY settlement_id, aggregate_version""")
        else:
            cur.execute("""SELECT settlement_id::text, aggregate_version, payload FROM clearledger.events
                            WHERE settlement_id::text = ANY(%s) ORDER BY settlement_id, aggregate_version""",
                        (list(settlement_ids),))
        ledger = {}
        for sid, ver, payload in cur.fetchall():
            ledger.setdefault(sid, []).append((ver, payload))
        cur.execute("SELECT settlement_id::text FROM clearledger.settlements"
                    + ("" if settlement_ids is None else " WHERE settlement_id::text = ANY(%s)"),
                    None if settlement_ids is None else (list(settlement_ids),))
        settlements = {r[0] for r in cur.fetchall()}
    conn.commit()
    return settlements, ledger


def expected_items(sid, events):
    items = {}
    pk = f"SETTLEMENT#{sid}"
    last_memo = None
    static = {}
    for ver, p in events:
        d = p["data"]
        item = {
            "PK": pk,
            "SK": f"EVENT#{ver:08d}",
            "settlement_id": sid,
            "event_id": p["eventId"],
            "version": Decimal(ver),
            "event_type": p["eventType"],
            "status": d["status"],
            "clearing_stage": d["clearingStage"],
            "occurred_at": ts_projection(p["occurredAt"]),
            "correlation_id": p["correlationId"],
            "envelope": canonical_envelope(p),
        }
        if d.get("entryId") is not None:
            item["entry_id"] = d["entryId"]
        if d.get("memo") is not None:
            item["memo"] = d["memo"]
            last_memo = d["memo"]
        for k_src, k_dst in (("accountId", "account_id"), ("reference", "reference"),
                             ("debitParty", "debit_party"), ("creditParty", "credit_party")):
            if d.get(k_src) is not None and k_dst not in static:
                static[k_dst] = d[k_src]
        items[(pk, item["SK"])] = item
    if events:
        ver, p = events[-1]
        d = p["data"]
        state = {
            "PK": pk,
            "SK": "STATE",
            "GSI1PK": f"ACCOUNT#{static.get('account_id', d.get('accountId'))}",
            "GSI1SK": pk,
            "settlement_id": sid,
            "account_id": static.get("account_id", d.get("accountId")),
            "reference": static.get("reference", d.get("reference")),
            "debit_party": static.get("debit_party", d.get("debitParty")),
            "credit_party": static.get("credit_party", d.get("creditParty")),
            "status": d["status"],
            "clearing_stage": d["clearingStage"],
            "version": Decimal(ver),
            "entry_count": Decimal(ver - 1),
            "updated_at": ts_projection(p["occurredAt"]),
        }
        if d.get("entryId") is not None:
            state["last_entry_id"] = d["entryId"]
        if last_memo is not None:
            state["last_memo"] = last_memo
        items[(pk, "STATE")] = state
    return items


def scan_table():
    actual = {}
    kwargs = {"TableName": TABLE, "ConsistentRead": True}
    while True:
        resp = ddb.scan(**kwargs)
        for raw in resp.get("Items", []):
            item = {k: deser.deserialize(v) for k, v in raw.items()}
            actual[(item.get("PK"), item.get("SK"))] = (item, raw)
        if "LastEvaluatedKey" not in resp:
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return actual


def to_ddb(item):
    return {k: ser.serialize(v) for k, v in item.items()}


def raw_key(raw):
    return {"PK": raw["PK"], "SK": raw["SK"]}


def converge_dynamodb(conn):
    settlements, ledger = load_ledger(conn)
    expected = {}
    for sid in settlements:
        expected.update(expected_items(sid, ledger.get(sid, [])))
    actual = scan_table()

    # Re-check extras against fresh PostgreSQL state (live traffic may have advanced)
    extras = [k for k in actual if k not in expected]
    if extras:
        fresh_ids = set()
        for pk, _ in extras:
            if isinstance(pk, str) and pk.startswith("SETTLEMENT#"):
                fresh_ids.add(pk[len("SETTLEMENT#"):])
        if fresh_ids:
            fresh_settlements, fresh_ledger = load_ledger(conn, fresh_ids)
            for sid in fresh_settlements:
                expected.update(expected_items(sid, fresh_ledger.get(sid, [])))
    deleted = put = 0
    for key, (item, raw) in actual.items():
        if key in expected:
            continue
        if "PK" not in raw or "SK" not in raw:
            continue
        ddb.delete_item(TableName=TABLE, Key=raw_key(raw))
        deleted += 1
    for key, item in expected.items():
        cur = actual.get(key)
        if cur is not None and cur[0] == item:
            continue
        if key[1] == "STATE":
            try:
                ddb.put_item(TableName=TABLE, Item=to_ddb(item),
                             ConditionExpression="attribute_not_exists(PK) OR version <= :v",
                             ExpressionAttributeValues={":v": {"N": str(item["version"])}})
            except ddb.exceptions.ConditionalCheckFailedException:
                log(f"STATE for {key[0]} advanced concurrently; leaving newer projection")
                continue
        else:
            ddb.put_item(TableName=TABLE, Item=to_ddb(item))
        put += 1
    log(f"dynamodb: {len(expected)} expected items, {put} written, {deleted} stray items removed")
    return settlements


# ---------------------------------------------------------------------------
# 3. S3 audit archive convergence
# ---------------------------------------------------------------------------
def list_all_versions():
    versions, markers = [], []
    kwargs = {"Bucket": BUCKET}
    while True:
        resp = s3.list_object_versions(**kwargs)
        versions.extend(resp.get("Versions", []))
        markers.extend(resp.get("DeleteMarkers", []))
        if not resp.get("IsTruncated"):
            break
        kwargs["KeyMarker"] = resp.get("NextKeyMarker")
        if resp.get("NextVersionIdMarker"):
            kwargs["VersionIdMarker"] = resp["NextVersionIdMarker"]
        else:
            kwargs.pop("VersionIdMarker", None)
    return versions, markers


def delete_version(key, version_id):
    if version_id in (None, "null"):
        s3.delete_object(Bucket=BUCKET, Key=key, VersionId="null")
    else:
        s3.delete_object(Bucket=BUCKET, Key=key, VersionId=version_id)


def batch_bytes(rows):
    return "".join(canonical_envelope(p) + "\n" for _, p in rows).encode("utf-8")


def batch_key(rows, body):
    return f"{PREFIX}batch-{rows[0][0]:08d}-{rows[-1][0]:08d}-{hashlib.sha256(body).hexdigest()[:16]}.ndjson"


def converge_s3(conn):
    with conn.cursor() as cur:
        cur.execute("""SELECT seq, payload, published_at IS NOT NULL, archived_at IS NOT NULL
                         FROM clearledger.outbox ORDER BY seq""")
        rows = cur.fetchall()
    conn.commit()
    by_seq = {r[0]: r for r in rows}
    seqs = [r[0] for r in rows]

    versions, markers = list_all_versions()
    to_delete = [(m["Key"], m.get("VersionId")) for m in markers]
    current = []
    for v in versions:
        if not v.get("IsLatest"):
            to_delete.append((v["Key"], v.get("VersionId")))
        else:
            current.append(v)

    valid = []
    for v in current:
        key = v["Key"]
        m = KEY_RE.match(key)
        ok = False
        if m:
            first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
            in_range = [s for s in seqs if first <= s <= last]
            if first <= last and in_range and in_range[0] == first and in_range[-1] == last \
                    and all(by_seq[s][2] for s in in_range):
                try:
                    body = s3.get_object(Bucket=BUCKET, Key=key, VersionId=v["VersionId"])["Body"].read() \
                        if v.get("VersionId") not in (None, "null") else \
                        s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
                except Exception as exc:  # noqa: BLE001
                    log(f"s3: cannot read {key}: {exc}")
                    body = None
                if body is not None and hashlib.sha256(body).hexdigest()[:16] == digest \
                        and body == batch_bytes([(s, by_seq[s][1]) for s in in_range]):
                    ok = True
                    valid.append((first, last, key, v.get("VersionId")))
        if not ok:
            to_delete.append((key, v.get("VersionId")))

    # keep non-overlapping valid batches
    valid.sort()
    kept, covered = [], set()
    last_end = -1
    for first, last, key, vid in valid:
        if first > last_end:
            kept.append((first, last, key))
            last_end = last
            covered.update(s for s in seqs if first <= s <= last)
        else:
            to_delete.append((key, vid))

    for key, vid in to_delete:
        delete_version(key, vid)
    if to_delete:
        log(f"s3: purged {len(to_delete)} invalid/duplicate/noncurrent versions or delete markers")

    # Write missing batches (contiguous runs of published, uncovered rows) and stamp archived_at
    written = 0
    with conn.cursor() as cur:
        cur.execute("SET LOCAL lock_timeout = '30s'")
        cur.execute("""SELECT seq, payload, published_at IS NOT NULL, archived_at IS NOT NULL
                         FROM clearledger.outbox WHERE published_at IS NOT NULL ORDER BY seq FOR UPDATE""")
        locked = {r[0]: r for r in cur.fetchall()}
        runs, run = [], []
        for s in seqs:
            r = locked.get(s)
            if r is None or s in covered:
                if run:
                    runs.append(run)
                    run = []
                continue
            run.append((s, r[1]))
            if len(run) >= AUDIT_BATCH:
                runs.append(run)
                run = []
        if run:
            runs.append(run)
        for run in runs:
            body = batch_bytes(run)
            key = batch_key(run, body)
            s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType="application/x-ndjson")
            written += 1
            covered.update(s for s, _ in run)
        to_stamp = [s for s in covered if s in locked and not locked[s][3]]
        if to_stamp:
            cur.execute("""UPDATE clearledger.outbox SET archived_at = GREATEST(clock_timestamp(), published_at)
                            WHERE seq = ANY(%s) AND archived_at IS NULL AND published_at IS NOT NULL""",
                        (to_stamp,))
    conn.commit()
    log(f"s3: {len(kept)} canonical batches kept, {written} batches written, {len(to_stamp)} rows stamped archived")


def verify_s3(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT seq, payload FROM clearledger.outbox ORDER BY seq")
        rows = cur.fetchall()
        cur.execute("SELECT count(*) FROM clearledger.outbox WHERE archived_at IS NULL")
        unarchived = cur.fetchone()[0]
    conn.commit()
    versions, markers = list_all_versions()
    if markers or any(not v.get("IsLatest") for v in versions):
        return False
    seen = []
    for v in versions:
        m = KEY_RE.match(v["Key"])
        if not m:
            return False
        seen.append((int(m.group(1)), int(m.group(2))))
    seen.sort()
    count = 0
    by = dict(rows)
    for i, (a, b) in enumerate(seen):
        if i and a <= seen[i - 1][1]:
            return False
        count += sum(1 for s in by if a <= s <= b)
    return count == len(rows) and unarchived == 0


# ---------------------------------------------------------------------------
# 4. Valkey cache convergence
# ---------------------------------------------------------------------------
_TOKEN = None


def read_token():
    global _TOKEN
    if _TOKEN:
        return _TOKEN
    c = MANIFEST["auth"]["clients"]["read"]
    req = urllib.request.Request(
        MANIFEST["auth"]["token_endpoint"],
        data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": c["scope"],
                                     "client_id": c["client_id"]}).encode(),
        headers={"Authorization": "Basic " + base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode(),
                 "Content-Type": "application/x-www-form-urlencoded"})
    _TOKEN = json.load(urllib.request.urlopen(req, timeout=15))["access_token"]
    return _TOKEN


def api_get(path):
    req = urllib.request.Request(SERVICE_URL + path, headers={
        "Authorization": "Bearer " + read_token(), "X-Correlation-Id": "deploy-reconcile"})
    try:
        r = urllib.request.urlopen(req, timeout=15)
        return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def projection_json(state):
    out = {
        "settlementId": state["settlement_id"],
        "accountId": state["account_id"],
        "reference": state["reference"],
        "debitParty": state["debit_party"],
        "creditParty": state["credit_party"],
        "status": state["status"],
        "clearingStage": state["clearing_stage"],
    }
    if state.get("last_entry_id") is not None:
        out["lastEntryId"] = state["last_entry_id"]
    if state.get("last_memo") is not None:
        out["lastMemo"] = state["last_memo"]
    out["version"] = int(state["version"])
    out["entryCount"] = int(state["entry_count"])
    out["updatedAt"] = ts_api(state["updated_at"])
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False)


def converge_valkey(conn):
    host = MANIFEST["cache"]["endpoint"]
    port = int(MANIFEST["cache"]["port"])
    r = redis.Redis(host=host, port=port, socket_timeout=10, socket_connect_timeout=10)
    # other logical databases must not hold anything
    try:
        for db_name in r.info("keyspace").keys():
            idx = int(str(db_name).lstrip("db"))
            if idx != 0:
                redis.Redis(host=host, port=port, db=idx, socket_timeout=10).flushdb()
                log(f"valkey: flushed stray logical database {idx}")
    except Exception as exc:  # noqa: BLE001
        log(f"valkey: keyspace inspection failed: {exc}")

    settlements, ledger = load_ledger(conn)
    removed = 0
    for raw in r.scan_iter(match="*", count=500):
        key = raw.decode("utf-8", "replace")
        m = CACHE_RE.match(key)
        if not m or m.group(1) not in settlements:
            r.delete(raw)
            removed += 1
    log(f"valkey: removed {removed} stray keys")

    populated = fixed = 0
    for sid in sorted(settlements):
        events = ledger.get(sid, [])
        if not events:
            continue
        items = expected_items(sid, events)
        expected_body = projection_json(items[(f"SETTLEMENT#{sid}", "STATE")])
        key = f"clearledger:settlement:{sid}"
        r.delete(key)
        ok = False
        try:
            status, _, body = api_get(f"/v1/settlements/{sid}")
            if status == 200:
                val = r.get(key)
                ttl = r.ttl(key)
                if val is not None and 0 < ttl <= 90 and json.loads(val) == json.loads(body) \
                        and json.loads(val) == json.loads(expected_body):
                    ok = True
        except Exception as exc:  # noqa: BLE001
            log(f"valkey: API read for {sid} failed: {exc}")
        if not ok:
            r.set(key, expected_body.encode("utf-8"), ex=90)
            fixed += 1
        populated += 1
    log(f"valkey: {populated} settlement projections cached ({fixed} written directly)")


def main():
    conn = pg()
    converge_outbox(conn)
    ensure_esm_enabled()
    wait_queue_drain()
    converge_dynamodb(conn)
    for attempt in range(3):
        converge_s3(conn)
        if verify_s3(conn):
            log("s3: archive verified")
            break
        log("s3: verification failed, re-running convergence")
    # a final pass to pick up anything projected in the meantime
    wait_queue_drain(timeout=30)
    converge_dynamodb(conn)
    converge_valkey(conn)
    log("data plane converged")


if __name__ == "__main__":
    main()
__CLEARLEDGER_EOF__


# ---------------------------------------------------------------------------
# 1. Pre-apply repairs (KMS keys pending deletion / disabled, rogue IAM policies)
# ---------------------------------------------------------------------------
log "pre-apply control-plane repair"
python3 "${WORK}/prerepair.py" "${PREFIX}" "${REGION}" || log "pre-apply repair reported problems (continuing)"

# ---------------------------------------------------------------------------
# 2. Terraform / OpenTofu apply
# ---------------------------------------------------------------------------
log "terraform init"
if ! tf init -input=false -no-color >"${WORK}/init.log" 2>&1; then
  cat "${WORK}/init.log"
  die "terraform init failed"
fi

apply_ok=0
for attempt in 1 2 3 4; do
  log "terraform apply (attempt ${attempt})"
  set +e
  tf apply -auto-approve -input=false -no-color -lock-timeout=120s \
      -var "config_path=${CONFIG_FILE}" >"${WORK}/apply.log" 2>&1
  rc=$?
  set -e
  tf_filter <"${WORK}/apply.log"
  if [ "${rc}" -eq 0 ]; then
    apply_ok=1
    break
  fi
  log "terraform apply failed (rc=${rc}); re-running repairs before retry"
  python3 "${WORK}/prerepair.py" "${PREFIX}" "${REGION}" || true
  sleep $((attempt * 5))
done
[ "${apply_ok}" -eq 1 ] || die "terraform apply did not converge"

# ---------------------------------------------------------------------------
# 3. Manifest export
# ---------------------------------------------------------------------------
log "exporting manifest"
tf output -no-color -json manifest >"${WORK}/manifest.raw.json"
python3 "${WORK}/manifest.py" "${WORK}/manifest.raw.json" "${MANIFEST_FILE}"
log "manifest written to ${MANIFEST_FILE}"

SERVICE_URL="$(jq -r '.service_url' "${MANIFEST_FILE}")"
export PGHOST="$(jq -r '.database.endpoint' "${MANIFEST_FILE}")"
export PGPORT="$(jq -r '.database.port' "${MANIFEST_FILE}")"
export PGUSER="${DB_USER}"
export PGPASSWORD="${DB_PASS}"
export PGDATABASE="${DB_NAME}"
export PGCONNECT_TIMEOUT=10

# ---------------------------------------------------------------------------
# 4. PostgreSQL schema enforcement
# ---------------------------------------------------------------------------
log "enforcing PostgreSQL schema on ${PGHOST}:${PGPORT}/${PGDATABASE}"
schema_ok=0
for attempt in 1 2 3; do
  if python3 "${WORK}/schema.py" "${WORK}/functions.sql"; then
    schema_ok=1
    break
  fi
  log "schema enforcement failed (attempt ${attempt}); retrying"
  sleep 5
done
[ "${schema_ok}" -eq 1 ] || die "schema enforcement failed"

# ---------------------------------------------------------------------------
# 5. Post-apply hygiene: retention on runtime-created log groups of this prefix
# ---------------------------------------------------------------------------
python3 "${WORK}/posthygiene.py" "${PREFIX}" "${REGION}" || log "log hygiene reported problems (continuing)"

# ---------------------------------------------------------------------------
# 6. Wait for readiness
# ---------------------------------------------------------------------------
wait_ready() {
  local deadline=$(( $(date +%s) + $1 ))
  local code=""
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    code="$(curl -s -o "${WORK}/ready.json" -w '%{http_code}' --max-time 5 "${SERVICE_URL}/health/ready" || true)"
    if [ "${code}" = "200" ]; then
      log "service ready: $(cat "${WORK}/ready.json")"
      return 0
    fi
    sleep 3
  done
  log "readiness still failing (last status ${code}): $(cat "${WORK}/ready.json" 2>/dev/null || true)"
  return 1
}
log "waiting for ${SERVICE_URL}/health/ready"
wait_ready 300 || die "API did not become ready"

# ---------------------------------------------------------------------------
# 7. Data-plane convergence against PostgreSQL
# ---------------------------------------------------------------------------
log "converging derived data stores"
python3 "${WORK}/reconcile.py" "${MANIFEST_FILE}" || die "data-plane convergence failed"

wait_ready 120 || die "API not ready after convergence"
log "deployment ${PREFIX} converged"
exit 0
