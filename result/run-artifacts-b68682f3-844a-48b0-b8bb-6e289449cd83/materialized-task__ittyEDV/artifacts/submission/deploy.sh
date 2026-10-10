#!/usr/bin/env bash
# ClearLedger deployment: converges infrastructure, PostgreSQL schema and every
# derived data store. Safe to re-run at any time.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$HERE/infra"
SCRIPTS="$HERE/scripts"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST="$HERE/manifest.json"
START=$(date +%s)

log() { printf '[%s] [deploy +%ss] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - START ))" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

[ -f "$CONFIG" ] || die "missing config $CONFIG"
for tool in jq psql curl; do command -v "$tool" >/dev/null || die "$tool is required"; done

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
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config_path="$CONFIG"

# Terraform (preferred) or OpenTofu.
TF="$(command -v terraform || command -v tofu || true)"
[ -n "$TF" ] || die "neither terraform nor tofu is installed"

# A Python interpreter that has boto3 (the aws CLI venv has it).
PY=""
for cand in python3 /opt/venv/bin/python3 "$(head -1 "$(command -v aws 2>/dev/null || echo /nonexistent)" 2>/dev/null | sed -n 's/^#!//p')"; do
  [ -n "$cand" ] || continue
  if "$cand" -c 'import boto3, psycopg2, redis, requests' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || die "no python interpreter with boto3, psycopg2, redis and requests found"

log "prefix=$PREFIX region=$REGION endpoint=$ENDPOINT tool=$TF"

# --------------------------------------------------------------------------
# 1. Infrastructure
# --------------------------------------------------------------------------
tf() { "$TF" -chdir="$INFRA" "$@"; }

log "terraform init"
tf init -input=false -no-color

apply_ok=0
for attempt in 1 2 3; do
  log "terraform apply (attempt $attempt)"
  if tf apply -input=false -auto-approve -no-color -lock-timeout=60s; then apply_ok=1; break; fi
  log "apply failed; refreshing and retrying"
  sleep 10
done
[ "$apply_ok" = 1 ] || die "terraform apply did not succeed"

write_manifest() {
  tf output -json manifest | jq -S . > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  "$PY" "$SCRIPTS/validate_manifest.py" "$MANIFEST"
}
write_manifest

DB_HOST="$(jq -er .database.endpoint "$MANIFEST")"
DB_PORT="$(jq -er .database.port "$MANIFEST")"
SERVICE_URL="$(jq -er .service_url "$MANIFEST")"

# --------------------------------------------------------------------------
# 2. PostgreSQL schema, constraints, triggers, indexes
# --------------------------------------------------------------------------
export PGPASSWORD="$DB_PASS" PGCONNECT_TIMEOUT=10
psql_cmd=(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -X -q)

log "waiting for PostgreSQL at $DB_HOST:$DB_PORT"
for i in $(seq 1 90); do
  if "${psql_cmd[@]}" -tAc 'select 1' >/dev/null 2>&1; then break; fi
  [ "$i" -lt 90 ] || die "PostgreSQL did not become reachable"
  sleep 2
done

log "applying clearledger schema"
for attempt in 1 2 3; do
  if "${psql_cmd[@]}" -o /dev/null -f "$HERE/sql/schema.sql"; then break; fi
  [ "$attempt" -lt 3 ] || die "schema application failed"
  sleep 3
done

# --------------------------------------------------------------------------
# 3. Control-plane drift Terraform cannot see (security group rules, IAM policies)
# --------------------------------------------------------------------------
log "control-plane backstop"
"$PY" "$SCRIPTS/controlplane.py" "$CONFIG" "$MANIFEST"

# --------------------------------------------------------------------------
# 4. Wait for the API
# --------------------------------------------------------------------------
wait_ready() {
  local deadline=$(( $(date +%s) + ${1:-300} )) code body
  while :; do
    code="$(curl -s -o /tmp/clearledger-ready.$$ -w '%{http_code}' --max-time 5 "$SERVICE_URL/health/ready" || true)"
    if [ "$code" = 200 ]; then rm -f /tmp/clearledger-ready.$$; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      body="$(cat /tmp/clearledger-ready.$$ 2>/dev/null || true)"; rm -f /tmp/clearledger-ready.$$
      log "last readiness response: HTTP $code $body"
      return 1
    fi
    sleep 3
  done
}
log "waiting for $SERVICE_URL/health/ready"
wait_ready 300 || die "API did not become ready"

# --------------------------------------------------------------------------
# 5. Data plane: outbox -> SQS, DynamoDB, S3 audit archive, Valkey
# --------------------------------------------------------------------------
log "converging data plane against PostgreSQL"
"$PY" "$SCRIPTS/dataplane.py" "$CONFIG" "$MANIFEST"

write_manifest
wait_ready 60 || die "API stopped being ready"
log "deploy complete: $SERVICE_URL"
