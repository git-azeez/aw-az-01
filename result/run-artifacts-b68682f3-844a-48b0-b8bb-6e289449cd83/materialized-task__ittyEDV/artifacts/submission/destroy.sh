#!/usr/bin/env bash
# ClearLedger teardown: destroys everything scoped to resource_prefix (Terraform
# managed or created out-of-band) and leaves cl-base-* baseline resources alone.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$HERE/infra"
SCRIPTS="$HERE/scripts"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
START=$(date +%s)

log() { printf '[%s] [destroy +%ss] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - START ))" "$*"; }

[ -f "$CONFIG" ] || { log "missing config $CONFIG"; exit 1; }
command -v jq >/dev/null || { log "jq is required"; exit 1; }

export AWS_ENDPOINT_URL="$(jq -er .aws_endpoint_url "$CONFIG")"
export AWS_REGION="$(jq -er .region "$CONFIG")" AWS_DEFAULT_REGION="$(jq -er .region "$CONFIG")"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config_path="$CONFIG"
PREFIX="$(jq -er .resource_prefix "$CONFIG")"

TF="$(command -v terraform || command -v tofu || true)"
PY=""
for cand in python3 /opt/venv/bin/python3 "$(head -1 "$(command -v aws 2>/dev/null || echo /nonexistent)" 2>/dev/null | sed -n 's/^#!//p')"; do
  [ -n "$cand" ] || continue
  if "$cand" -c 'import boto3' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { log "no python interpreter with boto3 found"; exit 1; }

tf() { "$TF" -chdir="$INFRA" "$@"; }
state_count() { tf state list 2>/dev/null | grep -c . || true; }

log "tearing down prefix=$PREFIX"

# 1. Terraform-managed resources.
if [ -n "$TF" ]; then
  tf init -input=false -no-color >/dev/null 2>&1 || log "terraform init failed; relying on the sweep"
  for attempt in 1 2; do
    if tf destroy -input=false -auto-approve -no-color -lock-timeout=60s; then break; fi
    log "terraform destroy attempt $attempt failed"
    [ "$attempt" = 2 ] && break
    # Out-of-band additions (rules, objects, ENIs, ...) can block the destroy: clear them, then retry.
    "$PY" "$SCRIPTS/sweep.py" "$CONFIG" || true
  done
fi

# 2. Anything scoped to the prefix that Terraform did not (or could not) remove.
log "sweeping out-of-band resources"
sweep_rc=0
"$PY" "$SCRIPTS/sweep.py" "$CONFIG" || sweep_rc=$?

# 3. Terraform state must end up empty.
if [ -n "$TF" ]; then
  if [ "$(state_count)" != 0 ]; then
    log "state still tracks resources; reconciling"
    tf destroy -input=false -auto-approve -no-color -lock-timeout=60s || true
  fi
  if [ "$(state_count)" != 0 ]; then
    log "dropping stale state entries for resources that no longer exist"
    tf state list 2>/dev/null | while read -r addr; do tf state rm "$addr" >/dev/null 2>&1 || true; done
  fi
  log "managed resources left in state: $(state_count)"
fi

if [ "$sweep_rc" != 0 ]; then
  log "sweep reported leftovers; running one more pass"
  "$PY" "$SCRIPTS/sweep.py" "$CONFIG"
fi

log "teardown complete"
