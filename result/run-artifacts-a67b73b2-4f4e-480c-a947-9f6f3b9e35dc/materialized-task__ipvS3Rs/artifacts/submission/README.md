# ClearLedger infrastructure

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Inputs are read on every run from `/workspace/config/config.json`; optionally
set `CLEARLEDGER_CONFIG` to another configuration file. Terraform 1.9+ and the
preinstalled Python packages (`boto3`, `psycopg2`, `redis`, `requests`, and
`jsonschema`) are used. Container images are used directly from the supplied
configuration.

## Deployment and recovery

Terraform owns cloud provisioning and local state in `infra/terraform.tfstate`.
The deployment plan is checked for destructive changes to RDS, DynamoDB, or S3
before application. `schema.sql` installs database constraints and append-only,
cross-table, and lifecycle triggers transactionally and idempotently.

Deployment exports and validates `manifest.json`, waits for readiness, removes
unexpected workload IAM policies and insecure datastore egress, then reconciles
derived stores from PostgreSQL. Existing workers publish unpublished outbox
rows and regenerate invalid audit archives. Valid archive batches are retained;
noncurrent versions and delete markers are permanently purged. DynamoDB items
and GSI attributes are replaced when divergent, orphan items are removed, and
all authoritative settlement projections are cached with a 90-second TTL.

During final convergence, schedules and the projector mapping are temporarily
paused. A bounded PostgreSQL aggregate-write barrier prevents racing writes
while the authoritative snapshot converges; reads continue, and pending writes
resume after the barrier is released. Backlog is processed before cache
population. Triggers are restored in a `finally` block. Both lifecycle scripts
share a filesystem lock.

## Teardown

Teardown removes operational attachments, policy versions, versioned bucket
contents, and prefix/tag-scoped drift resources, destroys Terraform resources,
then sweeps remaining operational resources and verifies zero managed instances
in state. Automatically generated runtime log groups and local-control-plane
default networking remnants are included. Recorded VPC ownership scopes those
remnants safely. The `cl-base-*` namespace is excluded from cleanup. KMS keys
are scheduled for deletion with the required ten-day window.

`manifest.json` contains OAuth client secrets and Terraform state contains
database credentials; lifecycle-generated files use private permissions.
