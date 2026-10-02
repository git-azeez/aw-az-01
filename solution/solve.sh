#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMISSION_DIR="/workspace/submission"

mkdir -p "${SUBMISSION_DIR}/infra"
cp "${SCRIPT_DIR}/deploy.sh" "${SUBMISSION_DIR}/deploy.sh"
cp "${SCRIPT_DIR}/destroy.sh" "${SUBMISSION_DIR}/destroy.sh"
cp "${SCRIPT_DIR}/infra/"*.tf "${SUBMISSION_DIR}/infra/"
chmod +x "${SUBMISSION_DIR}/deploy.sh" "${SUBMISSION_DIR}/destroy.sh"

"${SUBMISSION_DIR}/deploy.sh"
