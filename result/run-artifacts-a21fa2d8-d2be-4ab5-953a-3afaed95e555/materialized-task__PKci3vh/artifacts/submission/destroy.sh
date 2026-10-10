#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="$(jq -er .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -er .region /workspace/config/config.json)"
export AWS_REGION="$AWS_DEFAULT_REGION" AWS_PAGER=""
exec 9>"$ROOT/.lifecycle.lock"
flock -w 30 9
python3 "$ROOT/operations.py" preflight
python3 "$ROOT/cleanup.py" before
terraform -chdir="$ROOT/infra" init -input=false -no-color
terraform -chdir="$ROOT/infra" destroy -input=false -auto-approve -no-color -compact-warnings
python3 "$ROOT/cleanup.py" after
python3 "$ROOT/operations.py" empty-state
