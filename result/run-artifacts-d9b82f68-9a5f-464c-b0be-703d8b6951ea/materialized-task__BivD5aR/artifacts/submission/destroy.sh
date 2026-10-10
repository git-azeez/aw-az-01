#!/usr/bin/env bash
# Tears down everything scoped to resource_prefix (baseline cl-base-* untouched).
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SELF_DIR/scripts/common.sh"

trap 'stop_proxy' EXIT

load_config
pick_tool
log "destroying ClearLedger prefix=$RESOURCE_PREFIX using $TF"

start_proxy
cd "$INFRA_DIR"
tf_init || true

state_count() {
  if [ -s "$STATE_FILE" ]; then jq '[.resources[]?] | length' "$STATE_FILE" 2>/dev/null || echo 0; else echo 0; fi
}

# 1. Things that block a clean Terraform destroy: versioned objects, delete markers,
#    out-of-band policies attached to the workload roles, unattached managed policies.
log "pre-clean: audit bucket versions, out-of-band IAM policies"
python3 "$SUB_DIR/scripts/sweep.py" pre --config "$CONFIG_FILE" || true

# 2. Terraform destroy (state may be missing or partially applied; keep going regardless)
if [ "$(state_count)" -gt 0 ]; then
  for attempt in 1 2 3; do
    log "terraform destroy (attempt $attempt)"
    if tf destroy -input=false -auto-approve -no-color -lock-timeout=60s; then break; fi
    python3 "$SUB_DIR/scripts/sweep.py" pre --config "$CONFIG_FILE" || true
    sleep 5
  done
fi

# 3. Sweep everything scoped to the prefix that Terraform did not manage or could not remove.
log "sweeping out-of-band resources scoped to $RESOURCE_PREFIX"
python3 "$SUB_DIR/scripts/sweep.py" post --config "$CONFIG_FILE" || true

# 4. If anything is still in state (e.g. the first destroy aborted), converge the state now
#    that the sweep removed the real resources.
if [ "$(state_count)" -gt 0 ]; then
  log "reconciling remaining Terraform state"
  tf destroy -input=false -auto-approve -no-color -lock-timeout=60s || true
fi
if [ "$(state_count)" -gt 0 ]; then
  log "removing stale state entries for resources that no longer exist"
  # shellcheck disable=SC2046
  tf state rm $(tf state list) >/dev/null || true
fi

# Final pass in case the second destroy released more dependencies
python3 "$SUB_DIR/scripts/sweep.py" post --config "$CONFIG_FILE" || true

REMAINING="$(state_count)"
[ "$REMAINING" -eq 0 ] || die "$REMAINING resources still tracked in terraform.tfstate"
rm -f "$MANIFEST_FILE"
log "destroy complete: terraform.tfstate has zero managed resources"
