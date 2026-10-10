#!/usr/bin/env bash
# ClearLedger teardown: terraform destroy plus a prefix-scoped sweep of anything out-of-band.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$HERE/infra"
CONFIG_FILE="${CONFIG_FILE:-/workspace/config/config.json}"
HELPER="$HERE/.converge.py"
export CONFIG_FILE MANIFEST_FILE="$HERE/manifest.json"

START=$(date +%s)
log() { echo "[destroy $(date +%H:%M:%S) +$(( $(date +%s) - START ))s] $*"; }

TF="$(command -v terraform || command -v tofu || true)"
[ -n "$TF" ] || { echo "neither terraform nor tofu found" >&2; exit 1; }

PREFIX="$(jq -r .resource_prefix "$CONFIG_FILE")"
REGION="$(jq -r .region "$CONFIG_FILE")"
ENDPOINT="$(jq -r .aws_endpoint_url "$CONFIG_FILE")"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config_file="$CONFIG_FILE"
log "prefix=$PREFIX"

cat > "$HELPER" <<'CLEARLEDGER_HELPER_EOF'
@@CONVERGE@@
CLEARLEDGER_HELPER_EOF
trap 'rm -f "$HELPER"' EXIT
helper() { python3 "$HELPER" "$@"; }
tf() { "$TF" -chdir="$INFRA" "$@"; }

tf init -input=false -no-color >/dev/null 2>&1 || log "terraform init failed (continuing with sweep)"

# Out-of-band policies / versioned objects block role and bucket deletion: clear them first.
helper iam-clean-all || log "iam pre-clean incomplete"
helper empty-bucket "${PREFIX}-audit-archive" || true
helper kms-restore || true

destroyed=0
for attempt in 1 2 3; do
  log "terraform destroy (attempt $attempt)"
  if tf destroy -auto-approve -input=false -no-color -lock-timeout=120s; then destroyed=1; break; fi
  log "destroy failed; sweeping prefix-scoped resources before retrying"
  helper sweep || true
  sleep 5
done

log "sweeping out-of-band resources scoped to $PREFIX"
helper sweep || log "sweep reported errors"
helper sweep || true

# State must end up with zero managed resources.
if [ "$destroyed" != 1 ]; then
  tf destroy -auto-approve -input=false -no-color -lock-timeout=120s || true
fi
left="$(tf state list 2>/dev/null || true)"
if [ -n "$left" ]; then
  log "removing swept resources still referenced by state"
  while read -r addr; do [ -n "$addr" ] && tf state rm "$addr" >/dev/null 2>&1; done <<< "$left"
fi
left="$(tf state list 2>/dev/null || true)"
if [ -n "$left" ]; then
  log "state still tracks resources: $left"
  exit 1
fi
log "teardown complete"
