#!/usr/bin/env bash
# ClearLedger deployment: converges control plane (Terraform), PostgreSQL schema and all derived
# data stores (DynamoDB, Valkey, S3 audit archive) against the authoritative PostgreSQL state.
# Idempotent; safe to re-run after drift, deleted resources, or out-of-band changes.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$ROOT/infra"
LIB="$ROOT/lib"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST="$ROOT/manifest.json"
START_TS=$SECONDS

log() { printf '[deploy %3ss] %s\n' "$((SECONDS - START_TS))" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "failed at line $LINENO (exit $?)"' ERR

[[ -r "$CONFIG" ]] || die "config file $CONFIG not found"
cfg() { jq -er ".$1" "$CONFIG"; }

PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
ENDPOINT="$(cfg aws_endpoint_url)"
DB_NAME="$(cfg db_name)"
DB_USER="$(cfg db_username)"
DB_PASS="$(cfg db_password)"

export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export CLEARLEDGER_CONFIG="$CONFIG" CLEARLEDGER_MANIFEST="$MANIFEST"
export TF_IN_AUTOMATION=1 TF_INPUT=0
[[ -z "${TF_CLI_CONFIG_FILE:-}" && -r /etc/terraform.tfrc ]] && export TF_CLI_CONFIG_FILE=/etc/terraform.tfrc
# the control plane and the database are reached directly, never through the egress proxy
export NO_PROXY="${NO_PROXY:-},aws,localhost,127.0.0.1" no_proxy="${no_proxy:-},aws,localhost,127.0.0.1"

TF="${TF_BIN:-terraform}"
command -v "$TF" >/dev/null || die "$TF not found"
TFVARS=(-var "config_path=$CONFIG")
mkdir -p "$INFRA"
cd "$INFRA"

retry() { # retry <attempts> <sleep> cmd...
  local n="$1" s="$2" i; shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    log "attempt $i/$n failed: $*"
    ((i < n)) && sleep "$s"
  done
  return 1
}

tf_apply() { "$TF" apply -auto-approve -input=false -no-color -lock-timeout=60s "${TFVARS[@]}" "$@"; }

log "terraform init (prefix=$PREFIX region=$REGION)"
retry 3 5 "$TF" init -input=false -no-color >/dev/null

# ---------------------------------------------------------------------------------------------
# Phase 1: the database first, so the schema is in place before any workload starts.
# ---------------------------------------------------------------------------------------------
log "phase 1: apply networking, KMS and RDS"
retry 3 10 tf_apply -target=aws_db_instance.main >/tmp/clearledger-tf-phase1.log 2>&1 \
  || { tail -40 /tmp/clearledger-tf-phase1.log; die "terraform apply (database) failed"; }
grep -E "^(Apply complete|Warning: Applied changes)" /tmp/clearledger-tf-phase1.log || true

DB_HOST="$("$TF" state pull | jq -er '.resources[] | select(.type=="aws_db_instance" and .name=="main") | .instances[0].attributes.address')"
DB_PORT="$("$TF" state pull | jq -er '.resources[] | select(.type=="aws_db_instance" and .name=="main") | .instances[0].attributes.port')"
export PGPASSWORD="$DB_PASS" PGCONNECT_TIMEOUT=10

wait_for_db() {
  local i
  for ((i = 1; i <= 60; i++)); do
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -qAtc 'select 1' >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  return 1
}

apply_schema() {
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -X -q -v ON_ERROR_STOP=1 -f "$LIB/schema.sql" >/dev/null
}

log "waiting for PostgreSQL at $DB_HOST:$DB_PORT"
wait_for_db || die "PostgreSQL did not become reachable"
log "applying clearledger schema, constraints, triggers and indexes"
retry 5 5 apply_schema || die "schema initialisation failed"

# ---------------------------------------------------------------------------------------------
# Phase 2: everything else (also repairs control-plane drift and recreates deleted resources).
# ---------------------------------------------------------------------------------------------
log "phase 2: full terraform apply"
retry 3 10 tf_apply >/tmp/clearledger-tf-phase2.log 2>&1 \
  || { tail -60 /tmp/clearledger-tf-phase2.log; die "terraform apply failed"; }
grep -E "^(Apply complete|Plan:)" /tmp/clearledger-tf-phase2.log || true

write_manifest() {
  local tmp="$MANIFEST.tmp"
  "$TF" output -json manifest | jq -S . >"$tmp"
  python3 - "$tmp" "$ROOT" <<'PY'
import json, sys
import jsonschema
doc = json.load(open(sys.argv[1]))
schema = json.load(open("/workspace/contracts/schemas/manifest.schema.json"))
jsonschema.validate(doc, schema)
PY
  mv -f "$tmp" "$MANIFEST"
}

log "writing manifest.json"
write_manifest || die "manifest generation/validation failed"

# Control-plane attributes the provider cannot always observe are verified directly; if any drift
# is still visible, force a refresh/re-apply once more.
if ! python3 "$LIB/reconcile.py" verify-control; then
  log "drift still visible after apply; re-applying with a fresh refresh"
  retry 3 10 tf_apply -refresh=true >/tmp/clearledger-tf-phase3.log 2>&1 \
    || { tail -60 /tmp/clearledger-tf-phase3.log; die "terraform re-apply failed"; }
  write_manifest || die "manifest generation failed"
  python3 "$LIB/reconcile.py" verify-control || die "control plane drift could not be repaired"
fi

log "removing out-of-band IAM policies and open security group egress"
python3 "$LIB/reconcile.py" iam-sg

# ---------------------------------------------------------------------------------------------
# Phase 3: data plane convergence against PostgreSQL
# ---------------------------------------------------------------------------------------------
log "relaying unpublished outbox rows"
python3 "$LIB/reconcile.py" drain-outbox
log "waiting for the projector to drain the main queue"
python3 "$LIB/reconcile.py" wait-queue
log "reconciling DynamoDB projections"
python3 "$LIB/reconcile.py" dynamodb
log "reconciling Valkey cache"
python3 "$LIB/reconcile.py" valkey
log "reconciling S3 audit archive"
python3 "$LIB/reconcile.py" s3

# ---------------------------------------------------------------------------------------------
# Phase 4: readiness
# ---------------------------------------------------------------------------------------------
SERVICE_URL="$(jq -er .service_url "$MANIFEST")"
log "waiting for $SERVICE_URL/health/ready"
ready=0
for ((i = 1; i <= 90; i++)); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$SERVICE_URL/health/ready" || true)"
  if [[ "$code" == "200" ]]; then ready=1; break; fi
  sleep 3
done
((ready)) || die "service did not become ready (last HTTP status: ${code:-none})"

# A last cache sweep: anything the API cached while the stores were converging is validated again.
python3 "$LIB/reconcile.py" valkey

log "deployment complete: $SERVICE_URL"
exit 0
