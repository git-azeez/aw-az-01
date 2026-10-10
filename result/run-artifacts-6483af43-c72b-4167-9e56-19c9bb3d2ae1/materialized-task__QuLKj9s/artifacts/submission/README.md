# ClearLedger operations

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Both scripts read `/workspace/config/config.json` dynamically and serialize lifecycle operations with `flock`. Infrastructure and IAM policies are declared in `infra/`; local state is `infra/terraform.tfstate`. The manifest is generated from Terraform outputs and validated against the supplied JSON Schema.

Deployment repairs KMS state and unexpected IAM policies, applies Terraform, restores the PostgreSQL constraints/triggers/indexes, and waits for readiness. Recovery pauses workers and holds a PostgreSQL write barrier while reconciling SQS, DynamoDB, the versioned audit archive, and Valkey. Reads remain available; writes resume after the barrier commits. Failed recovery exits nonzero and restores the worker triggers.

Teardown inventories prefix/tag-scoped operational dependencies, aborts multipart uploads, removes object versions and Cognito domains, detaches IAM policies/profiles, deletes active/inactive ECS task-definition revisions, and schedules KMS deletion. It verifies that no managed Terraform resources remain.

The manifest contains the OAuth client secrets required by the contract; it and state files are created with restrictive permissions. Application images are used as supplied.
