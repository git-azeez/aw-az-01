#!/usr/bin/env bash
set -uo pipefail

# ClearLedger Verifier Suite — 19 Scored Test Blocks (100 Points Total)
# 1. Core product behavior (24 pts) — suite/test_functional.py:
#    - Settlement workflow (9 pts): test_settlement_lifecycle_workflow [functional.workflow]
#    - Projection and cache (7 pts): test_projection_and_valkey_cache [functional.cache]
#    - Idempotency and concurrency (8 pts): test_idempotency_and_optimistic_concurrency [functional.idempotency_concurrency]
# 2. Recovery (20 pts) — suite/test_recovery.py:
#    - Outbox recovery (6 pts): test_outbox_recovery_after_sqs_queue_deletion [recovery.outbox_recovery]
#    - Projection rebuild (5 pts): test_projection_rebuild_from_event_log [recovery.projection_rebuild]
#    - ECS task replacement (5 pts): test_ecs_task_failure_replacement [recovery.ecs_task_replacement]
#    - RDS reboot recovery (4 pts): test_rds_reboot_recovery [recovery.rds_reboot]
# 3. Architecture and deployment (17 pts) — suite/test_declared.py & suite/test_live.py:
#    - Infrastructure managed with Terraform or OpenTofu (3 pts): test_iac_discipline [declared.iac_discipline]
#    - Declared compute and ingress (2 pts): test_declared_compute_and_ingress [declared.compute_ingress]
#    - Declared data and messaging (2 pts): test_declared_data_and_async [declared.data_async]
#    - Live ingress and compute (5 pts): test_live_compute_and_ingress [live.compute_ingress]
#    - Live data and event graph (5 pts): test_live_data_and_event_graph [live.data_event_graph]
# 4. Lifecycle (15 pts) — suite/test_lifecycle.py:
#    - Stable deployment (7 pts): test_reapply_idempotence [lifecycle.reapply_idempotence]
#    - Clean destroy (8 pts): test_destroy_clean [lifecycle.clean_destroy]
# 5. Asynchronous processing (13 pts) — suite/test_async.py:
#    - Backlog recovery (7 pts): test_backlog_accumulation_and_drain [async.backlog_recovery]
#    - Duplicate and invalid messages (6 pts): test_duplicate_delivery_and_dlq_isolation [async.duplicate_and_dlq]
# 6. Security and observability (11 pts) — suite/test_declared.py, suite/test_live.py, suite/test_security.py:
#    - Declared security (3 pts): test_declared_security [declared.security]
#    - Live security graph (5 pts): test_live_security [live.security]
#    - Authorization, audit and logs (3 pts): test_authorization_audit_and_observability [security.auth_audit_logs]
# Hard gates / score caps: accepted_write_loss (49), auth_escalation (49), cleanup_leak (79)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://aws:4566}"
export TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE:-/etc/terraform.tfrc}"

mkdir -p /logs/verifier /workspace/evidence

echo "0" >/logs/verifier/reward.txt

pytest -q \
  "${SCRIPT_DIR}/suite/test_declared.py" \
  "${SCRIPT_DIR}/suite/test_live.py" \
  "${SCRIPT_DIR}/suite/test_functional.py" \
  "${SCRIPT_DIR}/suite/test_async.py" \
  "${SCRIPT_DIR}/suite/test_recovery.py" \
  "${SCRIPT_DIR}/suite/test_security.py" \
  "${SCRIPT_DIR}/suite/test_lifecycle.py" \
  -o cache_dir=/tmp/pytest_cache \
  --junitxml=/logs/verifier/junit.xml
PYTEST_RC=$?

if [[ -f /logs/verifier/results.json ]]; then
  cp /logs/verifier/results.json /workspace/evidence/verifier_results.json || true
fi

exit "${PYTEST_RC}"
