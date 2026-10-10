# ClearLedger local deployment

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Both scripts dynamically read `/workspace/config/config.json`, serialize lifecycle
operations with `flock`, and use Terraform's local state in `infra/terraform.tfstate`.
The manifest is generated from Terraform outputs and validated against the contract.
Terraform progress is reported every ten seconds; detailed logs are in `infra/`.

Deployment installs `schema.sql`, repairs IAM drift, drains the outbox through the
supplied relay, and reconciles DynamoDB, Valkey, and S3 against PostgreSQL. A database
write barrier provides a consistent recovery snapshot while API reads remain
available. Schedules and the projector mapping are restored in `finally` blocks.
Storage replacement is rejected during deployment. Teardown removes scoped
operational leftovers and schedules customer-managed keys for deletion in ten days.

Optional live verification (creates test settlements):

```sh
python3 /workspace/submission/verify.py smoke
python3 /workspace/submission/verify.py corrupt
/workspace/submission/deploy.sh
python3 /workspace/submission/verify.py repaired
```

`corrupt` intentionally injects a source-preserving recovery drill; use it only when
ready to run deployment again. Application images are used as provided.

## Verified in this workspace

- Deployment, schema initialization, manifest validation, and two healthy API instances.
- OAuth scope isolation, idempotency, status progression, and append-only database guards.
- Corrupted projections/cache/archive, IAM attachments, security-group egress, queue
  attributes, Lambda environment, log retention, and deleted-resource recovery.
- Duplicate/reverse-order events and poison-message delivery to the DLQ.
- Teardown to zero managed resources and no remaining workload inventories, followed
  by successful redeployment. KMS keys enter the required ten-day deletion window.

Local-control-plane limitation: replication-group describe responses omit the cache
security-group association, despite it being explicitly declared and applied in
Terraform. The endpoint rejects standalone Redis/Valkey cluster creation, so the
working Valkey 8 replication group is retained. Some tag metadata is also omitted
on refresh, which can produce repeated in-place plans in this emulator.
