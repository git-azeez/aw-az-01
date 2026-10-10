#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 700 9
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_PAGER=""
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export TF_IN_AUTOMATION=1
source "$ROOT/lifecycle.sh"
terraform -chdir="$ROOT/infra" init -input=false -no-color
# Apply a saved plan, refusing replacement/deletion of authoritative storage.
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out="$ROOT/infra/deploy.plan" >"$ROOT/infra/plan.log"
python3 "$ROOT/operations.py" check-plan
run_logged "$ROOT/infra/apply.log" "Terraform apply" terraform -chdir="$ROOT/infra" apply -input=false -no-color "$ROOT/infra/deploy.plan"
python3 "$ROOT/operations.py" deploy
