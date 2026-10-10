#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 880 9
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_PAGER=""
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export TF_IN_AUTOMATION=1
source "$ROOT/lifecycle.sh"
terraform -chdir="$ROOT/infra" init -input=false -no-color
python3 "$ROOT/operations.py" pre-destroy
run_logged "$ROOT/infra/destroy.log" "Terraform destroy" terraform -chdir="$ROOT/infra" destroy -auto-approve -input=false -no-color
python3 "$ROOT/operations.py" post-destroy
