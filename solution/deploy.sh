#!/usr/bin/env bash
set -euo pipefail

unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
export NO_PROXY="localhost,127.0.0.1,::1,aws,runtime"
export no_proxy="localhost,127.0.0.1,::1,aws,runtime"

CONFIG_FILE="/workspace/config/config.json"
SUBMISSION_DIR="/workspace/submission"
INFRA_DIR="${SUBMISSION_DIR}/infra"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
TFVARS_FILE="${INFRA_DIR}/config.auto.tfvars.json"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing ${CONFIG_FILE}" >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
  IAC_BIN="tofu"
else
  echo "Neither terraform nor tofu is available" >&2
  exit 1
fi

export AWS_REGION="$(jq -r '.region' "${CONFIG_FILE}")"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_ENDPOINT_URL="$(jq -r '.aws_endpoint_url' "${CONFIG_FILE}")"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export TF_IN_AUTOMATION=1

cp "${CONFIG_FILE}" "${TFVARS_FILE}"

pushd "${INFRA_DIR}" >/dev/null

"${IAC_BIN}" init -input=false -no-color >/dev/null

"${IAC_BIN}" apply \
  -input=false \
  -auto-approve \
  -no-color \
  -state="${STATE_FILE}"

"${IAC_BIN}" output \
  -json \
  -state="${STATE_FILE}" \
  manifest >"${MANIFEST_FILE}.tmp"

mv "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"
popd >/dev/null

SERVICE_URL="$(jq -r '.service_url' "${MANIFEST_FILE}")"
READY_URL="${SERVICE_URL%/}/health/ready"

for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 "${READY_URL}" >/dev/null 2>&1; then
    echo "ClearLedger deployment ready at ${SERVICE_URL}"
    exit 0
  fi
  sleep 2
done

echo "Service did not become ready at ${READY_URL}" >&2
exit 1
