#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export CLEARLEDGER_CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
export TF_VAR_config_path="$CLEARLEDGER_CONFIG"
export AWS_ENDPOINT_URL="$(jq -er .aws_endpoint_url "$CLEARLEDGER_CONFIG")"
export AWS_DEFAULT_REGION="$(jq -er .region "$CLEARLEDGER_CONFIG")"
export AWS_REGION="$AWS_DEFAULT_REGION" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
exec 9>"$ROOT/.lifecycle.lock"
flock -w 30 9
python3 "$ROOT/operations.py" cleanup-before
terraform -chdir="$ROOT/infra" init -input=false -no-color
if ! terraform -chdir="$ROOT/infra" destroy -input=false -auto-approve -no-color; then
  # The local SQS deletion waiter can lag the actual deletion. A refreshed
  # second destroy removes already-deleted queues from state and finishes KMS.
  terraform -chdir="$ROOT/infra" destroy -input=false -auto-approve -no-color
fi
python3 "$ROOT/operations.py" cleanup-after
test -z "$(terraform -chdir="$ROOT/infra" state list)"
