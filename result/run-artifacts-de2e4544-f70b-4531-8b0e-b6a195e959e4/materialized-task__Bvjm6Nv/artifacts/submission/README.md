# ClearLedger infrastructure

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Both commands read `/workspace/config/config.json` on every invocation and serialize
execution with a lifecycle lock. Terraform owns the cloud resources and policies;
its local state is `infra/terraform.tfstate`. The generated, schema-validated
`manifest.json` contains endpoints and OAuth client credentials (mode `0600`).

Deployment applies a transactionally enforced PostgreSQL schema, restores
out-of-band IAM policies and key state, then pauses worker triggers for a bounded
reconciliation window. A database write barrier provides a consistent authoritative
snapshot while projections, orphan items, cache contents, archive objects, old
versions, and delete markers are repaired. Worker triggers resume in a `finally`
block. Concurrent API writes wait at the database barrier and continue afterward.
Persistent RDS, DynamoDB, and S3 replacement plans are rejected rather than losing
data. Terraform diagnostics are retained in `terraform.log`.

Teardown removes prefix/tag-scoped untracked resources before Terraform destruction,
then sweeps residual resources and verifies an empty managed state. AWS KMS keys
use the required ten-day scheduled deletion window.

## Verification

```sh
python3 /workspace/submission/verify.py
python3 /workspace/submission/verify_recovery.py
```

The first command creates a labelled settlement and checks OAuth isolation,
idempotency, transitions, omitted-memo retention, projection, and archival. The
second deliberately corrupts derived data and selected infrastructure/schema
settings, deletes the queue and mapping, runs deployment, and checks recovery
without changing authoritative event history.

Verified locally: deployment/readiness, live API integration, repair drill,
teardown to zero Terraform-managed resources, and fresh redeployment.
