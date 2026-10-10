#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="$(jq -er .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -er .region /workspace/config/config.json)"
export TF_IN_AUTOMATION=1
exec 9>"$ROOT/.lifecycle.lock"
flock -w 30 9
heartbeat() { while sleep 20; do printf 'Teardown is still running...\n'; done; }
heartbeat 9>&- & pulse=$!
trap 'kill "$pulse" 2>/dev/null || true' EXIT
printf 'Removing ClearLedger infrastructure and prefix-scoped operational resources...\n'
jq '{config: .}' /workspace/config/config.json > "$ROOT/infra/runtime.auto.tfvars.json"
python3 "$ROOT/operations.py" prepare
terraform -chdir="$ROOT/infra" init -input=false -no-color > "$ROOT/infra/init.log" 2>&1
python3 "$ROOT/cleanup.py" extras
if ! terraform -chdir="$ROOT/infra" destroy -auto-approve -input=false -no-color > "$ROOT/infra/destroy.log" 2>&1; then
  python3 "$ROOT/cleanup.py" all
  terraform -chdir="$ROOT/infra" destroy -auto-approve -input=false -no-color >> "$ROOT/infra/destroy.log" 2>&1 || { cat "$ROOT/infra/destroy.log"; exit 1; }
fi
python3 "$ROOT/cleanup.py" all
test -z "$(terraform -chdir="$ROOT/infra" state list)"
printf 'ClearLedger teardown complete; Terraform state contains no managed resources.\n'
