# ClearLedger Runtime and Application Contract

All four application images are pre-built and loaded into the local container daemon. Do not rebuild or modify the application binaries. Configure each runtime using the environment variables below.

## 1. API Service (`api_image` on ECS Fargate)

- **Binary**: `/usr/local/bin/clearledger-api`
- **Listening port**: `8080` (`PORT=8080`)
- **Required environment variables**:
  - `PORT`: `"8080"`
  - `AWS_REGION`: region from `config.json` (`us-east-1`)
  - `AWS_DEFAULT_REGION`: region from `config.json` (`us-east-1`)
  - `AWS_ACCESS_KEY_ID`: `"test"`
  - `AWS_SECRET_ACCESS_KEY`: `"test"`
  - `AWS_ENDPOINT_URL`: control-plane endpoint reachable from the container (`http://aws:4566`)
  - `DATABASE_URL`: PostgreSQL connection string `postgres://<db_username>:<db_password>@<rds_host>:<rds_port>/<db_name>`
  - `SQS_QUEUE_URL`: URL of the main SQS event queue
  - `PROJECTION_TABLE`: name of the DynamoDB projection table
  - `VALKEY_URL`: Valkey connection URL `redis://<valkey_host>:<valkey_port>`
  - `CACHE_TTL_SECONDS`: `"90"` (must be explicitly set to `"90"`)
  - `AUTH_ISSUER`: Cognito issuer URL (`http://aws:4566/<user_pool_id>`)
  - `AUTH_AUDIENCES`: comma-separated Cognito client IDs (`<read_client_id>,<write_client_id>,<admin_client_id>`)
  - `AUTH_JWKS_URL`: Cognito JWKS URL (`http://aws:4566/<user_pool_id>/.well-known/jwks.json`)
  - `CLOUDWATCH_LOG_GROUP`: name of the API CloudWatch Log Group
  - `SERVICE_INSTANCE_ID` (optional): instance identifier returned in `X-ClearLedger-Instance` (defaults to `HOSTNAME`)

Upon startup, `clearledger-api` connects to PostgreSQL and serves HTTP traffic on `0.0.0.0:8080`. The application binaries do **not** run database migrations automatically: `deploy.sh` must idempotently apply the `clearledger` PostgreSQL schema (`clearledger.settlements`, `clearledger.events`, `clearledger.outbox`, `clearledger.idempotency_keys`), all required `CHECK` and `FOREIGN KEY` constraints, and its three indexes as defined in `services/rds.md` before `GET /health/ready` reports `200 OK` (`checks.postgres = "UP"`). During `POST /v1/settlements` and `POST /v1/settlements/{id}/entries`, `clearledger-api` maps PostgreSQL constraint violations (`SQLSTATE 23514` / `23503`, such as `debit_party = credit_party`) to HTTP `400 Bad Request` (`invalid_settlement`).

## 2. Projector Worker (`projector_image` on AWS Lambda)

- **Bootstrap**: `/var/runtime/bootstrap`
- **Trigger**: SQS event source mapping from the main SQS queue (`batch_size = 5`, `maximum_batching_window_in_seconds = 0`, `function_response_types = ["ReportBatchItemFailures"]`)
- **Required environment variables**:
  - `AWS_REGION`: region from `config.json`
  - `AWS_DEFAULT_REGION`: region from `config.json`
  - `AWS_ACCESS_KEY_ID`: `"test"`
  - `AWS_SECRET_ACCESS_KEY`: `"test"`
  - `AWS_ENDPOINT_URL`: `"http://aws:4566"`
  - `PROJECTION_TABLE`: name of the DynamoDB projection table
  - `VALKEY_URL`: `redis://<valkey_host>:<valkey_port>`
  - `CLOUDWATCH_LOG_GROUP`: name of the projector CloudWatch Log Group

For each valid event envelope in the SQS batch:
- Upserts the event item (`PK = "SETTLEMENT#<settlement_id>"`, `SK = "EVENT#<8-digit-zero-padded-version>"`) in DynamoDB.
- Updates the aggregate state item (`PK = "SETTLEMENT#<settlement_id>"`, `SK = "STATE"`, `GSI1PK = "ACCOUNT#<account_id>"`, `GSI1SK = "SETTLEMENT#<settlement_id>"`) when `aggregateVersion` is greater than the stored `version`. Duplicate or older versions are ignored idempotently; if an older version (such as `v1`) arrives after a newer version, any missing static metadata (`reference`, `debit_party`, `credit_party`) is backfilled without regressing `version`, `status`, or `clearing_stage`.
- Deletes the Valkey key `clearledger:settlement:<settlement_id>`.
- If any record fails validation or deserialization, its `messageId` is returned in `batchItemFailures` so SQS retries only the failed message and routes poison messages to the DLQ after `maxReceiveCount = 4` receives.

## 3. Outbox Relay Worker (`relay_image` on AWS Lambda)

- **Bootstrap**: `/var/runtime/bootstrap`
- **Trigger**: EventBridge Scheduler every 1 minute (`rate(1 minute)`)
- **Required environment variables**:
  - `AWS_REGION`: region from `config.json`
  - `AWS_DEFAULT_REGION`: region from `config.json`
  - `AWS_ACCESS_KEY_ID`: `"test"`
  - `AWS_SECRET_ACCESS_KEY`: `"test"`
  - `AWS_ENDPOINT_URL`: `"http://aws:4566"`
  - `DATABASE_URL`: `postgres://<db_username>:<db_password>@<rds_host>:<rds_port>/<db_name>`
  - `SQS_QUEUE_URL`: URL of the main SQS event queue
  - `OUTBOX_BATCH_SIZE`: `"50"` (must be explicitly set to `"50"`)
  - `CLOUDWATCH_LOG_GROUP`: name of the relay CloudWatch Log Group

Queries up to `OUTBOX_BATCH_SIZE` rows from `clearledger.outbox` where `published_at IS NULL` ordered by `seq ASC`, sends each event envelope to `SQS_QUEUE_URL`, and updates `published_at = NOW()` and `attempts = attempts + 1`.

## 4. Audit Archiver Worker (`archiver_image` on AWS Lambda)

- **Bootstrap**: `/var/runtime/bootstrap`
- **Trigger**: EventBridge Scheduler every 5 minutes (`rate(5 minutes)`)
- **Required environment variables**:
  - `AWS_REGION`: region from `config.json`
  - `AWS_DEFAULT_REGION`: region from `config.json`
  - `AWS_ACCESS_KEY_ID`: `"test"`
  - `AWS_SECRET_ACCESS_KEY`: `"test"`
  - `AWS_ENDPOINT_URL`: `"http://aws:4566"`
  - `DATABASE_URL`: `postgres://<db_username>:<db_password>@<rds_host>:<rds_port>/<db_name>`
  - `AUDIT_BUCKET`: name of the S3 audit archive bucket
  - `AUDIT_PREFIX`: `"ledger-audit/"` (must be explicitly set to `"ledger-audit/"`)
  - `AUDIT_BATCH_SIZE` (optional): defaults to `100`
  - `CLOUDWATCH_LOG_GROUP`: name of the archiver CloudWatch Log Group

Selects published outbox rows (`published_at IS NOT NULL AND archived_at IS NULL`) ordered by `seq ASC`, writes a newline-delimited JSON object to `s3://<AUDIT_BUCKET>/ledger-audit/batch-<first_seq>-<last_seq>-<sha256_prefix>.ndjson`, and sets `archived_at = NOW()`.

## 5. OAuth2 Scopes and Authorization

All protected endpoints validate Bearer JWTs issued by the Cognito User Pool against `AUTH_ISSUER`, `AUTH_JWKS_URL`, and `AUTH_AUDIENCES`. Scopes are strictly non-hierarchical:

- `clearledger/read`: permitted only on `GET /v1/settlements/{id}` and `GET /v1/settlements/{id}/ledger`.
- `clearledger/write`: permitted only on `POST /v1/settlements` and `POST /v1/settlements/{id}/entries`.
- `clearledger/admin`: permitted only on `POST /v1/admin/projections/{id}/rebuild`.

Missing or invalid tokens return `401 Unauthorized`; valid tokens lacking the exact endpoint scope return `403 Forbidden`.

## 6. Recovery Drills, Data-Plane Convergence, and Lifecycle

- **Backlog & DLQ**: When the projector event source mapping is disabled, API writes commit to PostgreSQL and enqueue on SQS while `GET /v1/settlements/{id}` returns `404` until re-enabled. Duplicate, out-of-order, and concurrent event deliveries are handled without version regression; invalid envelopes are retried and routed to the DLQ after `maxReceiveCount = 4`.
- **Self-Healing Outbox, Projection, Cache, and Archive Convergence in `deploy.sh`**:
  - If the main SQS queue and/or projector event source mapping are deleted during an outage, `POST /v1/settlements` and `POST /v1/settlements/{id}/entries` still commit to `clearledger.settlements`, `clearledger.events`, and `clearledger.outbox` (`published_at IS NULL`).
  - Furthermore, during outage or drift drills, control-plane settings (SQS/DLQ attributes, EventBridge schedule state, Lambda environment variables) may be mutated, and existing settlements may have their DynamoDB `STATE` projection deleted/regressed or their Valkey cache entry (`clearledger:settlement:<id>`) poisoned with a stale version.
  - Before `deploy.sh` exits `0`, it must not only converge the Terraform/OpenTofu control plane and update `manifest.json`, but also **reconcile the data plane**:
    1. Drain all unpublished outbox rows (`published_at IS NULL`) via `outbox_relay` until `published_at IS NULL` count is `0`.
    2. Reconcile every settlement in `clearledger.settlements` against DynamoDB (`PK = SETTLEMENT#<id>`, `SK = STATE` **and** `SK = EVENT#<8-digit-zero-padded-version>`) and Valkey (`clearledger:settlement:<id>`) so that whenever the DynamoDB `STATE` projection is missing/lagging (`version < pg_version`) **or** any `EVENT#*` ledger item (`1..pg_version`) is missing, the settlement's ordered events from `clearledger.events` are replayed through the projector and any stale Valkey cache entry is evicted.
    3. Drain all unarchived outbox rows (`published_at IS NOT NULL AND archived_at IS NULL`) via `audit_archiver` so every published event is persisted into an S3 NDJSON batch under `s3://<AUDIT_BUCKET>/<AUDIT_PREFIX>` and `archived_at IS NULL` count is `0`.
- **Prefix-Scoped Teardown in `destroy.sh`**:
  - During operational drills, out-of-band resources scoped to `<resource_prefix>` (such as inline diagnostic policies attached to `<resource_prefix>` IAM roles, `<resource_prefix>-*` SQS queues, or `/clearledger/<resource_prefix>/*` CloudWatch Log Groups) may exist outside Terraform state.
  - `destroy.sh` must detach/delete any residual inline or attached policies on `<resource_prefix>` IAM roles before role deletion, destroy all Terraform-managed resources, and sweep any remaining `<resource_prefix>`-prefixed or `ClearLedgerDeployment=<resource_prefix>`-tagged resources while keeping all `cl-base-*` baseline resources intact.
- **Structured Logs**: All four workloads emit JSON log lines containing `correlationId` (propagated from `X-Correlation-Id`) to their configured CloudWatch Log Groups without leaking `db_password` or Cognito `client_secret` values.
