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
heartbeat() { while sleep 20; do printf 'Deployment is still running...\n'; done; }
heartbeat 9>&- & pulse=$!
trap 'kill "$pulse" 2>/dev/null || true' EXIT
printf 'Applying ClearLedger infrastructure...\n'
jq '{config: .}' /workspace/config/config.json > "$ROOT/infra/runtime.auto.tfvars.json"
python3 "$ROOT/operations.py" prepare
terraform -chdir="$ROOT/infra" init -input=false -no-color > "$ROOT/infra/init.log" 2>&1
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out=deployment.plan > "$ROOT/infra/plan.log" 2>&1 || { cat "$ROOT/infra/plan.log"; exit 1; }
terraform -chdir="$ROOT/infra" show -json deployment.plan | python3 -c '
import json,sys
p=json.load(sys.stdin)
for r in p.get("resource_changes",[]):
    if r["type"] in ("aws_db_instance","aws_dynamodb_table","aws_s3_bucket") and "delete" in r["change"]["actions"]:
        sys.exit("Refusing destructive replacement of authoritative or durable store: " + r["address"])
'
terraform -chdir="$ROOT/infra" apply -input=false -no-color deployment.plan > "$ROOT/infra/apply.log" 2>&1 || { cat "$ROOT/infra/apply.log"; exit 1; }
terraform -chdir="$ROOT/infra" output -json manifest > "$ROOT/manifest.json.tmp"
python3 "$ROOT/operations.py" manifest
mv "$ROOT/manifest.json.tmp" "$ROOT/manifest.json"
python3 "$ROOT/operations.py" schema
python3 "$ROOT/operations.py" reconcile
python3 "$ROOT/operations.py" ready
printf 'ClearLedger deployed and reconciled. Manifest: %s/manifest.json\n' "$ROOT"
