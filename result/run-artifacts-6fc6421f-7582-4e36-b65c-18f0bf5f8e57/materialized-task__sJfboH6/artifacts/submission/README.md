# ClearLedger local infrastructure

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Both scripts read `/workspace/config/config.json` dynamically. Set
`CLEARLEDGER_CONFIG` to use another configuration file. Terraform 1.9+ and the
cached AWS provider 6.51.0 are used; application images are never rebuilt.

`manifest.json` is exported from Terraform and validated against the supplied
JSON Schema. The local ALB serves `http://aws:80`. State is maintained in
`infra/terraform.tfstate`. Manifest and state contain credentials and are
written with restrictive permissions.

Deployment repairs PostgreSQL constraints, triggers, and indexes transactionally.
Reconciliation pauses derived writers, takes a bounded PostgreSQL write lock,
drains SQS, repairs divergent DynamoDB items using the supplied projector,
validates and repairs audit batches and object versions, and warms all canonical
Valkey projections with a 90-second TTL. Worker schedules and the event source
mapping are restored in a `finally` block. Durable store replacement is rejected
by the deployment plan check.

Teardown removes policy attachments, empties versioned buckets, avoids the local
SQS deletion-waiter stall, destroys Terraform resources, and sweeps operational
resources and generated log groups by deployment prefix or tag. KMS keys follow
the required AWS deletion lifecycle: aliases are deleted and keys enter
`PendingDeletion` with a 10-day window. Subsequent deployment does not reactivate
keys from a completed teardown.

Optional local verification (commits a verification settlement):

```sh
python3 /workspace/submission/verify.py
python3 /workspace/submission/verify_recovery.py inject
/workspace/submission/deploy.sh
python3 /workspace/submission/verify_recovery.py check
```
