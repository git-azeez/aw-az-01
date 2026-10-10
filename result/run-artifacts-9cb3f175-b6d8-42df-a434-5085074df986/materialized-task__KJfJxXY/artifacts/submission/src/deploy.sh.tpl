#!/usr/bin/env bash
# ClearLedger deployment: Terraform/OpenTofu apply, PostgreSQL schema, manifest, and data-plane convergence.
# Safe to re-run at any time (repairs control-plane drift, preserves RDS / DynamoDB / S3 data).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$HERE/infra"
CONFIG_FILE="${CONFIG_FILE:-/workspace/config/config.json}"
MANIFEST="$HERE/manifest.json"
SCHEMA="$HERE/.schema.sql"
HELPER="$HERE/.converge.py"
export CONFIG_FILE MANIFEST_FILE="$MANIFEST"

START=$(date +%s)
log() { echo "[deploy $(date +%H:%M:%S) +$(( $(date +%s) - START ))s] $*"; }

# ------------------------------------------------------------------ inputs
for bin in jq psql python3; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done
TF="$(command -v terraform || command -v tofu || true)"
[ -n "$TF" ] || { echo "neither terraform nor tofu found" >&2; exit 1; }

PREFIX="$(jq -r .resource_prefix "$CONFIG_FILE")"
REGION="$(jq -r .region "$CONFIG_FILE")"
ENDPOINT="$(jq -r .aws_endpoint_url "$CONFIG_FILE")"
DB_NAME="$(jq -r .db_name "$CONFIG_FILE")"
DB_USER="$(jq -r .db_username "$CONFIG_FILE")"
DB_PASS="$(jq -r .db_password "$CONFIG_FILE")"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config_file="$CONFIG_FILE"
log "prefix=$PREFIX region=$REGION endpoint=$ENDPOINT engine=$(basename "$TF")"

# ------------------------------------------------------------------ embedded helpers
cat > "$SCHEMA" <<'CLEARLEDGER_SCHEMA_EOF'
@@SCHEMA@@
CLEARLEDGER_SCHEMA_EOF
cat > "$HELPER" <<'CLEARLEDGER_HELPER_EOF'
@@CONVERGE@@
CLEARLEDGER_HELPER_EOF
trap 'rm -f "$SCHEMA" "$HELPER"' EXIT
helper() { python3 "$HELPER" "$@"; }

tf() { "$TF" -chdir="$INFRA" "$@"; }

write_manifest() {
  local tmp="$MANIFEST.tmp"
  tf output -json manifest > "$tmp"
  python3 - "$tmp" <<'PY'
import json, sys
import jsonschema
m = json.load(open(sys.argv[1]))
schema = json.load(open("/workspace/contracts/schemas/manifest.schema.json"))
jsonschema.validate(m, schema)
json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
  mv "$tmp" "$MANIFEST"
}

# ------------------------------------------------------------------ control plane reachable?
for i in $(seq 1 30); do
  if curl -fsS -m 5 -o /dev/null "$ENDPOINT/_localstack/health" 2>/dev/null || curl -sS -m 5 -o /dev/null "$ENDPOINT" 2>/dev/null; then break; fi
  sleep 2
done

# ------------------------------------------------------------------ terraform
log "terraform init"
tf init -input=false -no-color >/dev/null
helper kms-restore || log "kms-restore skipped"

apply_ok=0
for attempt in 1 2 3; do
  log "terraform apply (attempt $attempt)"
  if tf apply -auto-approve -input=false -no-color -lock-timeout=120s; then apply_ok=1; break; fi
  log "apply failed; repairing and retrying"
  helper kms-restore || true
  sleep 10
done
[ "$apply_ok" = 1 ] || { log "terraform apply failed"; exit 1; }

write_manifest

# The projector event source mapping must exist, be enabled and point at the live queue.
ESM_UUID="$(jq -r .messaging.event_source_mapping_uuid "$MANIFEST")"
if ! helper esm-check "$ESM_UUID"; then
  log "re-binding projector event source mapping"
  tf apply -auto-approve -input=false -no-color -lock-timeout=120s \
     -replace=aws_lambda_event_source_mapping.projector
  write_manifest
fi

# ------------------------------------------------------------------ out-of-band control-plane drift Terraform cannot see
log "reconciling IAM policies and security groups"
helper iam-clean
helper sg-clean

# ------------------------------------------------------------------ PostgreSQL schema
DB_HOST="$(jq -r .database.endpoint "$MANIFEST")"
DB_PORT="$(jq -r .database.port "$MANIFEST")"
DB_URL="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGCONNECT_TIMEOUT=10
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 60); do
  if psql "$DB_URL" -X -q -At -c 'select 1' >/dev/null 2>&1; then break; fi
  sleep 3
done
schema_ok=0
for attempt in 1 2 3 4 5; do
  log "applying clearledger schema (attempt $attempt)"
  if psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$SCHEMA"; then schema_ok=1; break; fi
  sleep 5
done
[ "$schema_ok" = 1 ] || { log "schema application failed"; exit 1; }

# ------------------------------------------------------------------ readiness
SERVICE_URL="$(jq -r .service_url "$MANIFEST")"
wait_ready() {
  local limit="$1" code
  for i in $(seq 1 "$limit"); do
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SERVICE_URL/health/ready" || true)"
    [ "$code" = "200" ] && return 0
    sleep 3
  done
  return 1
}
log "waiting for $SERVICE_URL/health/ready"
wait_ready 80 || { log "API did not become ready"; exit 1; }

# ------------------------------------------------------------------ data-plane convergence (PostgreSQL is authoritative)
log "converging outbox, DynamoDB, S3 audit archive and Valkey"
conv_ok=0
for attempt in 1 2 3; do
  if helper data; then conv_ok=1; break; fi
  log "data convergence incomplete (attempt $attempt)"
  sleep 5
done
[ "$conv_ok" = 1 ] || { log "data convergence failed"; exit 1; }

write_manifest
wait_ready 20 || { log "API not ready at exit"; exit 1; }
log "deployment complete: $SERVICE_URL"
