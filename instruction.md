We need to stand up the AWS infrastructure for **ClearLedger**, an event-sourced interbank clearing and settlement ledger service, against the local AWS control plane (`http://aws:4566`). Your job is to write the Terraform or OpenTofu configuration, wire up the networking, KMS keys, Cognito OAuth2 scopes, and IAM roles, initialize the PostgreSQL schema and triggers, and provide deployment and teardown scripts that hold up under live traffic and recovery drills.

The application is already compiled into four container images and loaded into the local runtime. Do not rebuild or modify the application binaries. Your work is strictly on the infrastructure, database schema, and operational lifecycle side:

1. **API service (`api_image`)**: Serves the HTTP API (`POST /v1/settlements`, `POST /v1/settlements/{id}/entries`, `GET /v1/settlements/{id}`, `GET /v1/settlements/{id}/ledger`, `POST /v1/admin/projections/{id}/rebuild`, `/health/live`, and `/health/ready`). Run this on **ECS Fargate** (`desired_count = 2` across `us-east-1a` and `us-east-1b`) in private subnets behind an internet-facing **Application Load Balancer** (`port 80` HTTP listener forwarding to a target group on `port 8080` with `/health/ready` health checks).
2. **Projector (`projector_image`)**: Consumes domain events from the main **SQS** queue, writes the current settlement projection and ordered ledger event items into **DynamoDB**, and invalidates stale cached projections in **ElastiCache for Valkey**. Deploy this as a container-based **AWS Lambda** function connected to the main SQS queue via an event source mapping (`batch_size = 5`, `ReportBatchItemFailures` enabled) backed by a dead-letter queue (`maxReceiveCount = 4`).
3. **Outbox relay (`relay_image`)**: Polls **Amazon RDS for PostgreSQL** for committed outbox rows (`published_at IS NULL`), publishes them to the main SQS queue, and stamps `published_at`. Deploy this as a container-based **AWS Lambda** function triggered every minute (`rate(1 minute)`) by **EventBridge Scheduler**.
4. **Audit archiver (`archiver_image`)**: Reads published settlement events from PostgreSQL (`published_at IS NOT NULL AND archived_at IS NULL`) and writes deterministic NDJSON audit batches (`ledger-audit/batch-*.ndjson`) to a private, versioned **Amazon S3** bucket. Deploy this as a container-based **AWS Lambda** function triggered every five minutes (`rate(5 minutes)`) by **EventBridge Scheduler**.

## Workspace Environment and Contracts

The workspace comes with `terraform`, `tofu`, `aws`, `psql`, `jq`, `curl`, and Python 3 pre-installed. The local AWS control plane (`http://aws:4566`, region `us-east-1`) is configured through `AWS_ENDPOINT_URL` and `/workspace/config/config.json`. Docker is intentionally disabled inside the workspace; provision every cloud resource through Terraform or OpenTofu against the AWS endpoint.

Read the contract files under `/workspace/contracts/` before writing your code:

- `/workspace/contracts/runtime.md`: Container environment variables for the API and each Lambda worker (`DATABASE_URL`, `SQS_QUEUE_URL`, `PROJECTION_TABLE`, `VALKEY_URL`, `CACHE_TTL_SECONDS`, `OUTBOX_BATCH_SIZE`, `AUDIT_BUCKET`, `AUDIT_PREFIX`, `AUTH_ISSUER`, `AUTH_AUDIENCES`, `AUTH_JWKS_URL`, `CLOUDWATCH_LOG_GROUP`), the three non-hierarchical Cognito OAuth2 scopes (`clearledger/read`, `clearledger/write`, `clearledger/admin`), and the data-plane reconciliation rules required when `deploy.sh` runs.
- `/workspace/contracts/infrastructure.md` and `/workspace/contracts/services/*.md`: Service-by-service infrastructure requirements covering:
  - `services/vpc.md`: Two-AZ VPC (`us-east-1a` and `us-east-1b`), public and private subnets, route tables, and four least-privilege security groups (`alb`, `ecs`, `rds`, `valkey`).
  - `services/alb.md` and `services/ecs.md`: Application Load Balancer, target group, HTTP listener, ECS cluster (`containerInsights = "enabled"`), Fargate task definition, and service configuration.
  - `services/rds.md`: RDS PostgreSQL 16 (`db.t4g.micro`) instance settings and the `clearledger` schema (`settlements`, `events`, `outbox`, `idempotency_keys`), `CHECK` / `UNIQUE` / `FOREIGN KEY` constraints, PL/pgSQL triggers, and partial/composite indexes.
  - `services/sqs.md`, `services/lambda.md`, and `services/scheduler.md`: Main SQS queue and DLQ parameters, Lambda container workers, SQS event source mapping, and EventBridge Scheduler rules.
  - `services/dynamodb.md`, `services/elasticache-valkey.md`, and `services/s3.md`: DynamoDB key schema (`PK`/`SK`), `AccountIndex` GSI (`GSI1PK`/`GSI1SK`), and point-in-time recovery, ElastiCache Valkey 8 (`cache.t4g.micro`), and S3 bucket versioning, KMS encryption, public-access block, and canonical batch key layout.
  - `services/cognito.md`, `services/iam.md`, `services/kms.md`, and `services/cloudwatch-logs.md`: Cognito User Pool, resource server, and three client-credentials app clients, the six dedicated IAM roles (`ecs_execution`, `ecs_task`, `projector`, `relay`, `archiver`, `scheduler`) with both least-privilege `Allow` statements and explicit `Effect = "Deny"` guardrails, the four customer-managed KMS keys and aliases (`database`, `messaging`, `projection`, `audit`), and the four CloudWatch Log Groups (`retention_in_days >= 14`).
- `/workspace/contracts/openapi.yaml`: HTTP endpoints, request and response bodies, required request headers (`Idempotency-Key`, `X-Correlation-Id`), and response headers (`X-ClearLedger-Source`, `X-ClearLedger-Version`, `X-ClearLedger-Instance`).
- `/workspace/contracts/schemas/events.schema.json`: Domain event envelope schema used on SQS and in S3 NDJSON audit batches.
- `/workspace/contracts/schemas/manifest.schema.json`: JSON Schema for `/workspace/submission/manifest.json` (`additionalProperties: false` throughout).

Deployment inputs (`resource_prefix`, `region`, `aws_endpoint_url`, `db_name`, `db_username`, `db_password`, and the four container image tags and digests: `api_image` / `clearledger/api:1.0.0`, `projector_image` / `clearledger/projector:1.0.0`, `relay_image` / `clearledger/relay:1.0.0`, `archiver_image` / `clearledger/archiver:1.0.0`) are stored in `/workspace/config/config.json`. Read those values dynamically in `deploy.sh` and `destroy.sh` instead of hardcoding values from the current workspace.

## Deliverables and Lifecycle Rules

Write your solution under `/workspace/submission/`:

```text
/workspace/submission/
├── deploy.sh
├── destroy.sh
├── manifest.json
└── infra/
    └── *.tf (or *.tofu)
```

- `infra/`: Your Terraform or OpenTofu configuration. All required cloud resources and IAM policies must be declared here and tracked in `/workspace/submission/infra/terraform.tfstate`. Do not create scored cloud resources via imperative `aws` CLI commands in `deploy.sh`.
- `deploy.sh` (timeout: 720 seconds, max combined stdout/stderr: 8 MiB):
  - Initializes and applies `/workspace/submission/infra` with local state at `/workspace/submission/infra/terraform.tfstate`.
  - Idempotently creates the `clearledger` PostgreSQL schema, tables, relational `CHECK` / `UNIQUE` / `FOREIGN KEY` constraints, triggers, and indexes on the RDS instance as specified in `/workspace/contracts/services/rds.md`.
  - Exports `/workspace/submission/manifest.json` (max 1 MiB) from your Terraform/OpenTofu outputs matching `/workspace/contracts/schemas/manifest.schema.json`.
  - Waits until `GET <service_url>/health/ready` returns HTTP `200`.
  - Handles repair and re-apply cleanly: re-running `deploy.sh` must keep the existing RDS instance, DynamoDB table, and S3 bucket intact without losing committed data, fix out-of-band control-plane drift (across SQS/DLQ attributes, EventBridge schedules, CloudWatch Log Group retention, Lambda environment variables, out-of-band inline or attached IAM policies on the six workload roles including deleting detached `<resource_prefix>` customer-managed policies, and security group egress rules), recreate and re-wire any deleted resources (such as the SQS queues, schedules, or the projector event source mapping), drain unpublished outbox rows (`published_at IS NULL`) through `outbox_relay`, reconcile DynamoDB (`STATE`, `EVENT#*`, and `AccountIndex` GSI attributes) and actively populate Valkey cache entries (`clearledger:settlement:<settlement_id>`) 1-to-1 against `clearledger.settlements` and `clearledger.events` (deleting any orphan partitions or stray items/keys), and reconcile the versioned S3 `ledger-audit/` archive 1-to-1 against `clearledger.outbox` with contiguous, non-overlapping sequence batches through `audit_archiver` (including purging noncurrent object `Versions` and `DeleteMarkers`) before exiting `0`.
- `destroy.sh` (timeout: 900 seconds, max combined stdout/stderr: 8 MiB):
  - Tears down all resources created for the active `resource_prefix` while leaving pre-existing baseline (`cl-base-*`) resources untouched.
  - Cleans up any out-of-band operational resources or attachments scoped to `<resource_prefix>` (including inline or multi-version customer-managed IAM policies, breakglass IAM roles, non-empty versioned S3 buckets, DynamoDB tables, SQS queues, EventBridge schedules, customer-managed KMS keys/aliases, and `/clearledger/<resource_prefix>` CloudWatch Log Groups) so `terraform.tfstate` has zero remaining managed resources and post-destroy cloud inventory matches the pre-deployment baseline.
