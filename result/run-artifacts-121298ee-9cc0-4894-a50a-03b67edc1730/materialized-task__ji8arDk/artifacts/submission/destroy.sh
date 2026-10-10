#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_REGION="$(jq -r .region /workspace/config/config.json)" AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export TF_VAR_config="$(jq -c . /workspace/config/config.json)"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 850 9
terraform -chdir="$ROOT/infra" init -input=false -no-color
python3 "$ROOT/ops.py" quiesce
python3 "$ROOT/ops.py" cleanup-extra
terraform -chdir="$ROOT/infra" plan -destroy -input=false -no-color -out="$ROOT/infra/destroy.tfplan" >"$ROOT/infra/destroy-plan.log"
terraform -chdir="$ROOT/infra" apply -input=false -no-color "$ROOT/infra/destroy.tfplan"
python3 "$ROOT/ops.py" cleanup-all
test -z "$(terraform -chdir="$ROOT/infra" state list)"
