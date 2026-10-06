We need to stand up the AWS infrastructure for **ClearLedger**, an event-sourced interbank clearing and settlement ledger service, against the local AWS control plane (`http://aws:4566`). Your task is to write the Terraform or OpenTofu configuration, wire the networking, KMS keys, Cognito OAuth2 scopes, and IAM roles together, verify that the stack survives live traffic and recovery drills, and provide a clean teardown script.

The application code is already compiled into four container images. Do not rebuild or modify the application binaries—your work is strictly on the infrastructure and runtime configuration side:

1. **API service (`api_image`)**: Serves the HTTP API (`POST /v1/settlements`, `POST /v1/settlements/{id}/entries`, `GET /v1/settlements/{id}`, `GET /v1/settlements/{id}/ledger`, `POST /v1/admin/projections/{id}/rebuild`, `/health/live`, and `/health/ready`). Run this on **ECS Fargate** (`desired_count = 2` across two availability zones) behind an internet-facing **Application Load Balancer** (`port 80` listener -> HTTP target group on `port 8080` with `/health/ready` health checks).
2. **Projector (`projector_image`)**: Consumes domain events from the main **SQS** queue, writes the current settlement projection and ordered event items into **DynamoDB**, and invalidates stale cached projections in **ElastiCache for Valkey**. Deploy this as a container-based **AWS Lambda** function connected to the main SQS queue via an event source mapping (`ReportBatchItemFailures` enabled) backed by a dead-letter queue (`maxReceiveCount = 4`).
3. **Outbox relay (`relay_image`)**: Scans **Amazon RDS for PostgreSQL** for committed outbox rows (`published_at IS NULL`), publishes them to the main SQS queue, and records the delivery timestamp. Deploy this as a container-based **AWS Lambda** function triggered every minute (`rate(1 minute)`) by **EventBridge Scheduler**.
4. **Audit archiver (`archiver_image`)**: Reads published settlement events from PostgreSQL (`archived_at IS NULL`) and writes deterministic NDJSON audit batches (`ledger-audit/batch-*.ndjson`) to a private, versioned **Amazon S3** bucket. Deploy this as a container-based **AWS Lambda** function triggered every five minutes (`rate(5 minutes)`) by **EventBridge Scheduler**.

## Workspace Layout and Contracts

The environment already has `terraform`, `tofu`, `aws`, `psql`, `jq`, `curl`, and Python 3 installed, and the local AWS endpoint (`http://aws:4566`) is configured via `AWS_ENDPOINT_URL` and `/workspace/config/config.json`. Docker is intentionally unavailable inside the workspace; every cloud resource must be provisioned through Terraform or OpenTofu against the AWS control plane.

Read the specifications under `/workspace/contracts/` carefully before writing your configuration:

- `runtime.md` covers the container environment variables for the API and each Lambda worker (`DATABASE_URL`, `SQS_QUEUE_URL`, `PROJECTION_TABLE`, `VALKEY_URL`, `CACHE_TTL_SECONDS`, `OUTBOX_BATCH_SIZE`, `AUDIT_BUCKET`, `AUDIT_PREFIX`, `AUTH_ISSUER`, `AUTH_AUDIENCES`, `AUTH_JWKS_URL`, etc.), the three non-hierarchical Cognito OAuth2 scopes (`clearledger/read`, `clearledger/write`, `clearledger/admin`), and the outbox/archiver behavior.
- `infrastructure.md` and the service specs in `services/` define the two-AZ VPC (`us-east-1a` and `us-east-1b`) with public and private subnets, security groups (`alb`, `ecs`, `rds`, `valkey`), RDS PostgreSQL 16 (`db.t4g.micro`) and the required `clearledger` database schema and indexes (`services/rds.md`), SQS main queue and DLQ parameters, DynamoDB table keys (`PK`/`SK`), `AccountIndex` GSI (`GSI1PK`/`GSI1SK`), and point-in-time recovery, ElastiCache Valkey 8 (`cache.t4g.micro`), S3 bucket encryption/versioning/public-access blocks, EventBridge Scheduler targets, the six dedicated IAM roles (`ecs_execution`, `ecs_task`, `projector`, `relay`, `archiver`, `scheduler`), the four customer-managed KMS keys and aliases (`database`, `messaging`, `projection`, `audit`), and the four CloudWatch Log Groups (`retention_in_days >= 14`).
- `openapi.yaml` defines the HTTP routes, request/response schemas, required headers (`Idempotency-Key`, `X-Correlation-Id`), and response headers (`X-ClearLedger-Source`, `X-ClearLedger-Version`, `X-ClearLedger-Instance`).
- `schemas/events.schema.json` defines the canonical event envelope used on SQS and in S3 NDJSON audit batches.
- `schemas/manifest.schema.json` defines the exact schema that `/workspace/submission/manifest.json` is validated against (`additionalProperties: false` across every section).

Runtime inputs—`resource_prefix`, `region`, `aws_endpoint_url`, database credentials (`db_name`, `db_username`, `db_password`), and the four container image references and IDs—live in `/workspace/config/config.json`. Always read those values dynamically in `deploy.sh` and `destroy.sh` rather than hardcoding values from the current workspace file.

Place your deliverables in `/workspace/submission/`:

```text
/workspace/submission/
├── deploy.sh
├── destroy.sh
├── manifest.json
└── infra/
    └── *.tf (or *.tofu)
```

What each file is responsible for:

- `deploy.sh` initializes and applies the Terraform/OpenTofu configuration in `/workspace/submission/infra` with local state (`infra/terraform.tfstate`), idempotently initializes the `clearledger` PostgreSQL schema, tables, and indexes on the RDS instance (`services/rds.md`), writes `/workspace/submission/manifest.json` (max 1 MiB) from your Terraform outputs, and polls `GET /health/ready` until the service responds with HTTP 200. Re-running `deploy.sh` must converge cleanly without replacing the RDS instance or losing committed rows, reconcile any out-of-band control-plane drift (such as modified SQS queue attributes), and recreate and re-wire any resource deleted during a fault test (such as the main SQS queue and its Lambda event source mapping). Timeout: 720 seconds; max combined stdout/stderr: 8 MiB.
- `destroy.sh` destroys all AWS resources created for the current `resource_prefix` through Terraform or OpenTofu while leaving any pre-existing baseline resources untouched. Timeout: 900 seconds; max combined stdout/stderr: 8 MiB.
- `infra/` contains your `.tf` or `.tofu` files. All required AWS resources and IAM policies must be managed in `infra/terraform.tfstate`, not created imperatively via `aws` CLI commands inside shell scripts.

