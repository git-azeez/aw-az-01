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

Upon startup, `clearledger-api` connects to PostgreSQL and serves HTTP traffic on `0.0.0.0:8080`. The application binaries do **not** run database migrations automatically: `deploy.sh` must idempotently apply the `clearledger` PostgreSQL schema (`clearledger.settlements`, `clearledger.events`, `clearledger.outbox`, `clearledger.idempotency_keys`), all required relational `CHECK` / `UNIQUE` / `FOREIGN KEY` constraints, all state-transition, cross-table, and append-only triggers across all four tables, and its three indexes as defined in `services/rds.md` before `GET /health/ready` reports `200 OK` (`checks.postgres = "UP"`). During `POST /v1/settlements` and `POST /v1/settlements/{id}/entries`, `clearledger-api` maps PostgreSQL constraint and trigger exceptions (`SQLSTATE 23514`, `23503`, `23502`, `23505`, and `P0001`) to HTTP `400 Bad Request` (`invalid_settlement`).

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
- Inserts the event item (`PK = "SETTLEMENT#<settlement_id>"`, `SK = "EVENT#<8-digit-zero-padded-version>"`) in DynamoDB using a conditional `attribute_not_exists(PK) AND attribute_not_exists(SK)` write.
- Updates the aggregate state item (`PK = "SETTLEMENT#<settlement_id>"`, `SK = "STATE"`, `GSI1PK = "ACCOUNT#<account_id>"`, `GSI1SK = "SETTLEMENT#<settlement_id>"`) using a conditional write only when `aggregateVersion` is strictly greater than the stored `version`. Duplicate or older versions are ignored idempotently; if an older version (such as `v1`) arrives after a newer version, any missing static metadata (`reference`, `debit_party`, `credit_party`) is backfilled without regressing `version`, `status`, or `clearing_stage`.
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

Queries up to `OUTBOX_BATCH_SIZE` rows from `clearledger.outbox` where `published_at IS NULL` ordered by `seq ASC`, sends each event envelope to `SQS_QUEUE_URL`, and updates `published_at = NOW(), attempts = attempts + 1, last_error = NULL`.

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

Selects published outbox rows (`published_at IS NOT NULL AND archived_at IS NULL`) ordered by `seq ASC`, writes a newline-delimited JSON object to `s3://<AUDIT_BUCKET>/ledger-audit/batch-<first_seq:08d>-<last_seq:08d>-<16_char_sha256_hex>.ndjson`, and sets `archived_at = NOW()`.

## 5. OAuth2 Scopes and Authorization

All protected endpoints validate Bearer JWTs issued by the Cognito User Pool against `AUTH_ISSUER`, `AUTH_JWKS_URL`, and `AUTH_AUDIENCES`. Scopes are strictly non-hierarchical:

- `clearledger/read`: permitted only on `GET /v1/settlements/{id}` and `GET /v1/settlements/{id}/ledger`.
- `clearledger/write`: permitted only on `POST /v1/settlements` and `POST /v1/settlements/{id}/entries`.
- `clearledger/admin`: permitted only on `POST /v1/admin/projections/{id}/rebuild`.

Missing or invalid tokens return `401 Unauthorized`; valid tokens lacking the exact endpoint scope return `403 Forbidden`.

## 6. Recovery Drills, Bidirectional Data-Plane Reconciliation, and Lifecycle

- **Backlog & DLQ**: When the projector event source mapping is disabled, API writes commit to PostgreSQL and enqueue on SQS while `GET /v1/settlements/{id}` returns `404` until re-enabled. Duplicate, out-of-order, and concurrent event deliveries are handled without version regression; invalid envelopes are retried and routed to the DLQ after `maxReceiveCount = 4`.
- **Bidirectional Multi-Store Convergence in `deploy.sh`**:
  - PostgreSQL (`clearledger.settlements`, `clearledger.events`, `clearledger.outbox`) is the authoritative system of record; DynamoDB, Valkey, and S3 are derived read/archive stores.
  - During outage and drift drills, control-plane settings (SQS/DLQ attributes, deleted queues/event-source mappings, EventBridge schedule states, Lambda environment variables) and data-plane state across DynamoDB, Valkey, and S3 may diverge from PostgreSQL:
    - DynamoDB `SK = STATE` or `SK = EVENT#*` items may be deleted, may have their attributes (`status`, `clearing_stage`, `GSI1PK`, `GSI1SK`, `version`, `envelope`, etc.) corrupted in-place (both with inflated versions `version >= pg_version` and with unchanged `version == pg_version` / unchanged `EVENT#*` sort keys that the projector's conditional writes will not overwrite unless the corrupted DynamoDB items are deleted first), or may include phantom `EVENT#*` items (`version > pg_version`) or orphan `SETTLEMENT#<id>` partitions for settlements that do not exist in `clearledger.settlements`.
    - Valkey cache keys (`clearledger:settlement:<id>`) may contain stale/poisoned JSON payloads (including same-version poisoned entries) or orphan settlement keys not backed by PostgreSQL.
    - S3 audit objects under `s3://<AUDIT_BUCKET>/ledger-audit/` may be missing for outbox rows whose `archived_at` is already `NOT NULL` in PostgreSQL, may have forged/mismatched batch keys or SHA-256 digests (`batch-<first_seq:08d>-<last_seq:08d>-<16_char_sha256_hex>.ndjson`), may have out-of-order `outbox.seq` records within a batch, may contain orphan/tampered/duplicate `eventId` records or events whose `archived_at` was reset to `NULL` in PostgreSQL, or stray objects may exist outside the `ledger-audit/` prefix.
  - Before `deploy.sh` exits `0`, it must converge both the control plane and all derived data stores against PostgreSQL so that:
    - All unpublished outbox rows (`published_at IS NULL`) are relayed.
    - Every settlement in `clearledger.settlements` has an exact, uncorrupted DynamoDB `SK = STATE` item (including valid `AccountIndex` `GSI1PK` and `GSI1SK` attributes) and exact `SK = EVENT#00000001..EVENT#<pg_version>` items matching `clearledger.events` (with any corrupted or phantom `STATE`/`EVENT#*` items and any orphan `SETTLEMENT#*` partitions or Valkey keys purged).
    - Every committed event in `clearledger.outbox` appears **exactly once** across `s3://<AUDIT_BUCKET>/ledger-audit/batch-*.ndjson` with its exact canonical JSON `payload` from `clearledger.outbox`, valid `batch-<first_seq:08d>-<last_seq:08d>-<16_char_sha256_hex>.ndjson` key and digest, and ascending `seq` order (with `archived_at IS NOT NULL` in PostgreSQL and any stray, orphan, tampered, out-of-sequence, or duplicate S3 audit batches removed).
- **Prefix-Scoped Teardown in `destroy.sh`**:
  - During operational drills, out-of-band resources scoped to `<resource_prefix>` (such as inline or attached customer-managed IAM policies on `<resource_prefix>` roles, out-of-band `<resource_prefix>-*` IAM roles, SQS queues, EventBridge Scheduler schedules, KMS aliases, or `/clearledger/<resource_prefix>/*` CloudWatch Log Groups) may exist outside Terraform state.
  - `destroy.sh` must detach and delete any inline or attached customer-managed policies on `<resource_prefix>` IAM roles, destroy all Terraform-managed resources, and sweep any remaining `<resource_prefix>`-prefixed or `ClearLedgerDeployment=<resource_prefix>`-tagged resources across IAM, SQS, CloudWatch Logs, EventBridge Scheduler, and KMS aliases while keeping all `cl-base-*` baseline resources intact.
- **Structured Logs**: All four workloads emit JSON log lines containing `correlationId` (propagated from `X-Correlation-Id`) to their configured CloudWatch Log Groups without leaking `db_password` or Cognito `client_secret` values.
