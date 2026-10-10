# ClearLedger infrastructure

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Inputs are read from `/workspace/config/config.json` on every invocation.
Terraform owns the cloud resources and policies; state is in
`infra/terraform.tfstate`. `manifest.json` contains the deployed endpoints and
OAuth clients. Lifecycle scripts serialize against `.lifecycle.lock`.

Deployment repairs the PostgreSQL schema transactionally, fences database writes
briefly for a consistent recovery snapshot, drains SQS, reconciles all projection
items and audit versions, populates the 90-second cache, and resumes workers.
Persistent-store replacements are rejected before applying a deployment plan.
Teardown removes prefix/tag-scoped out-of-band dependencies and automatic service
log groups as well as Terraform resources. KMS deletion uses its configured
10-day pending-deletion window.

Optional verification scripts (they create immutable test settlements):

- `python3 verify.py`: API writes, memo retention, OAuth boundaries, workers.
- `python3 verify_recovery.py drift`: database/control-plane/data-store corruption.
- `python3 verify_recovery.py outage`: deleted SQS queue and event source mapping.
- `python3 verify_live.py`: reapply under concurrent API writes.
- `python3 verify_teardown.py`: destructive teardown with out-of-band resources.

Operational logs are written beside the scripts. Terraform inputs, state, plans,
and the manifest contain credentials and are created with restrictive permissions.
