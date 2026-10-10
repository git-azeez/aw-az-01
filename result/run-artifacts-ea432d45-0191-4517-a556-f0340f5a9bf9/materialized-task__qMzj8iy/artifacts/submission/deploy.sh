#!/usr/bin/env bash
# ClearLedger deployment: infrastructure (Terraform/OpenTofu), PostgreSQL schema,
# drift repair, data-plane convergence, manifest export, readiness gate.
# Safe to re-run at any time.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
INFRA="$ROOT/infra"
MANIFEST="$ROOT/manifest.json"
SCHEMA_SQL="$ROOT/sql/schema.sql"
RECONCILE="$ROOT/scripts/reconcile.py"
SCHEMA_JSON="${CLEARLEDGER_MANIFEST_SCHEMA:-/workspace/contracts/schemas/manifest.schema.json}"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
trap 'log "FAILED at line $LINENO (exit $?)"' ERR

cfg() { jq -er "$1" "$CONFIG"; }

PREFIX="$(cfg .resource_prefix)"
REGION="$(cfg .region)"
ENDPOINT="$(cfg .aws_endpoint_url)"
DB_PASSWORD="$(cfg .db_password)"
DB_USER="$(cfg .db_username)"

export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1 TF_INPUT=0
ENDPOINT_HOST="$(printf '%s' "$ENDPOINT" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')"
export NO_PROXY="${NO_PROXY:-},${ENDPOINT_HOST},localhost,127.0.0.1" no_proxy="${no_proxy:-},${ENDPOINT_HOST},localhost,127.0.0.1"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else log "neither terraform nor tofu is installed"; exit 1; fi
log "using $TF for prefix $PREFIX ($ENDPOINT)"

tf() { "$TF" -chdir="$INFRA" "$@"; }

write_manifest() {
  local tmp
  tmp="$(mktemp "$ROOT/.manifest.XXXXXX")"
  tf output -json manifest | jq -S . > "$tmp"
  python3 - "$tmp" "$SCHEMA_JSON" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
try:
    import jsonschema
except ImportError:
    sys.exit(0)
try:
    schema = json.load(open(sys.argv[2]))
except OSError:
    sys.exit(0)
jsonschema.validate(doc, schema)
PY
  chmod 644 "$tmp"
  mv -f "$tmp" "$MANIFEST"
}

# ---------------------------------------------------------------- 1. infrastructure
log "terraform init"
tf init -input=false -no-color >/dev/null

applied=0
for attempt in 1 2 3; do
  log "terraform apply (attempt $attempt)"
  if tf apply -auto-approve -input=false -no-color -lock-timeout=120s -parallelism=20 \
        -var "config_path=$CONFIG" 2>&1 | grep -v -E '^(.*: (Refreshing state|Still (creating|modifying|destroying))\.\.\.|\s*$)'; then
    applied=1
    break
  fi
  log "apply failed; retrying after refresh"
  sleep 10
done
[ "$applied" = 1 ] || { log "terraform apply did not succeed"; exit 1; }

write_manifest
log "manifest written to $MANIFEST"

DB_HOST="$(jq -er .database.endpoint "$MANIFEST")"
DB_PORT="$(jq -er .database.port "$MANIFEST")"
DB_NAME="$(jq -er .database.db_name "$MANIFEST")"
SERVICE_URL="$(jq -er .service_url "$MANIFEST")"

# ---------------------------------------------------------------- 2. database schema
log "applying PostgreSQL schema on $DB_HOST:$DB_PORT/$DB_NAME"
ok=0
for i in $(seq 1 30); do
  if PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=10 PGOPTIONS='-c client_min_messages=warning' \
       psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -X -q -v ON_ERROR_STOP=1 -1 -o /dev/null -f "$SCHEMA_SQL"; then
    ok=1; break
  fi
  log "schema apply not successful yet (try $i); waiting"
  sleep 4
done
[ "$ok" = 1 ] || { log "could not apply the PostgreSQL schema"; exit 1; }

# ---------------------------------------------------------------- 3. out-of-band drift
log "removing out-of-band IAM policies and security group rules"
python3 "$RECONCILE" drift --config "$CONFIG" --manifest "$MANIFEST"

# ---------------------------------------------------------------- 4. readiness
wait_ready() {
  local limit="$1" i code
  for i in $(seq 1 "$limit"); do
    code="$(curl -s --noproxy '*' -o /dev/null -m 5 -w '%{http_code}' "$SERVICE_URL/health/ready" || true)"
    [ "$code" = 200 ] && return 0
    sleep 3
  done
  return 1
}
log "waiting for $SERVICE_URL/health/ready"
wait_ready 80 || { log "API did not become ready"; exit 1; }

# ---------------------------------------------------------------- 5. data-plane convergence
log "draining the outbox"
python3 "$RECONCILE" drain --config "$CONFIG" --manifest "$MANIFEST"
log "reconciling the S3 audit archive"
python3 "$RECONCILE" archive --config "$CONFIG" --manifest "$MANIFEST"
log "reconciling DynamoDB projections"
python3 "$RECONCILE" ddb --config "$CONFIG" --manifest "$MANIFEST"
log "reconciling the Valkey cache"
python3 "$RECONCILE" valkey --config "$CONFIG" --manifest "$MANIFEST"

# ---------------------------------------------------------------- 6. final gate
wait_ready 40 || { log "API is not ready after convergence"; exit 1; }
write_manifest
log "deployment converged; service_url=$SERVICE_URL"
