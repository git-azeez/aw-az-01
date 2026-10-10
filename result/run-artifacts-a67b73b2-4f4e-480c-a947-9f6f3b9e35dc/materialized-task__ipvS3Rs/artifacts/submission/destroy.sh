#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export CLEARLEDGER_CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
export TF_VAR_config_path="$CLEARLEDGER_CONFIG"
export AWS_ENDPOINT_URL="$(jq -er .aws_endpoint_url "$CLEARLEDGER_CONFIG")"
export AWS_REGION="$(jq -er .region "$CLEARLEDGER_CONFIG")"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
exec 9>"$ROOT/.lifecycle.lock"
flock -w 800 9
python3 "$ROOT/lifecycle.py" guard
terraform -chdir="$ROOT/infra" init -input=false -no-color
python3 "$ROOT/lifecycle.py" pre-destroy
terraform -chdir="$ROOT/infra" destroy -auto-approve -input=false -no-color
python3 "$ROOT/lifecycle.py" cleanup
python3 "$ROOT/lifecycle.py" empty-state
