# ClearLedger infrastructure

Run `./deploy.sh` to deploy or repair; run `./destroy.sh` to tear down the
active deployment. Both read `/workspace/config/config.json` on every run.
Terraform 1.9+ and the preinstalled Python boto3, psycopg2, and jsonschema
packages are used. Application images are consumed unchanged.

`infra/terraform.tfstate` tracks the cloud resources. `manifest.json` is
generated from the sensitive Terraform output and validated against the
contract schema. The manifest and state contain credentials and are written
with restricted permissions.

Deployment repairs IAM attachments and security-group egress, refreshes and
applies Terraform, installs the SQL invariants, then converges the derived
stores. A short database lock lets reads continue while writes wait during
the final reconciliation window. Schedules and the projector mapping are
restored even if reconciliation fails. Destructive replacement of RDS,
DynamoDB, or the audit bucket is rejected during deployment.

Recovery uses the actual relay and archiver workers. Invalid audit coverage
is regenerated from the committed outbox; noncurrent object versions and
delete markers are purged. Rolled-back sequence gaps are handled with
single-record worker batches. DynamoDB is repaired bidirectionally and
Valkey is repopulated with 90-second TTLs.

`python3 verify.py` runs an optional end-to-end recovery drill. It creates
a settlement, tests authorization and database transitions, introduces
control-plane drift and derived-store corruption, and verifies deployment
repair. The test settlement remains in the authoritative ledger.

Teardown quiesces workloads, purges versioned objects, destroys the managed
resources, and sweeps prefix/tag-scoped operational resources and automatic
runtime log groups. KMS keys are scheduled for deletion with the required
10-day window. Resources named `cl-base-*` are excluded from cleanup.
