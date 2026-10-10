#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 850 9
export TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config="$(jq -c . /workspace/config/config.json)"
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
ENGINE="${TF_ENGINE:-terraform}"
python3 "$ROOT/ops.py" teardown-prepare
"$ENGINE" -chdir="$ROOT/infra" init -no-color
"$ENGINE" -chdir="$ROOT/infra" destroy -auto-approve -no-color -compact-warnings
python3 "$ROOT/ops.py" teardown
python3 "$ROOT/ops.py" empty-state
