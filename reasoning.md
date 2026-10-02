# ClearLedger Settlement Platform

## Introduction

ClearLedger is an event-sourced interbank clearing and settlement ledger running on an AWS-compatible control plane (`http://aws:4566`). The HTTP surface is intentionally focused: clients initiate a settlement instruction between two counterparties, append clearing and settlement ledger entries (such as `VALIDATED`, `RESERVED`, `CLEARED`, `SETTLED`, `RECONCILED`, or `DISPUTED`), and query either the latest settlement state or the full ordered ledger trail. I kept the application code compact because the benchmark is not testing whether an agent can write Rust HTTP handlers—it is testing whether an agent can provision and operate a resilient multi-service AWS architecture where accepted writes survive messaging outages, corrupted read projections can be rebuilt from the immutable event log, and every component runs with least-privilege IAM roles and customer-managed KMS keys.

Even though a basic ledger prototype could run on a single PostgreSQL instance, I split the write and read paths across RDS PostgreSQL, SQS, Lambda, DynamoDB, ElastiCache for Valkey, and S3. That separation forces the model to handle real cloud reliability and recovery mechanics: transactional outbox recovery when an SQS queue is deleted and recreated, DynamoDB Global Secondary Index (`AccountIndex`) and point-in-time recovery configuration, partial batch failure reporting (`ReportBatchItemFailures`) with a dead-letter queue (`maxReceiveCount = 4`), non-default worker tuning parameters (`CACHE_TTL_SECONDS = 90`, `OUTBOX_BATCH_SIZE = 50`, `AUDIT_PREFIX = ledger-audit/`), and clean idempotent Terraform convergence.

I package the application into four pre-built container images so each runtime role stays isolated with its own IAM role:

1. **API image (`clearledger/api:1.0.0`):** serves only the HTTP endpoints. The model runs this on ECS Fargate with two tasks across two availability zones behind an Application Load Balancer.
2. **Projector image (`clearledger/projector:1.0.0`):** consumes domain events from the main SQS queue, updates the settlement projection and event history in DynamoDB, and invalidates stale keys in Valkey. The model runs this as a container-based Lambda function wired to SQS via an event source mapping.
3. **Outbox relay image (`clearledger/relay:1.0.0`):** scans PostgreSQL for committed outbox rows that have not been published to SQS yet and delivers them in batches. This runs as a container-based Lambda function invoked every minute by EventBridge Scheduler.
4. **Audit archiver image (`clearledger/archiver:1.0.0`):** reads published events from PostgreSQL and writes deterministic NDJSON batches under `ledger-audit/batch-*.ndjson` in a private, KMS-encrypted S3 bucket. This runs as a third container-based Lambda function invoked every five minutes by EventBridge Scheduler.

Only the ECS Fargate API service keeps two warm tasks running continuously to serve low-latency HTTP traffic; the three background workers run as serverless Lambda functions on queue arrival or scheduled ticks.

## Infrastructure used

| Cloud service | How it is used in this task |
|---|---|
| **VPC** | Two-AZ virtual network (`us-east-1a` and `us-east-1b`) with public subnets for the load balancer, private subnets for ECS, RDS, and Valkey, and four security groups enforcing least-privilege network paths. |
| **Application Load Balancer** | Public HTTP entry point (`port 80`) that routes traffic across both availability zones to healthy ECS API tasks on `port 8080` using `/health/ready`. |
| **ECS Fargate** | Runs two warm API container tasks (`desired_count = 2`) and automatically replaces tasks if an instance is stopped. |
| **RDS PostgreSQL** | Durable system of record (`postgres 16`, `db.t4g.micro`) storing settlement aggregates, the immutable event log, transactional outbox rows, and idempotency keys. |
| **SQS (main queue and DLQ)** | Buffers domain events between the API/relay and the projector Lambda (`visibility_timeout_seconds = 3`, `receive_wait_time_seconds = 2`) and routes poison messages to a dead-letter queue after 4 failed receives (`maxReceiveCount = 4`). |
| **AWS Lambda** | Runs the projector, outbox relay, and audit archiver container images on demand without idle compute overhead. |
| **DynamoDB** | Stores the queryable settlement projection (`PK = SETTLEMENT#<id>`, `SK = STATE`) and ordered ledger items (`SK = EVENT#<version>`) with a `GSI1PK`/`GSI1SK` `AccountIndex` secondary index, KMS encryption, and point-in-time recovery enabled. |
| **ElastiCache for Valkey** | Caches hot settlement projections (`clearledger:settlement:<id>`) with a 90-second TTL (`CACHE_TTL_SECONDS = 90`) in front of DynamoDB. |
| **Cognito** | Hosts the OAuth2 user pool, domain, resource server (`clearledger`), and three separate app clients issuing access tokens for `clearledger/read`, `clearledger/write`, and `clearledger/admin`. |
| **EventBridge Scheduler** | Invokes the outbox relay Lambda on `rate(1 minute)` and the audit archiver Lambda on `rate(5 minutes)`. |
| **S3** | Stores versioned, KMS-encrypted NDJSON audit files (`ledger-audit/batch-*.ndjson`) with all public access blocked. |
| **IAM** | Provides six dedicated execution and runtime roles (`ecs_execution`, `ecs_task`, `projector`, `relay`, `archiver`, `scheduler`) scoped to exact resource ARNs. |
| **KMS** | Supplies four customer-managed keys and aliases (`database`, `messaging`, `projection`, `audit`) with automatic key rotation enabled and a 10-day deletion window. |
| **CloudWatch Logs** | Captures structured JSON logs from the API and all three Lambda functions in four dedicated log groups with at least 14 days of retention. |

## Operational flows

Each diagram below traces one operational path through the platform and includes only the services participating in that flow.

### 1. Authenticate and reach the API

Every business endpoint requires a Cognito JWT carrying the matching scope (`clearledger/read`, `clearledger/write`, or `clearledger/admin`). The client requests an access token from Cognito using the `client_credentials` grant, then sends the HTTP request to the Application Load Balancer. The ALB forwards the request to one of the two ECS Fargate API tasks. If the API task does not have the Cognito signing keys cached yet, it fetches the JWKS document once, verifies the JWT signature, issuer, token use, expiration, and scope locally, and then executes the handler.

```mermaid
sequenceDiagram
    participant Client
    participant Cognito
    participant ALB
    participant API as ECS API

    Client->>Cognito: Request token with client credentials
    Cognito-->>Client: Return signed JWT access token
    Client->>ALB: Send HTTP request with Bearer token
    ALB->>API: Forward request to healthy task
    opt Public keys are not cached in memory yet
        API->>Cognito: Fetch public JWKS verification keys
        Cognito-->>API: Return public JWKS keys
    end
    API->>API: Validate signature locally with cached key
    API->>API: Check expiration, issuer and required scope
```

### 2. Initiate a new settlement

When a client calls `POST /v1/settlements`, the API opens a single SQL transaction in RDS PostgreSQL and writes three records atomically:

1. The **settlement aggregate row** in `clearledger.settlements` recording the settlement ID, account ID, reference, debit and credit counterparties, and initial version (`1`).
2. The **immutable event row** in `clearledger.events` recording `SettlementInitiated`.
3. The **transactional outbox row** in `clearledger.outbox` holding the serialized event envelope with `published_at = NULL`.

Because all three inserts share one database transaction, PostgreSQL guarantees that we never commit a settlement without queuing its event in the outbox. Immediately after commit, the API performs a best-effort publish to the main SQS queue, marks `published_at` if SQS accepts the message, and returns `201 Created`. The Projector Lambda then consumes the SQS message, writes the initial state and event item into DynamoDB, and clears any stale Valkey entry.

```mermaid
sequenceDiagram
    participant Client
    participant ALB
    participant API as ECS API
    participant RDS as RDS PostgreSQL
    participant SQS as Main SQS Queue
    participant Projector as Projector Lambda
    participant DDB as DynamoDB
    participant Valkey

    Client->>ALB: POST /v1/settlements with write token
    ALB->>API: Route request
    API->>RDS: Begin SQL transaction
    API->>RDS: Insert settlement row
    API->>RDS: Insert SettlementInitiated event row
    API->>RDS: Insert unpublished outbox row
    API->>RDS: Commit transaction
    RDS-->>API: Commit confirmed
    API->>SQS: Send SettlementInitiated event
    API-->>ALB: 201 Created
    ALB-->>Client: 201 Created
    SQS->>Projector: Deliver event batch
    Projector->>DDB: Put STATE item and EVENT#00000001 item
    Projector->>Valkey: Delete stale settlement cache key
```

### 3. Append a clearing or settlement ledger entry

Calling `POST /v1/settlements/{id}/entries` appends the next lifecycle transition (for example, `VALIDATED`, `RESERVED`, `CLEARED`, or `SETTLED`) without overwriting prior ledger entries. The caller passes an `Idempotency-Key` header and `expectedVersion`. Inside RDS PostgreSQL, the API locks the aggregate row, checks `clearledger.idempotency_keys` for an existing key, and verifies `expectedVersion`.

That produces one of three deterministic outcomes: an idempotent replay (`200 OK` with `idempotentReplay: true`) if the exact request was already committed, a version increment (`202 Accepted`) that writes `LedgerEntryRecorded` and invalidates Valkey, or a `409 Conflict` if either the idempotency payload differs or `expectedVersion` is stale.

```mermaid
sequenceDiagram
    participant Client
    participant ALB
    participant API as ECS API
    participant RDS as RDS PostgreSQL
    participant SQS as Main SQS Queue
    participant Projector as Projector Lambda
    participant DDB as DynamoDB
    participant Valkey

    Client->>ALB: POST /v1/settlements/{id}/entries
    ALB->>API: Forward token, idempotency key and expectedVersion
    API->>RDS: Check idempotency key and current aggregate version

    alt FLOW 1 · IDEMPOTENT REPLAY · Return stored response
        RDS-->>API: Return previously saved response body
        API-->>ALB: 200 OK (idempotentReplay: true)
        ALB-->>Client: 200 OK without duplicate event
    else FLOW 2 · ENTRY ACCEPTED · Commit next version
        API->>RDS: Commit LedgerEntryRecorded event and outbox row
        RDS-->>API: Transaction committed
        API->>Valkey: Invalidate clearledger:settlement:{id}
        API->>SQS: Send LedgerEntryRecorded message
        API-->>ALB: 202 Accepted
        ALB-->>Client: 202 Accepted
        SQS->>Projector: Deliver event
        Projector->>DDB: Update STATE item and write EVENT#<version>
        Projector->>Valkey: Delete cached settlement key
    else FLOW 3 · VERSION OR PAYLOAD CONFLICT · Reject write
        RDS-->>API: Mismatch detected
        API-->>ALB: 409 Conflict
        ALB-->>Client: 409 Conflict
    end
```

### 4. Read current settlement state

When a client calls `GET /v1/settlements/{id}`, the API checks Valkey (`clearledger:settlement:{id}`) first. On a cache hit, it returns the projection immediately with `X-ClearLedger-Source: cache`. On a cache miss, it reads the `STATE` item from DynamoDB (`PK = SETTLEMENT#<id>`, `SK = STATE`), writes the serialized JSON into Valkey with a 90-second TTL (`CACHE_TTL_SECONDS = 90`), and returns the response with `X-ClearLedger-Source: projection`. PostgreSQL is never queried on the read path—if the projection has not arrived in DynamoDB yet or was deleted, `GET /v1/settlements/{id}` returns `404` until projection delivery completes or an administrator triggers a rebuild.

```mermaid
sequenceDiagram
    participant Client
    participant ALB
    participant API as ECS API
    participant Valkey
    participant DDB as DynamoDB

    Client->>ALB: GET /v1/settlements/{id} with read token
    ALB->>API: Forward request
    API->>Valkey: GET clearledger:settlement:{id}

    alt FLOW 1 · CACHE HIT · Serve from Valkey
        Valkey-->>API: Return cached projection JSON
        API-->>ALB: 200 OK (X-ClearLedger-Source: cache)
    else FLOW 2 · CACHE MISS · Read DynamoDB and warm Valkey
        API->>DDB: GetItem PK=SETTLEMENT#{id}, SK=STATE
        DDB-->>API: Return projection attributes
        API->>Valkey: SETEX clearledger:settlement:{id} 90s
        API-->>ALB: 200 OK (X-ClearLedger-Source: projection)
    end

    ALB-->>Client: Return settlement projection
```

### 5. Read the full settlement ledger history

Calling `GET /v1/settlements/{id}/ledger` returns every committed lifecycle event in ascending version order. Because Valkey only caches the latest summary state, ledger queries go directly to DynamoDB and query all items under `PK = SETTLEMENT#<id>` where `SK` begins with `EVENT#`.

```mermaid
sequenceDiagram
    participant Client
    participant ALB
    participant API as ECS API
    participant DDB as DynamoDB

    Client->>ALB: GET /v1/settlements/{id}/ledger
    ALB->>API: Forward request with read token
    API->>DDB: Query PK=SETTLEMENT#{id} and SK begins_with EVENT#
    DDB-->>API: Return ordered event items
    API-->>ALB: 200 OK (X-ClearLedger-Source: projection)
    ALB-->>Client: Return ordered settlement ledger
```

### 6. Rebuild a corrupted or deleted DynamoDB projection

If the DynamoDB items for a settlement are deleted or corrupted (causing `GET /v1/settlements/{id}` to return `404`), an operator holding a `clearledger/admin` token can call `POST /v1/admin/projections/{id}/rebuild`. The API queries RDS PostgreSQL for all events belonging to that settlement ordered by `aggregate_version ASC`, re-enqueues each event envelope onto the main SQS queue, and evicts the Valkey cache key so the Projector Lambda reconstructs the DynamoDB items cleanly.

```mermaid
sequenceDiagram
    participant Admin
    participant ALB
    participant API as ECS API
    participant RDS as RDS PostgreSQL
    participant SQS as Main SQS Queue
    participant Valkey
    participant Projector as Projector Lambda
    participant DDB as DynamoDB

    Admin->>ALB: POST /v1/admin/projections/{id}/rebuild
    ALB->>API: Forward request with clearledger/admin token
    API->>RDS: Select all events for settlement ordered by version
    RDS-->>API: Return ordered event envelopes
    API->>SQS: Re-enqueue all settlement events
    API->>Valkey: Delete clearledger:settlement:{id}
    API-->>ALB: 202 Accepted (requeued count)
    ALB-->>Admin: Return rebuild confirmation
    SQS->>Projector: Deliver replayed events
    Projector->>DDB: Reconstruct STATE and EVENT# items
```

### 7. Recover writes accepted during an SQS outage

If the main SQS queue is deleted while a client submits a settlement or ledger entry, the API still accepts the write (`201` or `202`) because the aggregate row, event row, and outbox row (`published_at = NULL`) commit inside RDS PostgreSQL before the API attempts the direct SQS publish. While the queue is missing, `GET /v1/settlements/{id}` returns `404` because the event cannot reach DynamoDB. Recovery proceeds in three steps:

1. **Induce the fault:** the verifier deletes the main SQS queue and submits a new settlement and ledger entry. PostgreSQL commits both writes durably with `published_at = NULL`, while `GET` returns `404`.
2. **Repair the infrastructure:** the verifier re-runs `deploy.sh`, which refreshes Terraform state, recreates the missing SQS queue and event source mapping, and updates the active runtime configuration.
3. **Flush the outbox:** EventBridge Scheduler (or a direct Lambda invocation) runs the Outbox Relay Lambda, which selects unpublished outbox rows (`LIMIT 50`), publishes them to the restored SQS queue, updates `published_at`, and lets the Projector Lambda populate DynamoDB.

```mermaid
sequenceDiagram
    autonumber
    participant Verifier
    participant Client
    participant API as ECS API
    participant RDS as RDS PostgreSQL
    participant SQS as Main SQS Queue
    participant Deploy as deploy.sh
    participant Trigger as Scheduler / Verifier
    participant Relay as Outbox Relay Lambda
    participant Projector as Projector Lambda
    participant DDB as DynamoDB

    Verifier->>SQS: PHASE 1 · Delete main SQS queue
    Client->>API: Submit settlement write
    API->>RDS: Commit event row and unpublished outbox row
    RDS-->>API: Transaction committed
    API-xSQS: Best-effort send fails (queue missing)
    API-->>Client: Return 201/202 from durable SQL commit
    Verifier->>Deploy: PHASE 2 · Re-run deploy.sh
    Deploy->>SQS: Recreate SQS queue and Lambda event source mapping
    Trigger->>Relay: PHASE 3 · Invoke Outbox Relay Lambda
    Relay->>RDS: Select unpublished outbox rows (batch size 50)
    RDS-->>Relay: Return pending event envelopes
    Relay->>SQS: Send pending events to restored queue
    SQS-->>Relay: Confirm delivery
    Relay->>RDS: Set published_at timestamp
    SQS->>Projector: Deliver recovered events
    Projector->>DDB: Write recovered settlement projection
```

### 8. Archive published events to Amazon S3

Every five minutes (`rate(5 minutes)`), EventBridge Scheduler triggers the Audit Archiver Lambda. The archiver queries RDS PostgreSQL for published outbox rows whose `archived_at` column is still `NULL`, validates each event envelope, writes a deterministic NDJSON object (`ledger-audit/batch-<first_seq>-<last_seq>-<sha256_prefix>.ndjson`) to the KMS-encrypted S3 audit bucket, and stamps `archived_at` in PostgreSQL.

```mermaid
sequenceDiagram
    participant Scheduler as EventBridge Scheduler
    participant Archiver as Audit Archiver Lambda
    participant RDS as RDS PostgreSQL
    participant S3 as Private S3 Bucket

    Scheduler->>Archiver: Trigger scheduled archive run
    Archiver->>RDS: Fetch published unarchived events
    RDS-->>Archiver: Return ordered event batch
    Archiver->>S3: PutObject ledger-audit/batch-*.ndjson
    S3-->>Archiver: Confirm object stored
    Archiver->>RDS: Mark events archived_at
```

## Score

The verifier evaluates the submission across **19 test blocks** grouped into **six categories** totaling **100 points**. A submission only passes when it achieves **100 / 100** and triggers no hard-gate score caps.

| Category | Points |
|---|---:|
| Core product behavior | 24 |
| Recovery | 20 |
| Architecture and deployment | 17 |
| Lifecycle | 15 |
| Asynchronous processing | 13 |
| Security and observability | 11 |
| **Total** | **100** |

Here is what each scored test block checks and how points are distributed:

| Category | Scored test block | What its experiments prove | Points |
|---|---|---|---:|
| Core product behavior | Settlement workflow | 8–12 randomized settlement lifecycles with 3–6 clearing/settlement entries each commit cleanly, project into DynamoDB, and return accurate state and ordered ledger histories through the ALB. | 9 |
| Core product behavior | Projection and cache | Deleting the Valkey key causes the next `GET /v1/settlements/{id}` to return `X-ClearLedger-Source: projection` and repopulate Valkey so the following read returns `X-ClearLedger-Source: cache`; writes invalidate the cached key. | 7 |
| Core product behavior | Idempotency and concurrency | Replaying the same `Idempotency-Key` 5–10 times commits only once (`idempotentReplay: true` on replays), reusing an `Idempotency-Key` with a different body returns `409`, and submitting a stale `expectedVersion` returns `409`. | 8 |
| Recovery | Outbox recovery | Deleting the main SQS queue does not block write acceptance in PostgreSQL (`GET` returns `404` while unprojected), and re-running `deploy.sh` plus invoking the outbox relay restores the queue and converges the DynamoDB projection. | 6 |
| Recovery | Projection rebuild | Deleting the DynamoDB `STATE` and `EVENT#` items and Valkey key causes `GET` to return `404` until `POST /v1/admin/projections/{id}/rebuild` replays the PostgreSQL event log through SQS. | 5 |
| Recovery | ECS task replacement | Stopping one running ECS task leaves `/health/ready` and existing settlement reads available via the remaining task while ECS schedules a replacement to return to 2 running tasks. | 5 |
| Recovery | RDS reboot recovery | Rebooting the RDS PostgreSQL instance preserves all previously committed settlement records and allows new writes to succeed once the instance returns healthy. | 4 |
| Architecture and deployment | Infrastructure managed with Terraform or OpenTofu | `terraform validate` succeeds and `infra/terraform.tfstate` manages all required AWS resource types and tagged resources for the deployment prefix. | 3 |
| Architecture and deployment | Declared compute and ingress | State declares the 2-AZ VPC, public/private subnets, 4 security groups (`alb`, `ecs`, `rds`, `valkey`), internet-facing ALB + HTTP listener + `/health/ready` target group, and ECS Fargate service (`desired_count >= 2`, `CACHE_TTL_SECONDS = 90`). | 2 |
| Architecture and deployment | Declared data and messaging | State declares RDS PostgreSQL 16 (`db.t4g.micro`), SQS main queue (`visibility_timeout = 3`, `wait_time = 2`, `retention = 172800`) + DLQ (`retention = 1209600`, `maxReceiveCount = 4`), 3 container Lambdas (`OUTBOX_BATCH_SIZE = 50`, `AUDIT_PREFIX = ledger-audit/`), SQS ESM (`batch_size = 5`, `ReportBatchItemFailures`), 2 EventBridge schedules, DynamoDB (`PK`/`SK`, `AccountIndex` GSI, PITR, KMS), Valkey 8 (`cache.t4g.micro`), and S3 (versioning, KMS, public access block). | 2 |
| Architecture and deployment | Live ingress and compute | Live AWS inspection confirms the ALB, listener, target group, ECS cluster/service (`2` running tasks across `2` AZs), and `X-ClearLedger-Instance` header distribution match `manifest.json`. | 5 |
| Architecture and deployment | Live data and event graph | Live AWS inspection confirms RDS, SQS queue attributes and redrive policy, Lambda functions and ESM, EventBridge schedules, DynamoDB `AccountIndex` GSI + PITR + SSE, Valkey node, and S3 versioning/encryption/public-access blocks match `manifest.json`. | 5 |
| Lifecycle | Stable deployment | Re-running `deploy.sh` converges cleanly with the same RDS endpoint and preserves all committed settlement records. | 7 |
| Lifecycle | Clean destroy | Running `destroy.sh` exits `0`, removes every resource created for the trial's `resource_prefix`, and leaves all baseline resources untouched. | 8 |
| Asynchronous processing | Backlog recovery | Disabling the SQS event source mapping causes 20–35 rapid ledger entries across 5 settlements to queue in SQS (`GET` returns `404` while disabled) and drain cleanly in version order once re-enabled. | 7 |
| Asynchronous processing | Duplicate and invalid messages | Re-sending an already applied event envelope to SQS is ignored idempotently without bumping the version, while a poison message is retried and routed to the DLQ after 4 receives. | 6 |
| Security and observability | Declared security | State declares 6 distinct IAM roles with least-privilege policies, 4 customer-managed KMS keys (`enable_key_rotation = true`, `deletion_window_in_days >= 10`) and aliases, Cognito user pool/domain/resource server/3 scoped clients, and 4 CloudWatch Log Groups (`retention_in_days >= 14`). | 3 |
| Security and observability | Live security graph | Live AWS inspection verifies the 6 IAM roles and wildcard-free policies, 4 enabled KMS keys with rotation, Cognito scopes (`clearledger/read`, `clearledger/write`, `clearledger/admin`), and 4 CloudWatch Log Groups. | 5 |
| Security and observability | Authorization, audit and logs | Every endpoint enforces strict non-hierarchical OAuth2 scope checks (`401` missing token, `403` wrong scope), the archiver writes valid `ledger-audit/batch-*.ndjson` envelopes to S3, and CloudWatch Logs record correlation IDs without leaking database passwords or client secrets. | 3 |
| **Total** |  |  | **100** |

### Hard Gates and Score Caps

In addition to the point weights above, the verifier applies three score caps if critical invariants are broken:
- **Accepted write loss or corruption (`score cap: 49`)**: Applied if any settlement creation or ledger entry write that returned HTTP `201`/`202` is lost or corrupted in PostgreSQL or the rebuilt projection.
- **Critical authorization escalation (`score cap: 49`)**: Applied if an unauthenticated request or an under-scoped token (`read`, `write`, or `admin` outside its permitted routes) succeeds, or if credentials are leaked in CloudWatch Logs.
- **Teardown resource leak (`score cap: 79`)**: Applied if `destroy.sh` fails, leaves behind trial resources in the AWS account, or removes pre-existing baseline resources.
