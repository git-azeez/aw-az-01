# ClearLedger infrastructure

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Both scripts read `/workspace/config/config.json`, serialize lifecycle operations with
`flock`, and use Terraform's local `infra/terraform.tfstate`. The pinned AWS provider
is supplied by the workspace's provider mirror. Images are used as supplied.

`manifest.json` is generated atomically from Terraform outputs and validated against
the supplied JSON Schema. It includes OAuth client secrets and is written mode 0600.

Deployment repairs KMS state and noncanonical IAM attachments before Terraform
refresh/apply, installs `schema.sql` transactionally, and waits for API readiness.
It then pauses scheduled workers and SQS consumption, briefly locks ledger writes,
publishes pending outbox rows, drains the queue, and repairs DynamoDB, Valkey and S3
against a consistent PostgreSQL snapshot. Reads remain available. Recovery purges
orphan items, corrupt audit batches, old object versions and delete markers, and
repopulates every settlement cache entry with a 90-second TTL. Workers are resumed
even when reconciliation raises an error; failed runs can be retried.

Teardown stops producers, removes deployment-scoped operational dependencies,
runs Terraform destroy, deletes active/inactive task definitions, and verifies an
empty managed state. Customer-managed KMS keys enter their 10-day deletion window.
Resources named `cl-base-*` are excluded from operational cleanup.

Optional verification (writes test settlements):

```sh
python3 /workspace/submission/verify.py
```

For a deliberate recovery drill against a disposable deployment:

```sh
python3 /workspace/submission/verify_recovery.py inject
/workspace/submission/deploy.sh
python3 /workspace/submission/verify_recovery.py check
```
