# ClearLedger local deployment

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Both scripts read `/workspace/config/config.json`, serialize lifecycle operations
with `flock`, and use the local Terraform state in `infra/terraform.tfstate`.
The deployment writes a schema-validated `manifest.json`, including OAuth client
credentials. Generated credentials, state, plans, and logs are restricted by
`umask 077`.

`schema.sql` repairs relational constraints, enabled triggers, and indexes in a
single transaction. Recovery temporarily disables the worker triggers and takes
database table locks in aggregate/event/outbox order. Writes wait during the
bounded reconciliation window. PostgreSQL remains authoritative: derived items
are replaced exactly, stray items are removed, valid audit batches are retained,
and obsolete S3 versions and delete markers are permanently removed. The cache
is populated with canonical projections and a 90-second TTL. Worker triggers
are restored in a `finally` block. A failed operation can be safely rerun.

The teardown removes prefix/tag-scoped operational resources, policy attachments
and policy versions, then verifies an empty Terraform state. Baseline names
containing `cl-base-` are excluded from operational cleanup.

`python3 /workspace/submission/verify.py` runs an explicit live smoke test and a
destructive derived-store/control-plane drift drill, retaining its committed
test settlement in PostgreSQL. It is not run by the deployment script.
