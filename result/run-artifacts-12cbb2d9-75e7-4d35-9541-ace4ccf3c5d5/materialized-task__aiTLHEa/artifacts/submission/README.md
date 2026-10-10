# ClearLedger infrastructure

Run `/workspace/submission/deploy.sh` to provision and repair the deployment.
Run `/workspace/submission/destroy.sh` to tear it down.
Both scripts read `/workspace/config/config.json` dynamically and serialize lifecycle
operations with a local lock. Terraform state lives in `infra/terraform.tfstate`.

`manifest.json` is generated and validated against the supplied JSON Schema.
Sensitive state, manifests, and Terraform diagnostic logs are owner-readable only.
The application uses the supplied precompiled image references without rebuilding.

Deployment checks its Terraform plan for destructive replacements of PostgreSQL,
DynamoDB, and S3. PostgreSQL migrations run transactionally. Reconciliation pauses
workers, locks authoritative ledger tables against concurrent writers, repairs
DynamoDB in both directions, rebuilds missing/corrupt audit batches, purges old S3
versions and delete markers, and populates canonical Valkey values with 90-second
TTLs. Workers and schedules are restored even if reconciliation raises an error.

An explicit recovery drill is available as `python3 /workspace/submission/verify.py`.
It writes test settlements, verifies OAuth scope isolation and idempotency, invokes
workers, injects drift, deletes the event queue/mapping and archiver, runs deployment,
and checks preserved durable identities and repaired data/control planes.
`python3 /workspace/submission/verify_traffic.py` additionally verifies concurrent
API writes during deployment and a final authoritative checkpoint after quiescing.

## Verified local KMS limitation

The local Floci KMS control plane implements `ScheduleKeyDeletion` but does not
provide an immediate `DeleteKey` operation or remove scheduled keys from `ListKeys`.
Teardown leaves deployment-owned keys scheduled for deletion with the configured
10-day window, and reports these residual `PendingDeletion` records. Terraform state
is empty after destruction; exact inventory equality for KMS cannot be achieved
through the supported local AWS API within the teardown timeout. No global reset
is used, and baseline resources are preserved.
