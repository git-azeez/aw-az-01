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
   - Idempotently initializes the `clearledger` PostgreSQL schema, tables, relational constraints, triggers, and all six required indexes on the RDS instance as specified in [RDS PostgreSQL](services/rds.md).
   - Writes `/workspace/submission/manifest.json` (max 1 MiB) conforming strictly to `/workspace/contracts/schemas/manifest.schema.json`.
   - Polls `GET <service_url>/health/ready` until the API returns HTTP `200`.
   - Re-running `deploy.sh` must preserve the RDS instance, DynamoDB table, and S3 bucket without data loss, reconcile control-plane drift across all managed AWS resources (including KMS key state/pending-deletion cancellation/rotation/tags, RDS tags, ALB target group health check settings, ECS cluster `containerInsights`, DynamoDB `point_in_time_recovery`, S3 `PublicAccessBlock`, SQS/DLQ attributes, EventBridge Scheduler schedules, CloudWatch Log Group retention, Lambda worker environment variables, out-of-band inline or attached IAM policies on the six workload roles, and security group ingress/egress rules), recreate any missing canonical resources, event source mappings, or PostgreSQL indexes, and converge all derived data stores (DynamoDB, Valkey, and the versioned S3 audit bucket including purging noncurrent object `Versions` and `DeleteMarkers`) 1-to-1 with authoritative PostgreSQL state before exiting `0`.
2. `/workspace/submission/destroy.sh`:
   - Must be executable (timeout: 900s) and cleanly destroy all resources created for `resource_prefix` while leaving all pre-existing baseline (`cl-base-*`) resources untouched.
   - Must handle non-empty versioned S3 buckets and in-progress multipart uploads (`abort_multipart_upload`), active and inactive ECS task definitions (`deregister_task_definition` and `delete_task_definitions`), Cognito user pool domains (`delete_user_pool_domain`), IAM instance profiles (`remove_role_from_instance_profile` and `delete_instance_profile`), attached or multi-version IAM policies, and any out-of-band resources scoped to `<resource_prefix>` (by name prefix or `ClearLedgerDeployment = <resource_prefix>` tag, including customer-managed KMS keys scheduled for deletion) so that post-destroy inventory matches the pre-deployment baseline.


