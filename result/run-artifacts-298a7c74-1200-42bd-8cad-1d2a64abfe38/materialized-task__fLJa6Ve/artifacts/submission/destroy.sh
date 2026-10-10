#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export AWS_REGION="$AWS_DEFAULT_REGION"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 30 9
python3 "$ROOT/ops.py" prepare
terraform -chdir="$ROOT/infra" init -input=false -no-color >"$ROOT/init.log" 2>&1
python3 "$ROOT/ops.py" control
# First remove untracked dependencies; canonical resources remain for Terraform.
python3 "$ROOT/ops.py" cleanup-extra
if ! terraform -chdir="$ROOT/infra" destroy -auto-approve -input=false -no-color >"$ROOT/destroy.log" 2>&1; then
  python3 "$ROOT/ops.py" report-destroy-error
  exit 1
fi
python3 "$ROOT/ops.py" cleanup
python3 "$ROOT/ops.py" empty-state
printf '%s\n' 'ClearLedger resources removed.'
