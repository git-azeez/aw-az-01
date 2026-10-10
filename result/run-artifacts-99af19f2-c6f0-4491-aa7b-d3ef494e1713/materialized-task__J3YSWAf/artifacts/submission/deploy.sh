#!/usr/bin/env bash
# ClearLedger deployment: Terraform apply + PostgreSQL schema + manifest +
# readiness gate + control-plane / data-plane convergence.  Idempotent.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$HERE/scripts/common.sh"

load_config
pick_tf
trap 'stop_forwarder' EXIT
trap 'log "deploy failed at line $LINENO"' ERR

MANIFEST="$ROOT/manifest.json"
PYTHON="$(command -v python3)"
APPLY_ATTEMPTS=3
READY_TIMEOUT=240

log "ClearLedger deploy for prefix $PREFIX ($REGION, $ENDPOINT) using $TF"
start_forwarder

# ---------------------------------------------------------------------------
# 1. Infrastructure
# ---------------------------------------------------------------------------
tf_init
for attempt in $(seq 1 "$APPLY_ATTEMPTS"); do
  log "terraform apply (attempt $attempt/$APPLY_ATTEMPTS)"
  if tf apply -auto-approve -input=false -no-color -lock-timeout=60s 2>&1 | sed -u -E 's#(postgres://[^:]+:)[^@]*@#\1***@#g'; then
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then break; fi
  fi
  [ "$attempt" -lt "$APPLY_ATTEMPTS" ] || die "terraform apply failed"
  sleep 10
done

# ---------------------------------------------------------------------------
# 2. Manifest
# ---------------------------------------------------------------------------
write_manifest() {
  local tmp
  tmp="$(mktemp "$ROOT/.manifest.XXXXXX")"
  tf output -json manifest | jq -S . >"$tmp"
  "$PYTHON" - "$tmp" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
try:
    import jsonschema
    schema = json.load(open("/workspace/contracts/schemas/manifest.schema.json"))
    jsonschema.validate(manifest, schema)
except FileNotFoundError:
    pass
PY
  chmod 0644 "$tmp"
  mv -f "$tmp" "$MANIFEST"
}
write_manifest
log "manifest written to $MANIFEST"

DB_HOST="$(jq -r .database.endpoint "$MANIFEST")"
DB_PORT="$(jq -r .database.port "$MANIFEST")"
SERVICE_URL="$(jq -r .service_url "$MANIFEST")"

# ---------------------------------------------------------------------------
# 3. PostgreSQL schema, constraints, triggers, indexes
# ---------------------------------------------------------------------------
export PGPASSWORD="$DB_PASS" PGCONNECT_TIMEOUT=10
PSQL=(psql -X -q -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1)

log "waiting for PostgreSQL at $DB_HOST:$DB_PORT"
for i in $(seq 1 90); do
  if "${PSQL[@]}" -c 'select 1' >/dev/null 2>&1; then break; fi
  [ "$i" -lt 90 ] || die "PostgreSQL did not become reachable"
  sleep 2
done

log "applying clearledger schema"
for attempt in 1 2 3 4; do
  if "${PSQL[@]}" -o /dev/null -f "$ROOT/sql/schema.sql"; then break; fi
  # release the advisory lock held by an aborted session, then retry
  [ "$attempt" -lt 4 ] || die "schema migration failed"
  log "schema migration failed (attempt $attempt); retrying"
  sleep 5
done

# ---------------------------------------------------------------------------
# 4. Control-plane convergence (things Terraform cannot see or own)
# ---------------------------------------------------------------------------
log "reconciling IAM, security groups and KMS state"
"$PYTHON" "$ROOT/scripts/reconcile.py" control-plane

# ---------------------------------------------------------------------------
# 5. Readiness gate
# ---------------------------------------------------------------------------
wait_ready() {
  local deadline=$(( $(date +%s) + READY_TIMEOUT )) code=000
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$SERVICE_URL/health/ready" || true)"
    [ "$code" = "200" ] && return 0
    sleep 3
  done
  log "last readiness status: $code"
  return 1
}
log "waiting for $SERVICE_URL/health/ready"
wait_ready || die "service did not report ready"
log "service is ready"

# ---------------------------------------------------------------------------
# 6. Data-plane convergence: outbox -> SQS, S3 archive, DynamoDB, Valkey
# ---------------------------------------------------------------------------
"$PYTHON" "$ROOT/scripts/reconcile.py" data-plane

wait_ready || die "service is not ready after convergence"
write_manifest
log "deploy complete: $SERVICE_URL"
