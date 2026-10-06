use std::{collections::BTreeMap, env, net::SocketAddr, sync::Arc, time::Duration};

use anyhow::{bail, Context, Result};
use aws_sdk_dynamodb::Client as DynamoDbClient;
use aws_sdk_sqs::Client as SqsClient;
use axum::{
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::Utc;
use clearledger::{
    build_aws_config, connect_postgres, fetch_ledger_from_dynamodb,
    fetch_projection_from_dynamodb, normalize_valkey_url, sha256_hex, valkey_settlement_key,
    verify_postgres_schema, AppendEntryRequest, CloudWatchEmit, CreateSettlementRequest,
    DomainEventData, DomainEventEnvelope, JwksValidator, RebuildResponse, SettlementStatus,
    TokenClaims, WriteAcceptedResponse,
};
use redis::AsyncCommands;
use serde_json::{json, Value};
use sqlx::{PgPool, Postgres, Row, Transaction};
use tokio::net::TcpListener;
use tracing::{error, info, warn};
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    sqs: SqsClient,
    ddb: DynamoDbClient,
    redis_client: redis::Client,
    jwks: JwksValidator,
    cw: CloudWatchEmit,
    queue_url: String,
    projection_table: String,
    cache_ttl_seconds: u64,
    instance_id: String,
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = Json(json!({
            "error": self.code,
            "message": self.message,
        }));
        (self.status, body).into_response()
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .json()
        .init();

    let port: u16 = env::var("PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse()
        .context("invalid PORT")?;
    let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let queue_url = env::var("SQS_QUEUE_URL")
        .or_else(|_| env::var("QUEUE_URL"))
        .context("SQS_QUEUE_URL is required")?;
    let projection_table = env::var("PROJECTION_TABLE").context("PROJECTION_TABLE is required")?;
    let valkey_url = env::var("VALKEY_URL")
        .or_else(|_| env::var("VALKEY_ENDPOINT"))
        .context("VALKEY_URL is required")?;
    let cache_ttl_raw = env::var("CACHE_TTL_SECONDS").unwrap_or_else(|_| "90".to_string());
    let cache_ttl_seconds: u64 = cache_ttl_raw
        .trim()
        .parse()
        .context("CACHE_TTL_SECONDS must be an integer")?;
    if cache_ttl_seconds == 0 {
        bail!("CACHE_TTL_SECONDS must be > 0");
    }
    let instance_id = env::var("SERVICE_INSTANCE_ID")
        .or_else(|_| env::var("INSTANCE_ID"))
        .or_else(|_| env::var("HOSTNAME"))
        .unwrap_or_else(|_| format!("api-{}", Uuid::new_v4()));

    let sdk_config = build_aws_config().await;
    let sqs = SqsClient::new(&sdk_config);
    let ddb = DynamoDbClient::new(&sdk_config);
    let cw = CloudWatchEmit::new(&sdk_config, "api");
    let jwks = JwksValidator::from_env()?;
    let normalized_valkey = normalize_valkey_url(&valkey_url);
    let redis_client =
        redis::Client::open(normalized_valkey.as_str()).context("failed creating Valkey client")?;

    let pool = loop {
        match connect_postgres(&database_url).await {
            Ok(pool) => break pool,
            Err(err) => {
                warn!(error = %err, "waiting for PostgreSQL to become reachable");
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    };

    let state = Arc::new(AppState {
        pool,
        sqs,
        ddb,
        redis_client,
        jwks,
        cw,
        queue_url,
        projection_table,
        cache_ttl_seconds,
        instance_id: instance_id.clone(),
    });

    let app = Router::new()
        .route("/health/live", get(health_live))
        .route("/health/ready", get(health_ready))
        .route("/v1/settlements", post(create_settlement))
        .route("/v1/settlements/{id}/entries", post(append_entry))
        .route("/v1/settlements/{id}", get(get_settlement))
        .route("/v1/settlements/{id}/ledger", get(get_settlement_ledger))
        .route(
            "/v1/admin/projections/{id}/rebuild",
            post(rebuild_projection),
        )
        .with_state(state.clone());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    info!(%addr, instance = %instance_id, "starting clearledger-api");
    state
        .cw
        .emit_json(json!({
            "service": "clearledger-api",
            "event": "startup",
            "instance": instance_id,
            "timestamp": Utc::now().to_rfc3339(),
        }))
        .await;

    let listener = TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn authenticate(
    state: &AppState,
    headers: &HeaderMap,
    required_scope: &str,
) -> Result<TokenClaims, ApiError> {
    let raw_header = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "Missing Authorization header",
            )
        })?;

    let token = raw_header
        .strip_prefix("Bearer ")
        .or_else(|| raw_header.strip_prefix("bearer "))
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "Authorization header must use Bearer scheme",
            )
        })?
        .trim();

    if token.is_empty() {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "Empty bearer token",
        ));
    }

    let claims = state.jwks.verify(token).await.map_err(|err| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            format!("Invalid access token: {err}"),
        )
    })?;

    if !claims.has_scope(required_scope) {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "forbidden",
            format!("Token does not grant required scope {required_scope}"),
        ));
    }

    Ok(claims)
}

fn extract_idempotency_key(headers: &HeaderMap) -> Result<String, ApiError> {
    let key = headers
        .get("Idempotency-Key")
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::BAD_REQUEST,
                "missing_idempotency_key",
                "Header Idempotency-Key is required",
            )
        })?;
    if key.len() < 8 || key.len() > 128 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_idempotency_key",
            "Idempotency-Key must be between 8 and 128 characters",
        ));
    }
    Ok(key.to_string())
}

fn extract_correlation_id(headers: &HeaderMap) -> String {
    headers
        .get("X-Correlation-Id")
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|v| v.len() >= 4)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("corr-{}", Uuid::new_v4()))
}

fn attach_instance_header(headers: &mut HeaderMap, instance_id: &str) {
    if let Ok(val) = HeaderValue::from_str(instance_id) {
        headers.insert("X-ClearLedger-Instance", val);
    }
}

async fn health_live(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut headers = HeaderMap::new();
    attach_instance_header(&mut headers, &state.instance_id);
    (
        StatusCode::OK,
        headers,
        Json(json!({
            "status": "UP",
            "service": "clearledger-api",
            "instance": state.instance_id,
            "checks": {}
        })),
    )
}

async fn health_ready(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut checks = BTreeMap::new();
    let pg_ok = verify_postgres_schema(&state.pool).await;
    checks.insert(
        "postgres".to_string(),
        if pg_ok { "UP" } else { "DOWN" }.to_string(),
    );

    let ddb_ok = state
        .ddb
        .describe_table()
        .table_name(&state.projection_table)
        .send()
        .await
        .is_ok();
    checks.insert(
        "dynamodb".to_string(),
        if ddb_ok { "UP" } else { "DOWN" }.to_string(),
    );

    let sqs_ok = state
        .sqs
        .get_queue_attributes()
        .queue_url(&state.queue_url)
        .send()
        .await
        .is_ok();
    checks.insert(
        "sqs".to_string(),
        if sqs_ok { "UP" } else { "DEGRADED" }.to_string(),
    );

    let valkey_ok = match state.redis_client.get_multiplexed_async_connection().await {
        Ok(mut conn) => redis::cmd("PING")
            .query_async::<String>(&mut conn)
            .await
            .is_ok(),
        Err(_) => false,
    };
    checks.insert(
        "valkey".to_string(),
        if valkey_ok { "UP" } else { "DEGRADED" }.to_string(),
    );

    let ready = pg_ok && ddb_ok;
    let status_code = if ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    let mut headers = HeaderMap::new();
    attach_instance_header(&mut headers, &state.instance_id);
    (
        status_code,
        headers,
        Json(json!({
            "status": if ready { "UP" } else { "DEGRADED" },
            "service": "clearledger-api",
            "instance": state.instance_id,
            "checks": checks,
        })),
    )
}

async fn check_idempotency(
    tx: &mut Transaction<'_, Postgres>,
    scope: &str,
    key: &str,
    request_hash: &str,
) -> Result<Option<(StatusCode, Value)>, ApiError> {
    let row = sqlx::query(
        "SELECT request_hash, status_code, response_body FROM clearledger.idempotency_keys WHERE scope = $1 AND idempotency_key = $2 FOR UPDATE",
    )
    .bind(scope)
    .bind(key)
    .fetch_optional(&mut **tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    let Some(row) = row else {
        return Ok(None);
    };

    let stored_hash: String = row.get("request_hash");
    if stored_hash != request_hash {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "idempotency_conflict",
            "Idempotency-Key was already used with a different request payload",
        ));
    }

    let mut body: Value = row.get("response_body");
    if let Some(obj) = body.as_object_mut() {
        obj.insert("idempotentReplay".to_string(), Value::Bool(true));
    }
    Ok(Some((StatusCode::OK, body)))
}

async fn best_effort_publish_outbox_event(state: &AppState, envelope: &DomainEventEnvelope) {
    let payload_str = match serde_json::to_string(envelope) {
        Ok(s) => s,
        Err(_) => return,
    };

    match state
        .sqs
        .send_message()
        .queue_url(&state.queue_url)
        .message_body(payload_str)
        .send()
        .await
    {
        Ok(_) => {
            let _ = sqlx::query(
                "UPDATE clearledger.outbox SET published_at = NOW(), attempts = attempts + 1, last_error = NULL WHERE event_id = $1 AND published_at IS NULL",
            )
            .bind(envelope.event_id)
            .execute(&state.pool)
            .await;
        }
        Err(err) => {
            warn!(
                event_id = %envelope.event_id,
                settlement_id = %envelope.aggregate_id,
                error = %err,
                "direct SQS publish failed; event remains queued in transactional outbox"
            );
            let _ = sqlx::query(
                "UPDATE clearledger.outbox SET attempts = attempts + 1, last_error = $2 WHERE event_id = $1",
            )
            .bind(envelope.event_id)
            .bind(err.to_string())
            .execute(&state.pool)
            .await;
        }
    }
}

async fn invalidate_valkey_cache(state: &AppState, settlement_id: Uuid) {
    if let Ok(mut conn) = state.redis_client.get_multiplexed_async_connection().await {
        let key = valkey_settlement_key(settlement_id);
        let _: redis::RedisResult<i64> = conn.del(&key).await;
    }
}

async fn create_settlement(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<CreateSettlementRequest>,
) -> Result<impl IntoResponse, ApiError> {
    authenticate(&state, &headers, "clearledger/write").await?;
    let idempotency_key = extract_idempotency_key(&headers)?;
    let correlation_id = extract_correlation_id(&headers);

    if req.expected_version != 0 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_expected_version",
            "expectedVersion must be 0 when initiating a settlement",
        ));
    }
    if req.account_id.trim().len() < 3
        || req.reference.trim().len() < 3
        || req.debit_party.trim().len() < 2
        || req.credit_party.trim().len() < 2
    {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "accountId, reference, debitParty, and creditParty must be non-empty",
        ));
    }

    let canonical_req = json!({
        "settlementId": req.settlement_id,
        "accountId": req.account_id.trim(),
        "reference": req.reference.trim(),
        "debitParty": req.debit_party.trim(),
        "creditParty": req.credit_party.trim(),
        "expectedVersion": req.expected_version,
    });
    let req_hash = sha256_hex(canonical_req.to_string().as_bytes());
    let idem_scope = format!("create:{}", req.settlement_id);

    let mut tx = state.pool.begin().await.map_err(|err| {
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string())
    })?;

    let lock_key = req.settlement_id.as_u128() as i64;
    sqlx::query("SELECT pg_advisory_xact_lock($1)")
        .bind(lock_key)
        .execute(&mut *tx)
        .await
        .map_err(|err| {
            ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string())
        })?;

    if let Some((status, body)) =
        check_idempotency(&mut tx, &idem_scope, &idempotency_key, &req_hash).await?
    {
        tx.commit().await.ok();
        let mut resp_headers = HeaderMap::new();
        attach_instance_header(&mut resp_headers, &state.instance_id);
        return Ok((status, resp_headers, Json(body)));
    }

    let existing_version = sqlx::query_scalar::<_, i32>(
        "SELECT version FROM clearledger.settlements WHERE settlement_id = $1 FOR UPDATE",
    )
    .bind(req.settlement_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    if existing_version.is_some() {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "version_conflict",
            "Settlement already exists",
        ));
    }

    let now = Utc::now();
    let event_id = Uuid::new_v4();
    let version = 1;
    let initial_stage = format!("INITIATED@{}", req.debit_party.trim());

    let envelope = DomainEventEnvelope {
        schema_version: "1.0".to_string(),
        event_id,
        event_type: "SettlementInitiated".to_string(),
        aggregate_type: "settlement".to_string(),
        aggregate_id: req.settlement_id,
        aggregate_version: version,
        occurred_at: now,
        correlation_id: correlation_id.clone(),
        idempotency_key: idempotency_key.clone(),
        data: DomainEventData {
            kind: "settlementInitiated".to_string(),
            account_id: req.account_id.trim().to_string(),
            reference: Some(req.reference.trim().to_string()),
            debit_party: Some(req.debit_party.trim().to_string()),
            credit_party: Some(req.credit_party.trim().to_string()),
            entry_id: None,
            status: SettlementStatus::Initiated,
            clearing_stage: initial_stage.clone(),
            memo: Some("Settlement initiated".to_string()),
        },
    };

    let envelope_json = serde_json::to_value(&envelope).map_err(|err| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "serialization_error",
            err.to_string(),
        )
    })?;

    sqlx::query(
        r#"
        INSERT INTO clearledger.settlements (
            settlement_id, account_id, reference, debit_party, credit_party,
            current_status, current_stage, last_entry_id, last_memo,
            version, entry_count, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, $8, $9, 0, $10, $10)
        "#,
    )
    .bind(req.settlement_id)
    .bind(req.account_id.trim())
    .bind(req.reference.trim())
    .bind(req.debit_party.trim())
    .bind(req.credit_party.trim())
    .bind(SettlementStatus::Initiated.as_str())
    .bind(&initial_stage)
    .bind("Settlement initiated")
    .bind(version)
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    sqlx::query(
        r#"
        INSERT INTO clearledger.events (
            event_id, settlement_id, aggregate_version, event_type,
            correlation_id, idempotency_key, occurred_at, payload
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        "#,
    )
    .bind(event_id)
    .bind(req.settlement_id)
    .bind(version)
    .bind("SettlementInitiated")
    .bind(&correlation_id)
    .bind(&idempotency_key)
    .bind(now)
    .bind(&envelope_json)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    sqlx::query(
        r#"
        INSERT INTO clearledger.outbox (
            event_id, settlement_id, aggregate_version, correlation_id, payload
        ) VALUES ($1, $2, $3, $4, $5)
        "#,
    )
    .bind(event_id)
    .bind(req.settlement_id)
    .bind(version)
    .bind(&correlation_id)
    .bind(&envelope_json)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    let response_payload = WriteAcceptedResponse {
        settlement_id: req.settlement_id,
        event_id,
        version,
        accepted: true,
        idempotent_replay: false,
    };
    let response_value = serde_json::to_value(&response_payload).unwrap();

    sqlx::query(
        r#"
        INSERT INTO clearledger.idempotency_keys (
            scope, idempotency_key, request_hash, status_code, response_body
        ) VALUES ($1, $2, $3, $4, $5)
        "#,
    )
    .bind(&idem_scope)
    .bind(&idempotency_key)
    .bind(&req_hash)
    .bind(StatusCode::CREATED.as_u16() as i32)
    .bind(&response_value)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    tx.commit().await.map_err(|err| {
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string())
    })?;

    invalidate_valkey_cache(&state, req.settlement_id).await;
    best_effort_publish_outbox_event(&state, &envelope).await;

    info!(
        settlement_id = %req.settlement_id,
        event_id = %event_id,
        version = version,
        correlation_id = %correlation_id,
        instance = %state.instance_id,
        "settlement initiated"
    );
    state
        .cw
        .emit_json(json!({
            "service": "clearledger-api",
            "action": "create_settlement",
            "settlementId": req.settlement_id,
            "eventId": event_id,
            "version": version,
            "correlationId": correlation_id,
            "instance": state.instance_id,
            "timestamp": Utc::now().to_rfc3339(),
        }))
        .await;

    let mut resp_headers = HeaderMap::new();
    attach_instance_header(&mut resp_headers, &state.instance_id);
    Ok((StatusCode::CREATED, resp_headers, Json(response_value)))
}

async fn append_entry(
    State(state): State<Arc<AppState>>,
    Path(settlement_id): Path<Uuid>,
    headers: HeaderMap,
    Json(req): Json<AppendEntryRequest>,
) -> Result<impl IntoResponse, ApiError> {
    authenticate(&state, &headers, "clearledger/write").await?;
    let idempotency_key = extract_idempotency_key(&headers)?;
    let correlation_id = extract_correlation_id(&headers);

    if req.expected_version < 1 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_expected_version",
            "expectedVersion must be >= 1 when appending a ledger entry",
        ));
    }
    if req.status == SettlementStatus::Initiated {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_status",
            "Ledger entry cannot transition back to INITIATED",
        ));
    }
    if req.clearing_stage.trim().len() < 2 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_clearing_stage",
            "clearingStage must be at least 2 characters",
        ));
    }

    let canonical_req = json!({
        "settlementId": settlement_id,
        "entryId": req.entry_id,
        "status": req.status.as_str(),
        "clearingStage": req.clearing_stage.trim(),
        "memo": req.memo.as_deref().unwrap_or(""),
        "occurredAt": req.occurred_at.to_rfc3339(),
        "expectedVersion": req.expected_version,
    });
    let req_hash = sha256_hex(canonical_req.to_string().as_bytes());
    let idem_scope = format!("entry:{settlement_id}");

    let mut tx = state.pool.begin().await.map_err(|err| {
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string())
    })?;

    let lock_key = settlement_id.as_u128() as i64;
    sqlx::query("SELECT pg_advisory_xact_lock($1)")
        .bind(lock_key)
        .execute(&mut *tx)
        .await
        .map_err(|err| {
            ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string())
        })?;

    if let Some((status, body)) =
        check_idempotency(&mut tx, &idem_scope, &idempotency_key, &req_hash).await?
    {
        tx.commit().await.ok();
        let mut resp_headers = HeaderMap::new();
        attach_instance_header(&mut resp_headers, &state.instance_id);
        return Ok((status, resp_headers, Json(body)));
    }

    let row = sqlx::query(
        "SELECT account_id, reference, debit_party, credit_party, version, entry_count FROM clearledger.settlements WHERE settlement_id = $1 FOR UPDATE",
    )
    .bind(settlement_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    let Some(row) = row else {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "settlement_not_found",
            format!("Settlement {settlement_id} not found"),
        ));
    };

    let current_version: i32 = row.get("version");
    if current_version != req.expected_version {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "version_conflict",
            format!(
                "Expected version {}, but current version is {}",
                req.expected_version, current_version
            ),
        ));
    }

    let account_id: String = row.get("account_id");
    let reference: String = row.get("reference");
    let debit_party: String = row.get("debit_party");
    let credit_party: String = row.get("credit_party");
    let entry_count: i32 = row.get("entry_count");

    let next_version = current_version + 1;
    let next_entry_count = entry_count + 1;
    let event_id = Uuid::new_v4();

    let envelope = DomainEventEnvelope {
        schema_version: "1.0".to_string(),
        event_id,
        event_type: "LedgerEntryRecorded".to_string(),
        aggregate_type: "settlement".to_string(),
        aggregate_id: settlement_id,
        aggregate_version: next_version,
        occurred_at: req.occurred_at,
        correlation_id: correlation_id.clone(),
        idempotency_key: idempotency_key.clone(),
        data: DomainEventData {
            kind: "ledgerEntryRecorded".to_string(),
            account_id,
            reference: Some(reference),
            debit_party: Some(debit_party),
            credit_party: Some(credit_party),
            entry_id: Some(req.entry_id),
            status: req.status.clone(),
            clearing_stage: req.clearing_stage.trim().to_string(),
            memo: req.memo.clone(),
        },
    };

    let envelope_json = serde_json::to_value(&envelope).map_err(|err| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "serialization_error",
            err.to_string(),
        )
    })?;

    sqlx::query(
        r#"
        UPDATE clearledger.settlements
        SET current_status = $2,
            current_stage = $3,
            last_entry_id = $4,
            last_memo = $5,
            version = $6,
            entry_count = $7,
            updated_at = $8
        WHERE settlement_id = $1
        "#,
    )
    .bind(settlement_id)
    .bind(req.status.as_str())
    .bind(req.clearing_stage.trim())
    .bind(req.entry_id)
    .bind(&req.memo)
    .bind(next_version)
    .bind(next_entry_count)
    .bind(req.occurred_at)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    sqlx::query(
        r#"
        INSERT INTO clearledger.events (
            event_id, settlement_id, aggregate_version, event_type,
            correlation_id, idempotency_key, occurred_at, payload
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        "#,
    )
    .bind(event_id)
    .bind(settlement_id)
    .bind(next_version)
    .bind("LedgerEntryRecorded")
    .bind(&correlation_id)
    .bind(&idempotency_key)
    .bind(req.occurred_at)
    .bind(&envelope_json)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    sqlx::query(
        r#"
        INSERT INTO clearledger.outbox (
            event_id, settlement_id, aggregate_version, correlation_id, payload
        ) VALUES ($1, $2, $3, $4, $5)
        "#,
    )
    .bind(event_id)
    .bind(settlement_id)
    .bind(next_version)
    .bind(&correlation_id)
    .bind(&envelope_json)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    let response_payload = WriteAcceptedResponse {
        settlement_id,
        event_id,
        version: next_version,
        accepted: true,
        idempotent_replay: false,
    };
    let response_value = serde_json::to_value(&response_payload).unwrap();

    sqlx::query(
        r#"
        INSERT INTO clearledger.idempotency_keys (
            scope, idempotency_key, request_hash, status_code, response_body
        ) VALUES ($1, $2, $3, $4, $5)
        "#,
    )
    .bind(&idem_scope)
    .bind(&idempotency_key)
    .bind(&req_hash)
    .bind(StatusCode::ACCEPTED.as_u16() as i32)
    .bind(&response_value)
    .execute(&mut *tx)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    tx.commit().await.map_err(|err| {
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string())
    })?;

    invalidate_valkey_cache(&state, settlement_id).await;
    best_effort_publish_outbox_event(&state, &envelope).await;

    info!(
        settlement_id = %settlement_id,
        entry_id = %req.entry_id,
        event_id = %event_id,
        version = next_version,
        correlation_id = %correlation_id,
        instance = %state.instance_id,
        "ledger entry recorded"
    );
    state
        .cw
        .emit_json(json!({
            "service": "clearledger-api",
            "action": "append_entry",
            "settlementId": settlement_id,
            "entryId": req.entry_id,
            "eventId": event_id,
            "version": next_version,
            "correlationId": correlation_id,
            "instance": state.instance_id,
            "timestamp": Utc::now().to_rfc3339(),
        }))
        .await;

    let mut resp_headers = HeaderMap::new();
    attach_instance_header(&mut resp_headers, &state.instance_id);
    Ok((StatusCode::ACCEPTED, resp_headers, Json(response_value)))
}

async fn get_settlement(
    State(state): State<Arc<AppState>>,
    Path(settlement_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    authenticate(&state, &headers, "clearledger/read").await?;
    let correlation_id = extract_correlation_id(&headers);
    let cache_key = valkey_settlement_key(settlement_id);

    if let Ok(mut conn) = state.redis_client.get_multiplexed_async_connection().await {
        let cached: redis::RedisResult<Option<String>> = conn.get(&cache_key).await;
        if let Ok(Some(cached_json)) = cached {
            if let Ok(projection) =
                serde_json::from_str::<clearledger::SettlementProjection>(&cached_json)
            {
                let mut resp_headers = HeaderMap::new();
                resp_headers.insert("X-ClearLedger-Source", HeaderValue::from_static("cache"));
                if let Ok(ver) = HeaderValue::from_str(&projection.version.to_string()) {
                    resp_headers.insert("X-ClearLedger-Version", ver);
                }
                attach_instance_header(&mut resp_headers, &state.instance_id);
                return Ok((StatusCode::OK, resp_headers, Json(projection)));
            }
        }
    }

    let projection =
        fetch_projection_from_dynamodb(&state.ddb, &state.projection_table, settlement_id)
            .await
            .map_err(|err| {
                error!(error = %err, %settlement_id, "failed reading DynamoDB projection");
                ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "projection_error",
                    err.to_string(),
                )
            })?
            .ok_or_else(|| {
                ApiError::new(
                    StatusCode::NOT_FOUND,
                    "projection_not_found",
                    format!("Projection for settlement {settlement_id} not found"),
                )
            })?;

    if let Ok(serialized) = serde_json::to_string(&projection) {
        if let Ok(mut conn) = state.redis_client.get_multiplexed_async_connection().await {
            let _: redis::RedisResult<()> = conn
                .set_ex(&cache_key, serialized, state.cache_ttl_seconds)
                .await;
        }
    }

    state
        .cw
        .emit_json(json!({
            "service": "clearledger-api",
            "action": "get_settlement",
            "settlementId": settlement_id,
            "version": projection.version,
            "source": "projection",
            "correlationId": correlation_id,
            "instance": state.instance_id,
            "timestamp": Utc::now().to_rfc3339(),
        }))
        .await;

    let mut resp_headers = HeaderMap::new();
    resp_headers.insert(
        "X-ClearLedger-Source",
        HeaderValue::from_static("projection"),
    );
    if let Ok(ver) = HeaderValue::from_str(&projection.version.to_string()) {
        resp_headers.insert("X-ClearLedger-Version", ver);
    }
    attach_instance_header(&mut resp_headers, &state.instance_id);
    Ok((StatusCode::OK, resp_headers, Json(projection)))
}

async fn get_settlement_ledger(
    State(state): State<Arc<AppState>>,
    Path(settlement_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    authenticate(&state, &headers, "clearledger/read").await?;
    let ledger = fetch_ledger_from_dynamodb(&state.ddb, &state.projection_table, settlement_id)
        .await
        .map_err(|err| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "projection_error",
                err.to_string(),
            )
        })?
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::NOT_FOUND,
                "ledger_not_found",
                format!("Ledger for settlement {settlement_id} not found"),
            )
        })?;

    let mut resp_headers = HeaderMap::new();
    resp_headers.insert(
        "X-ClearLedger-Source",
        HeaderValue::from_static("projection"),
    );
    if let Ok(ver) = HeaderValue::from_str(&ledger.version.to_string()) {
        resp_headers.insert("X-ClearLedger-Version", ver);
    }
    attach_instance_header(&mut resp_headers, &state.instance_id);
    Ok((StatusCode::OK, resp_headers, Json(ledger)))
}

async fn rebuild_projection(
    State(state): State<Arc<AppState>>,
    Path(settlement_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    authenticate(&state, &headers, "clearledger/admin").await?;
    let correlation_id = extract_correlation_id(&headers);

    let rows = sqlx::query(
        "SELECT payload FROM clearledger.events WHERE settlement_id = $1 ORDER BY aggregate_version ASC",
    )
    .bind(settlement_id)
    .fetch_all(&state.pool)
    .await
    .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "db_error", err.to_string()))?;

    if rows.is_empty() {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "settlement_not_found",
            format!("Settlement {settlement_id} does not exist in PostgreSQL"),
        ));
    }

    invalidate_valkey_cache(&state, settlement_id).await;

    let mut requeued = 0usize;
    for row in rows {
        let payload: Value = row.get("payload");
        let body = payload.to_string();
        state
            .sqs
            .send_message()
            .queue_url(&state.queue_url)
            .message_body(body)
            .send()
            .await
            .map_err(|err| {
                ApiError::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "sqs_unavailable",
                    format!("Failed to enqueue rebuild event: {err}"),
                )
            })?;
        requeued += 1;
    }

    info!(
        settlement_id = %settlement_id,
        requeued = requeued,
        correlation_id = %correlation_id,
        "projection rebuild events enqueued"
    );
    state
        .cw
        .emit_json(json!({
            "service": "clearledger-api",
            "action": "rebuild_projection",
            "settlementId": settlement_id,
            "requeued": requeued,
            "correlationId": correlation_id,
            "instance": state.instance_id,
            "timestamp": Utc::now().to_rfc3339(),
        }))
        .await;

    let mut resp_headers = HeaderMap::new();
    attach_instance_header(&mut resp_headers, &state.instance_id);
    Ok((
        StatusCode::ACCEPTED,
        resp_headers,
        Json(RebuildResponse {
            settlement_id,
            requeued,
        }),
    ))
}
