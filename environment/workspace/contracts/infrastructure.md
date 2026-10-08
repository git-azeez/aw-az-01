# ClearLedger Infrastructure Contract

Provision the ClearLedger clearing and settlement platform using Terraform or OpenTofu in `/workspace/submission/infra` with local state stored at `/workspace/submission/infra/terraform.tfstate`.

## Required Input Source

Read runtime inputs from `/workspace/config/config.json`:

- `resource_prefix`: unique prefix for this deployment (for example `cl-a1b2c3`)
- `region`: AWS region (`us-east-1`)
- `aws_endpoint_url`: AWS control-plane endpoint (`http://aws:4566`)
- `db_name`, `db_username`, `db_password`: PostgreSQL database name and credentials
- `api_image`, `projector_image`, `relay_image`, `archiver_image`: container image references
- `api_image_id`, `projector_image_id`, `relay_image_id`, `archiver_image_id`: image digest identifiers

Every taggable AWS resource created by your configuration must carry the tag `ClearLedgerDeployment = <resource_prefix>` (at least 25 tagged resources) and have its name or identifier prefixed with `<resource_prefix>`. All cloud resources and IAM policies must be declared in Terraform/OpenTofu (`aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_route_table`, `aws_security_group`, `aws_lb`, `aws_lb_target_group`, `aws_lb_listener`, `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_ecs_service`, `aws_db_subnet_group`, `aws_db_instance`, `aws_dynamodb_table`, `aws_elasticache_subnet_group`, `aws_elasticache_replication_group`, `aws_s3_bucket`, `aws_s3_bucket_versioning`, `aws_s3_bucket_server_side_encryption_configuration`, `aws_s3_bucket_public_access_block`, `aws_sqs_queue`, `aws_lambda_function`, `aws_lambda_event_source_mapping`, `aws_scheduler_schedule`, `aws_cognito_user_pool`, `aws_cognito_resource_server`, `aws_cognito_user_pool_client`, `aws_iam_role`, `aws_iam_role_policy`, `aws_kms_key`, `aws_kms_alias`, `aws_cloudwatch_log_group`) rather than created via imperative `aws` CLI commands in `deploy.sh`.

## Service Specifications

Read the individual service contracts in `/workspace/contracts/services/` for the exact resource attributes and wiring requirements:

- [VPC and Security Groups](services/vpc.md)
- [Application Load Balancer](services/alb.md)
- [ECS Fargate Service](services/ecs.md)
- [RDS PostgreSQL](services/rds.md)
- [SQS Main Queue and DLQ](services/sqs.md)
- [Lambda Workers and Event Source Mapping](services/lambda.md)
- [DynamoDB Projection Store](services/dynamodb.md)
- [ElastiCache for Valkey](services/elasticache-valkey.md)
- [S3 Audit Archive](services/s3.md)
- [EventBridge Scheduler](services/scheduler.md)
- [Cognito User Pool and OAuth2 Scopes](services/cognito.md)
- [IAM Roles and Least-Privilege Policies](services/iam.md)
- [Customer-Managed KMS Keys](services/kms.md)
- [CloudWatch Log Groups](services/cloudwatch-logs.md)

## Submission Scripts and Manifest

1. `/workspace/submission/deploy.sh`:
   - Must be executable and idempotent (timeout: 720s).
   - Runs `terraform` or `tofu` against `/workspace/submission/infra` with state saved at `/workspace/submission/infra/terraform.tfstate`.
   - Idempotently initializes the `clearledger` PostgreSQL schema, tables, relational `CHECK` / `UNIQUE` / `FOREIGN KEY` constraints, state-transition and append-only triggers, and indexes on the RDS instance as specified in [RDS PostgreSQL](services/rds.md).
   - Writes `/workspace/submission/manifest.json` (max 1 MiB) conforming strictly to `/workspace/contracts/schemas/manifest.schema.json`.
   - Polls `GET <service_url>/health/ready` until the API returns HTTP `200`.
   - Re-running `deploy.sh` must preserve the RDS instance, DynamoDB table, and S3 bucket without data loss, reconcile control-plane drift (across SQS/DLQ attributes, EventBridge schedule state, and Lambda worker environment variables), recreate any deleted resource (such as the main SQS queue and its Lambda event source mapping), and perform **bidirectional data-plane reconciliation** against PostgreSQL before exiting `0`:
     - Drain all pending `clearledger.outbox` rows (`published_at IS NULL`) via `outbox_relay`.
     - Purge any orphan `SETTLEMENT#<id>` items in DynamoDB and any orphan `clearledger:settlement:<id>` keys in Valkey whose settlement ID does not exist in `clearledger.settlements`.
     - Reconcile every settlement in `clearledger.settlements` against DynamoDB (`SK = STATE` and `SK = EVENT#*`) and Valkey (`clearledger:settlement:<id>`): if `SK = STATE` or any `SK = EVENT#*` item (`1..version`) is missing, has an inflated/mismatched version, has any mutated attributes (`status`, `clearing_stage`, `last_entry_id`, `last_memo`, `entry_id`, `memo`, `GSI1PK`, `GSI1SK`, etc.), or has extra phantom/stray partition items, delete the corrupted/phantom DynamoDB items, replay the settlement's ordered events from `clearledger.events` through the projector, and evict any stale or TTL-invalid Valkey cache entry.
     - Reconcile S3 (`s3://<audit_bucket>`) against `clearledger.outbox`: remove any stray objects outside `ledger-audit/`, purge any S3 batch under `ledger-audit/` that fails canonical `batch-<first_seq:08d>-<last_seq:08d>-<16_char_sha256_hex>.ndjson` key/digest validation, ascending `outbox.seq` ordering, or 1-to-1 `clearledger.outbox` payload/archival coherence, reset `archived_at = NULL` for any outbox row not present in a surviving valid S3 batch, and drain unarchived outbox rows via `audit_archiver` until `archived_at IS NULL` count is `0`.
2. `/workspace/submission/destroy.sh`:
   - Must be executable (timeout: 900s) and cleanly destroy all resources created for `resource_prefix` while leaving all pre-existing baseline (`cl-base-*`) resources untouched.
   - Before/after running `terraform destroy` or `tofu destroy`, `destroy.sh` must detach/delete any residual inline or attached customer-managed policies on `<resource_prefix>` IAM roles and sweep any out-of-band `<resource_prefix>`-prefixed IAM roles/policies, SQS queues, EventBridge Scheduler schedules, KMS aliases, or `/clearledger/<resource_prefix>` CloudWatch Log Groups so zero trial-scoped resources leak.
