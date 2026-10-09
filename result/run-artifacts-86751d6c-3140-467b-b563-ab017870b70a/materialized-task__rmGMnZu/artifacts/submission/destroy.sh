#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
export AWS_REGION="$(jq -r .region /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 30 9
python3 "$ROOT/operations.py" dependencies
terraform -chdir="$ROOT/infra" init -input=false -no-color
python3 "$ROOT/operations.py" before-destroy
terraform -chdir="$ROOT/infra" destroy -auto-approve -input=false -no-color
python3 "$ROOT/operations.py" cleanup
python3 "$ROOT/operations.py" empty-state
