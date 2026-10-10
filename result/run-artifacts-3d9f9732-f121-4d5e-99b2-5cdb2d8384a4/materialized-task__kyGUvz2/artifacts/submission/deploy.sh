#!/usr/bin/env bash
# ClearLedger deployment: Terraform apply + PostgreSQL schema + drift repair + data-plane convergence.
# Safe to re-run at any time (idempotent); never replaces the RDS instance, DynamoDB table or S3 bucket.
set -Eeuo pipefail

SUBMISSION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$SUBMISSION/infra"
LIB="$SUBMISSION/lib"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST="$SUBMISSION/manifest.json"
START=$(date +%s)
DEADLINE=$((START + 690))        # hard budget is 720s

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cfg() { jq -er ".$1" "$CONFIG"; }

[ -r "$CONFIG" ] || die "config not found: $CONFIG"
export AWS_ENDPOINT_URL AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
AWS_ENDPOINT_URL="$(cfg aws_endpoint_url)"
AWS_REGION="$(cfg region)"
AWS_DEFAULT_REGION="$AWS_REGION"
PREFIX="$(cfg resource_prefix)"
DB_NAME="$(cfg db_name)"
DB_USER="$(cfg db_username)"
export PGPASSWORD
PGPASSWORD="$(cfg db_password)"
export TF_IN_AUTOMATION=1 TF_INPUT=0
[ -n "${TF_CLI_CONFIG_FILE:-}" ] || { [ -r /etc/terraform.tfrc ] && export TF_CLI_CONFIG_FILE=/etc/terraform.tfrc; } || true
export PYTHONPATH="$LIB${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONUNBUFFERED=1
# The control plane and data stores are reached directly, never through the sandbox proxy.
export no_proxy="${no_proxy:+$no_proxy,}aws,localhost,127.0.0.1" NO_PROXY="${NO_PROXY:+$NO_PROXY,}aws,localhost,127.0.0.1"

TF=terraform
tf() { (cd "$INFRA" && "$TF" "$@"); }

# Runs a command, hides terraform's progress ticker and returns the command's own exit status.
filtered() {
  local rc
  set +e
  "$@" 2>&1 | grep --line-buffered -v -E 'Still (creating|modifying|destroying)\.\.\.|^$'
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

tf_apply() {
  local attempt
  for attempt in 1 2 3; do
    if filtered bash -c 'cd "$1" && shift && exec timeout 480 terraform apply -auto-approve -input=false -no-color -compact-warnings -lock-timeout=60s "$@"' _ "$INFRA" -var-file="$CONFIG" "$@"; then
      return 0
    fi
    log "terraform apply attempt $attempt failed; repairing and retrying"
    python3 "$LIB/drift.py" iam || true
    sleep 5
  done
  return 1
}

write_manifest() {
  local tmp="$MANIFEST.tmp"
  tf output -json manifest | jq '.' > "$tmp" || die "cannot read manifest output"
  mv "$tmp" "$MANIFEST"
  python3 - <<'PY'
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(0)
schema = json.load(open("/workspace/contracts/schemas/manifest.schema.json"))
doc = json.load(open("/workspace/submission/manifest.json"))
jsonschema.validate(doc, schema)
print("manifest.json validates against manifest.schema.json")
PY
}

# ---------------------------------------------------------------------------------------------------------------
log "== 1/7 terraform init"
tf init -input=false -no-color -upgrade=false >/dev/null || die "terraform init failed"

log "== 2/7 terraform apply (creates missing resources, reverts control-plane drift)"
tf_apply || die "terraform apply failed"
write_manifest

log "== 3/7 out-of-band IAM / security-group / event-source-mapping repair"
python3 "$LIB/drift.py" iam
python3 "$LIB/drift.py" sg
python3 "$LIB/drift.py" esm-prune
if ! python3 "$LIB/drift.py" esm; then
  log "projector event source mapping is missing or inconsistent; re-creating it"
  tf_apply -replace=aws_lambda_event_source_mapping.projector || die "cannot recreate the event source mapping"
  write_manifest
  python3 "$LIB/drift.py" esm || die "projector event source mapping still inconsistent"
fi

log "== 4/7 PostgreSQL schema"
DB_HOST="$(jq -er '.database.endpoint' "$MANIFEST")"
DB_PORT="$(jq -er '.database.port' "$MANIFEST")"
for i in $(seq 1 60); do
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -qtAc 'select 1' >/dev/null 2>&1 && break
  [ "$i" -eq 60 ] && die "PostgreSQL at $DB_HOST:$DB_PORT is not reachable"
  sleep 3
done
filtered env PGOPTIONS='-c client_min_messages=warning' psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -1 -q -o /dev/null -f "$LIB/schema.sql" || die "schema migration failed"
log "schema applied"

log "== 5/7 data-plane reconciliation (outbox -> SQS -> DynamoDB/Valkey, S3 audit archive)"
python3 "$LIB/reconcile.py" "$DEADLINE" || die "data-plane reconciliation failed"

log "== 6/7 wait for API readiness"
SERVICE_URL="$(jq -er '.service_url' "$MANIFEST")"
ready=0
while [ "$(date +%s)" -lt "$((START + 705))" ]; do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$SERVICE_URL/health/ready" || true)"
  if [ "$code" = "200" ]; then ready=1; break; fi
  sleep 3
done
[ "$ready" -eq 1 ] || die "GET $SERVICE_URL/health/ready did not return 200"

log "== 7/7 done: $SERVICE_URL ready after $(( $(date +%s) - START ))s"
exit 0
