#!/usr/bin/env bash
# Deploys (or repairs / re-converges) the ClearLedger platform.
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SELF_DIR/scripts/common.sh"

START=$(date +%s)
trap 'stop_proxy' EXIT
trap 'rc=$?; echo "[$(ts)] deploy.sh failed (exit $rc) at line $LINENO" >&2' ERR

load_config
pick_tool
for bin in jq psql curl python3; do command -v "$bin" >/dev/null 2>&1 || die "$bin is required"; done
log "deploying ClearLedger prefix=$RESOURCE_PREFIX region=$REGION endpoint=$AWS_ENDPOINT using $TF"

start_proxy
cd "$INFRA_DIR"
tf_init

# ---------------------------------------------------------------------------
# Database host/port come from Terraform state
# ---------------------------------------------------------------------------
db_endpoint() {
  jq -r '[.resources[]? | select(.type=="aws_db_instance" and .name=="main") | .instances[0].attributes | "\(.address) \(.port)"][0] // empty' "$STATE_FILE" 2>/dev/null || true
}

run_psql() {
  local host="$1" port="$2"; shift 2
  PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=10 psql -h "$host" -p "$port" -U "$DB_USER" -d "$DB_NAME" \
    -X -q -v ON_ERROR_STOP=1 "$@"
}

apply_schema() {
  local host="$1" port="$2" i
  for i in $(seq 1 60); do
    if run_psql "$host" "$port" -tAc 'SELECT 1' >/dev/null 2>&1; then break; fi
    [ "$i" -eq 60 ] && die "PostgreSQL at $host:$port did not become reachable"
    sleep 3
  done
  log "applying clearledger schema (idempotent) to $host:$port"
  run_psql "$host" "$port" -o /dev/null -f "$SUB_DIR/sql/schema.sql"
}

# Phase 1: make sure the database exists, then give it its schema *before* the
# API tasks start probing /health/ready.
log "phase 1: database"
tf_apply -target=aws_db_instance.main
read -r DB_HOST DB_PORT <<<"$(db_endpoint)"
[ -n "${DB_HOST:-}" ] || die "could not determine database endpoint from state"
apply_schema "$DB_HOST" "$DB_PORT"

# Phase 2: everything else. Refresh makes Terraform repair out-of-band drift
# (SQS attributes, schedules, log retention, Lambda env, event source mappings,
# security group rules, role policies, deleted resources ...).
log "phase 2: full apply"
tf_apply
read -r DB_HOST DB_PORT <<<"$(db_endpoint)"
apply_schema "$DB_HOST" "$DB_PORT"

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
log "writing manifest"
TMP_MANIFEST="$(mktemp "$SUB_DIR/.manifest.XXXXXX")"
tf output -json manifest | jq -S . >"$TMP_MANIFEST"
python3 - "$TMP_MANIFEST" "/workspace/contracts/schemas/manifest.schema.json" <<'PY'
import json, os, sys
m = json.load(open(sys.argv[1]))
schema_path = sys.argv[2]
if os.path.exists(schema_path):
    try:
        import jsonschema
        jsonschema.validate(m, json.load(open(schema_path)))
    except ImportError:
        pass
assert os.path.getsize(sys.argv[1]) < 1024 * 1024
PY
chmod 0644 "$TMP_MANIFEST"
mv -f "$TMP_MANIFEST" "$MANIFEST_FILE"

SERVICE_URL="$(jq -r .service_url "$MANIFEST_FILE")"

# ---------------------------------------------------------------------------
# Control-plane drift that Terraform cannot see (extra policies / SG rules)
# ---------------------------------------------------------------------------
log "control-plane reconciliation (IAM, security groups)"
python3 "$SUB_DIR/scripts/reconcile.py" control --config "$CONFIG_FILE" --manifest "$MANIFEST_FILE"

wait_ready() {
  local limit="$1" end code
  end=$(( $(date +%s) + limit ))
  while [ "$(date +%s)" -lt "$end" ]; do
    code="$(curl -s --noproxy '*' -o /dev/null -m 5 -w '%{http_code}' "$SERVICE_URL/health/ready" || true)"
    if [ "$code" = "200" ]; then return 0; fi
    sleep 3
  done
  return 1
}

log "waiting for $SERVICE_URL/health/ready"
wait_ready 300 || die "API did not report ready (HTTP 200) in time"

# ---------------------------------------------------------------------------
# Data-plane convergence against PostgreSQL
# ---------------------------------------------------------------------------
log "data-plane reconciliation (outbox, DynamoDB, S3 audit archive, Valkey)"
python3 "$SUB_DIR/scripts/reconcile.py" data --config "$CONFIG_FILE" --manifest "$MANIFEST_FILE"

wait_ready 120 || die "API stopped reporting ready after reconciliation"
log "deploy complete in $(( $(date +%s) - START ))s: $SERVICE_URL"
