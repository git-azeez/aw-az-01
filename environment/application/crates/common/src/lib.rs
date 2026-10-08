use std::{
    collections::HashMap,
    env,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Context, Result};
use aws_config::{BehaviorVersion, Region};
use aws_credential_types::Credentials;
use aws_sdk_dynamodb::{types::AttributeValue, Client as DynamoDbClient};
use chrono::{DateTime, Utc};
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use reqwest::Client as HttpClient;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use sqlx::{postgres::PgPoolOptions, PgPool};
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SettlementStatus {
    Initiated,
    Validated,
    Reserved,
    Cleared,
    Settled,
    Reconciled,
    Disputed,
}

impl SettlementStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Initiated => "INITIATED",
            Self::Validated => "VALIDATED",
            Self::Reserved => "RESERVED",
            Self::Cleared => "CLEARED",
            Self::Settled => "SETTLED",
            Self::Reconciled => "RECONCILED",
            Self::Disputed => "DISPUTED",
        }
    }

    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "INITIATED" => Ok(Self::Initiated),
            "VALIDATED" => Ok(Self::Validated),
            "RESERVED" => Ok(Self::Reserved),
            "CLEARED" => Ok(Self::Cleared),
            "SETTLED" => Ok(Self::Settled),
            "RECONCILED" => Ok(Self::Reconciled),
            "DISPUTED" => Ok(Self::Disputed),
            other => bail!("unsupported settlement status: {other}"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSettlementRequest {
    pub settlement_id: Uuid,
    pub account_id: String,
    pub reference: String,
    pub debit_party: String,
    pub credit_party: String,
    pub expected_version: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppendEntryRequest {
    pub entry_id: Uuid,
    pub status: SettlementStatus,
    pub clearing_stage: String,
    #[serde(default)]
    pub memo: Option<String>,
    pub occurred_at: DateTime<Utc>,
    pub expected_version: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteAcceptedResponse {
    pub settlement_id: Uuid,
    pub event_id: Uuid,
    pub version: i32,
    pub accepted: bool,
    pub idempotent_replay: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettlementProjection {
    pub settlement_id: Uuid,
    pub account_id: String,
    pub reference: String,
    pub debit_party: String,
    pub credit_party: String,
    pub status: SettlementStatus,
    pub clearing_stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_entry_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_memo: Option<String>,
    pub version: i32,
    pub entry_count: i32,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettlementLedgerItem {
    pub event_id: Uuid,
    pub version: i32,
    pub event_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry_id: Option<Uuid>,
    pub status: String,
    pub clearing_stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memo: Option<String>,
    pub occurred_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettlementLedgerResponse {
    pub settlement_id: Uuid,
    pub version: i32,
    pub events: Vec<SettlementLedgerItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RebuildResponse {
    pub settlement_id: Uuid,
    pub requeued: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DomainEventEnvelope {
    pub schema_version: String,
    pub event_id: Uuid,
    pub event_type: String,
    pub aggregate_type: String,
    pub aggregate_id: Uuid,
    pub aggregate_version: i32,
    pub occurred_at: DateTime<Utc>,
    pub correlation_id: String,
    pub idempotency_key: String,
    pub data: DomainEventData,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DomainEventData {
    pub kind: String,
    pub account_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub debit_party: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credit_party: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry_id: Option<Uuid>,
    pub status: SettlementStatus,
    pub clearing_stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memo: Option<String>,
}

pub fn validate_envelope(envelope: &DomainEventEnvelope) -> Result<()> {
    if envelope.schema_version != "1.0" {
        bail!("invalid schemaVersion: {}", envelope.schema_version);
    }
    if envelope.aggregate_type != "settlement" {
        bail!("invalid aggregateType: {}", envelope.aggregate_type);
    }
    if envelope.aggregate_version < 1 {
        bail!("aggregateVersion must be >= 1");
    }
    if envelope.correlation_id.trim().len() < 4 {
        bail!("correlationId too short");
    }
    if envelope.idempotency_key.trim().len() < 8 {
        bail!("idempotencyKey too short");
    }
    if envelope.data.account_id.trim().len() < 3 {
        bail!("accountId too short");
    }
    if envelope.data.clearing_stage.trim().len() < 2 {
        bail!("clearingStage too short");
    }
    match envelope.event_type.as_str() {
        "SettlementInitiated" => {
            if envelope.aggregate_version != 1 {
                bail!("SettlementInitiated must have aggregateVersion == 1");
            }
            if envelope.data.kind != "settlementInitiated" {
                bail!("SettlementInitiated requires data.kind == settlementInitiated");
            }
            if envelope.data.status != SettlementStatus::Initiated {
                bail!("SettlementInitiated requires INITIATED status");
            }
        }
        "LedgerEntryRecorded" => {
            if envelope.aggregate_version < 2 {
                bail!("LedgerEntryRecorded must have aggregateVersion >= 2");
            }
            if envelope.data.kind != "ledgerEntryRecorded" {
                bail!("LedgerEntryRecorded requires data.kind == ledgerEntryRecorded");
            }
            if envelope.data.entry_id.is_none() {
                bail!("LedgerEntryRecorded requires entryId");
            }
        }
        other => bail!("unsupported eventType: {other}"),
    }
    Ok(())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn resolve_reachable_host(host: &str) -> String {
    use std::net::ToSocketAddrs;
    if (host, 4566).to_socket_addrs().is_ok() {
        return host.to_string();
    }
    if let Ok(ip) = env::var("CLEARLEDGER_AWS_IP") {
        let trimmed = ip.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    host.to_string()
}

pub fn init_runtime_env() {
    let no_proxy = "localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal";
    // SAFETY: invoked at process startup before serving requests or Lambda invocations.
    unsafe {
        for key in [
            "HTTP_PROXY",
            "http_proxy",
            "HTTPS_PROXY",
            "https_proxy",
            "ALL_PROXY",
            "all_proxy",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
            "AWS_WEB_IDENTITY_TOKEN_FILE",
            "AWS_ROLE_ARN",
            "AWS_PROFILE",
            "AWS_DEFAULT_PROFILE",
        ] {
            env::remove_var(key);
        }
        env::set_var("NO_PROXY", no_proxy);
        env::set_var("no_proxy", no_proxy);
        env::set_var("AWS_EC2_METADATA_DISABLED", "true");
        if let Ok(runtime_api) = env::var("AWS_LAMBDA_RUNTIME_API") {
            let (host, port) = runtime_api
                .split_once(':')
                .unwrap_or((runtime_api.as_str(), "9001"));
            let resolved = resolve_reachable_host(host);
            if resolved != host {
                env::set_var("AWS_LAMBDA_RUNTIME_API", format!("{resolved}:{port}"));
            }
        }
    }
}

pub fn aws_endpoint_url() -> String {
    let raw = env::var("AWS_ENDPOINT_URL")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "http://aws:4566".to_string());
    let (scheme, rest) = if let Some(r) = raw.strip_prefix("https://") {
        ("https://", r)
    } else if let Some(r) = raw.strip_prefix("http://") {
        ("http://", r)
    } else {
        ("http://", raw.as_str())
    };
    let host_port = rest.split('/').next().unwrap_or("aws:4566");
    let (host, port) = host_port.split_once(':').unwrap_or((host_port, "4566"));
    let target_host = if host == "localhost"
        || host == "127.0.0.1"
        || host.contains(".amazonaws.com")
        || host.ends_with(".local")
        || host.ends_with(".internal")
    {
        resolve_reachable_host("aws")
    } else {
        resolve_reachable_host(host)
    };
    format!("{scheme}{target_host}:{port}")
}

pub fn aws_endpoint_host() -> String {
    let ep = aws_endpoint_url();
    let without_scheme = ep
        .strip_prefix("http://")
        .or_else(|| ep.strip_prefix("https://"))
        .unwrap_or(&ep);
    without_scheme
        .split('/')
        .next()
        .unwrap_or("aws:4566")
        .split(':')
        .next()
        .unwrap_or("aws")
        .to_string()
}

pub fn normalize_http_endpoint_url(raw: &str) -> String {
    let trimmed = raw.trim();
    let ep_base = aws_endpoint_url();
    let ep_base = ep_base.trim_end_matches('/');
    if let Some(rest) = trimmed
        .strip_prefix("http://")
        .or_else(|| trimmed.strip_prefix("https://"))
    {
        let (host_port, path_part) = match rest.split_once('/') {
            Some((hp, p)) => (hp, format!("/{p}")),
            None => (rest, String::new()),
        };
        let host = host_port.split(':').next().unwrap_or(host_port);
        if host == "localhost"
            || host == "127.0.0.1"
            || host == "aws"
            || host.contains(".amazonaws.com")
            || host.ends_with(".local")
            || host.ends_with(".internal")
        {
            return format!("{ep_base}{path_part}");
        }
    }
    trimmed.to_string()
}

pub fn normalize_database_url(raw: &str) -> String {
    let proxy_host = aws_endpoint_host();
    if let Some((prefix, rest)) = raw.rsplit_once('@') {
        if let Some((host_port, path_part)) = rest.split_once('/') {
            let (host, port) = host_port.split_once(':').unwrap_or((host_port, "5432"));
            if host == "localhost"
                || host == "127.0.0.1"
                || host == "aws"
                || host.contains(".amazonaws.com")
                || host.contains(".rds.")
                || host.ends_with(".local")
                || host.ends_with(".internal")
            {
                return format!("{prefix}@{proxy_host}:{port}/{path_part}");
            }
        }
    }
    raw.to_string()
}

pub fn normalize_valkey_url(raw: &str) -> String {
    let proxy_host = aws_endpoint_host();
    let with_scheme = if raw.starts_with("redis://") || raw.starts_with("rediss://") {
        raw.to_string()
    } else {
        format!("redis://{raw}")
    };
    if let Some(rest) = with_scheme.strip_prefix("redis://") {
        let (host_port, suffix) = match rest.split_once('/') {
            Some((hp, s)) => (hp, format!("/{s}")),
            None => (rest, String::new()),
        };
        let (host, port) = host_port.split_once(':').unwrap_or((host_port, "6379"));
        if host == "localhost"
            || host == "127.0.0.1"
            || host == "aws"
            || host.contains(".amazonaws.com")
            || host.contains(".cache.")
            || host.ends_with(".local")
            || host.ends_with(".internal")
        {
            return format!("redis://{proxy_host}:{port}{suffix}");
        }
    }
    with_scheme
}

pub async fn build_aws_config() -> aws_config::SdkConfig {
    init_runtime_env();
    let region = env::var("AWS_REGION")
        .or_else(|_| env::var("AWS_DEFAULT_REGION"))
        .unwrap_or_else(|_| "us-east-1".to_string());
    let endpoint = aws_endpoint_url();
    let access_key = env::var("AWS_ACCESS_KEY_ID")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "test".to_string());
    let secret_key = env::var("AWS_SECRET_ACCESS_KEY")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "test".to_string());

    let retry_config = aws_config::retry::RetryConfig::standard().with_max_attempts(2);
    let timeout_config = aws_config::timeout::TimeoutConfig::builder()
        .connect_timeout(Duration::from_secs(2))
        .operation_timeout(Duration::from_secs(5))
        .operation_attempt_timeout(Duration::from_secs(3))
        .build();

    tracing::info!(
        aws_endpoint = %endpoint,
        aws_region = %region,
        credential_provider = "clearledger-static",
        "resolved AWS SDK configuration"
    );

    aws_config::defaults(BehaviorVersion::latest())
        .region(Region::new(region))
        .endpoint_url(endpoint)
        .retry_config(retry_config)
        .timeout_config(timeout_config)
        .credentials_provider(Credentials::new(
            access_key,
            secret_key,
            env::var("AWS_SESSION_TOKEN")
                .ok()
                .filter(|v| !v.trim().is_empty()),
            None,
            "clearledger-static",
        ))
        .load()
        .await
}

pub async fn connect_postgres(database_url: &str) -> Result<PgPool> {
    let normalized = normalize_database_url(database_url);
    match PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(10))
        .connect(&normalized)
        .await
    {
        Ok(pool) => Ok(pool),
        Err(first_err) if normalized != database_url => PgPoolOptions::new()
            .max_connections(10)
            .acquire_timeout(Duration::from_secs(10))
            .connect(database_url)
            .await
            .with_context(|| format!("failed to connect to PostgreSQL ({first_err})")),
        Err(err) => Err(err).context("failed to connect to PostgreSQL"),
    }
}

pub async fn verify_postgres_schema(pool: &PgPool) -> bool {
    let tables_ok = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'clearledger' AND table_name IN ('settlements', 'events', 'outbox', 'idempotency_keys')",
    )
    .fetch_one(pool)
    .await
    .map(|count| count == 4)
    .unwrap_or(false);
    if !tables_ok {
        return false;
    }
    let indexes_ok = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'clearledger' AND indexname IN ('idx_clearledger_outbox_unpublished', 'idx_clearledger_outbox_unarchived', 'idx_clearledger_events_settlement_version')",
    )
    .fetch_one(pool)
    .await
    .map(|count| count == 3)
    .unwrap_or(false);
    if !indexes_ok {
        return false;
    }
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(DISTINCT c.relname) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'clearledger' AND NOT t.tgisinternal AND c.relname IN ('settlements', 'events', 'outbox', 'idempotency_keys')",
    )
    .fetch_one(pool)
    .await
    .map(|count| count == 4)
    .unwrap_or(false)
}

pub fn projection_pk(settlement_id: Uuid) -> String {
    format!("SETTLEMENT#{settlement_id}")
}

pub fn projection_state_sk() -> &'static str {
    "STATE"
}

pub fn projection_event_sk(version: i32) -> String {
    format!("EVENT#{version:08}")
}

pub fn valkey_settlement_key(settlement_id: Uuid) -> String {
    format!("clearledger:settlement:{settlement_id}")
}

fn is_ddb_conditional_failure<E: std::fmt::Debug>(
    err: &aws_sdk_dynamodb::error::SdkError<E>,
) -> bool {
    format!("{err:?}").contains("ConditionalCheckFailed")
}

pub async fn apply_event_to_dynamodb(
    ddb: &DynamoDbClient,
    table_name: &str,
    envelope: &DomainEventEnvelope,
) -> Result<bool> {
    validate_envelope(envelope)?;
    let pk = projection_pk(envelope.aggregate_id);
    let event_sk = projection_event_sk(envelope.aggregate_version);
    let envelope_json = serde_json::to_string(envelope)?;

    let mut event_item = HashMap::new();
    event_item.insert("PK".to_string(), AttributeValue::S(pk.clone()));
    event_item.insert("SK".to_string(), AttributeValue::S(event_sk));
    event_item.insert(
        "settlement_id".to_string(),
        AttributeValue::S(envelope.aggregate_id.to_string()),
    );
    event_item.insert(
        "event_id".to_string(),
        AttributeValue::S(envelope.event_id.to_string()),
    );
    event_item.insert(
        "version".to_string(),
        AttributeValue::N(envelope.aggregate_version.to_string()),
    );
    event_item.insert(
        "event_type".to_string(),
        AttributeValue::S(envelope.event_type.clone()),
    );
    event_item.insert(
        "status".to_string(),
        AttributeValue::S(envelope.data.status.as_str().to_string()),
    );
    event_item.insert(
        "clearing_stage".to_string(),
        AttributeValue::S(envelope.data.clearing_stage.clone()),
    );
    event_item.insert(
        "occurred_at".to_string(),
        AttributeValue::S(envelope.occurred_at.to_rfc3339()),
    );
    event_item.insert(
        "correlation_id".to_string(),
        AttributeValue::S(envelope.correlation_id.clone()),
    );
    event_item.insert("envelope".to_string(), AttributeValue::S(envelope_json));
    if let Some(entry_id) = envelope.data.entry_id {
        event_item.insert(
            "entry_id".to_string(),
            AttributeValue::S(entry_id.to_string()),
        );
    }
    if let Some(memo) = &envelope.data.memo {
        event_item.insert("memo".to_string(), AttributeValue::S(memo.clone()));
    }

    if let Err(err) = ddb
        .put_item()
        .table_name(table_name)
        .set_item(Some(event_item))
        .condition_expression("attribute_not_exists(PK) AND attribute_not_exists(SK)")
        .send()
        .await
    {
        if !is_ddb_conditional_failure(&err) {
            return Err(anyhow::Error::new(err).context("failed to put event item in DynamoDB"));
        }
    }

    for _attempt in 0..16 {
        let existing = ddb
            .get_item()
            .table_name(table_name)
            .key("PK", AttributeValue::S(pk.clone()))
            .key("SK", AttributeValue::S(projection_state_sk().to_string()))
            .consistent_read(true)
            .send()
            .await
            .context("failed reading current projection state from DynamoDB")?
            .item;

        let current_version = existing
            .as_ref()
            .and_then(|item| item.get("version"))
            .and_then(|v| v.as_n().ok())
            .and_then(|n| n.parse::<i32>().ok())
            .unwrap_or(0);

        if envelope.aggregate_version == current_version {
            return Ok(false);
        }

        if envelope.aggregate_version < current_version {
            if let Some(mut current_item) = existing {
                let mut backfilled = false;
                for (field, candidate) in [
                    ("reference", envelope.data.reference.as_ref()),
                    ("debit_party", envelope.data.debit_party.as_ref()),
                    ("credit_party", envelope.data.credit_party.as_ref()),
                ] {
                    let is_unknown = current_item
                        .get(field)
                        .and_then(|v| v.as_s().ok())
                        .map(|s| s == "UNKNOWN")
                        .unwrap_or(true);
                    if is_unknown {
                        if let Some(val) = candidate {
                            current_item
                                .insert(field.to_string(), AttributeValue::S((*val).clone()));
                            backfilled = true;
                        }
                    }
                }
                if !backfilled {
                    return Ok(false);
                }
                match ddb
                    .put_item()
                    .table_name(table_name)
                    .set_item(Some(current_item))
                    .condition_expression("#version = :expected_version")
                    .expression_attribute_names("#version", "version")
                    .expression_attribute_values(
                        ":expected_version",
                        AttributeValue::N(current_version.to_string()),
                    )
                    .send()
                    .await
                {
                    Ok(_) => return Ok(true),
                    Err(err) if is_ddb_conditional_failure(&err) => continue,
                    Err(err) => {
                        return Err(anyhow::Error::new(err)
                            .context("failed to backfill metadata on STATE projection in DynamoDB"));
                    }
                }
            }
            return Ok(false);
        }

        let account_id = existing
            .as_ref()
            .and_then(|item| item.get("account_id"))
            .and_then(|v| v.as_s().ok())
            .cloned()
            .unwrap_or_else(|| envelope.data.account_id.clone());

        let reference = envelope
            .data
            .reference
            .clone()
            .or_else(|| {
                existing
                    .as_ref()
                    .and_then(|item| item.get("reference"))
                    .and_then(|v| v.as_s().ok())
                    .filter(|s| *s != "UNKNOWN")
                    .cloned()
            })
            .unwrap_or_else(|| "UNKNOWN".to_string());

        let debit_party = envelope
            .data
            .debit_party
            .clone()
            .or_else(|| {
                existing
                    .as_ref()
                    .and_then(|item| item.get("debit_party"))
                    .and_then(|v| v.as_s().ok())
                    .filter(|s| *s != "UNKNOWN")
                    .cloned()
            })
            .unwrap_or_else(|| "UNKNOWN".to_string());

        let credit_party = envelope
            .data
            .credit_party
            .clone()
            .or_else(|| {
                existing
                    .as_ref()
                    .and_then(|item| item.get("credit_party"))
                    .and_then(|v| v.as_s().ok())
                    .filter(|s| *s != "UNKNOWN")
                    .cloned()
            })
            .unwrap_or_else(|| "UNKNOWN".to_string());

        let entry_count = if envelope.aggregate_version <= 1 {
            0
        } else {
            envelope.aggregate_version - 1
        };

        let mut state_item = HashMap::new();
        state_item.insert("PK".to_string(), AttributeValue::S(pk.clone()));
        state_item.insert(
            "SK".to_string(),
            AttributeValue::S(projection_state_sk().to_string()),
        );
        state_item.insert(
            "GSI1PK".to_string(),
            AttributeValue::S(format!("ACCOUNT#{account_id}")),
        );
        state_item.insert(
            "GSI1SK".to_string(),
            AttributeValue::S(format!("SETTLEMENT#{}", envelope.aggregate_id)),
        );
        state_item.insert(
            "settlement_id".to_string(),
            AttributeValue::S(envelope.aggregate_id.to_string()),
        );
        state_item.insert("account_id".to_string(), AttributeValue::S(account_id));
        state_item.insert("reference".to_string(), AttributeValue::S(reference));
        state_item.insert("debit_party".to_string(), AttributeValue::S(debit_party));
        state_item.insert("credit_party".to_string(), AttributeValue::S(credit_party));
        state_item.insert(
            "status".to_string(),
            AttributeValue::S(envelope.data.status.as_str().to_string()),
        );
        state_item.insert(
            "clearing_stage".to_string(),
            AttributeValue::S(envelope.data.clearing_stage.clone()),
        );
        state_item.insert(
            "version".to_string(),
            AttributeValue::N(envelope.aggregate_version.to_string()),
        );
        state_item.insert(
            "entry_count".to_string(),
            AttributeValue::N(entry_count.to_string()),
        );
        state_item.insert(
            "updated_at".to_string(),
            AttributeValue::S(envelope.occurred_at.to_rfc3339()),
        );

        if let Some(entry_id) = envelope.data.entry_id {
            state_item.insert(
                "last_entry_id".to_string(),
                AttributeValue::S(entry_id.to_string()),
            );
        } else if let Some(prev_entry) = existing
            .as_ref()
            .and_then(|item| item.get("last_entry_id"))
            .and_then(|v| v.as_s().ok())
        {
            state_item.insert(
                "last_entry_id".to_string(),
                AttributeValue::S(prev_entry.clone()),
            );
        }

        if let Some(memo) = &envelope.data.memo {
            state_item.insert("last_memo".to_string(), AttributeValue::S(memo.clone()));
        } else if let Some(prev_memo) = existing
            .as_ref()
            .and_then(|item| item.get("last_memo"))
            .and_then(|v| v.as_s().ok())
        {
            state_item.insert("last_memo".to_string(), AttributeValue::S(prev_memo.clone()));
        }

        let put_req = if existing.is_none() {
            ddb.put_item()
                .table_name(table_name)
                .set_item(Some(state_item))
                .condition_expression("attribute_not_exists(PK) AND attribute_not_exists(SK)")
        } else {
            ddb.put_item()
                .table_name(table_name)
                .set_item(Some(state_item))
                .condition_expression("#version = :expected_version AND #version < :new_version")
                .expression_attribute_names("#version", "version")
                .expression_attribute_values(
                    ":expected_version",
                    AttributeValue::N(current_version.to_string()),
                )
                .expression_attribute_values(
                    ":new_version",
                    AttributeValue::N(envelope.aggregate_version.to_string()),
                )
        };

        match put_req.send().await {
            Ok(_) => return Ok(true),
            Err(err) if is_ddb_conditional_failure(&err) => continue,
            Err(err) => {
                return Err(
                    anyhow::Error::new(err).context("failed to put STATE projection in DynamoDB")
                );
            }
        }
    }

    bail!(
        "exhausted optimistic concurrency retries updating projection state for settlement {}",
        envelope.aggregate_id
    )
}

pub async fn fetch_projection_from_dynamodb(
    ddb: &DynamoDbClient,
    table_name: &str,
    settlement_id: Uuid,
) -> Result<Option<SettlementProjection>> {
    let output = ddb
        .get_item()
        .table_name(table_name)
        .key("PK", AttributeValue::S(projection_pk(settlement_id)))
        .key("SK", AttributeValue::S(projection_state_sk().to_string()))
        .consistent_read(true)
        .send()
        .await
        .context("failed reading projection item from DynamoDB")?;

    let Some(item) = output.item else {
        return Ok(None);
    };

    let get_s = |k: &str| -> Result<String> {
        item.get(k)
            .and_then(|v| v.as_s().ok())
            .cloned()
            .ok_or_else(|| anyhow!("missing string attribute {k}"))
    };
    let get_n = |k: &str| -> Result<i32> {
        item.get(k)
            .and_then(|v| v.as_n().ok())
            .ok_or_else(|| anyhow!("missing number attribute {k}"))?
            .parse::<i32>()
            .with_context(|| format!("invalid integer attribute {k}"))
    };

    let status = SettlementStatus::parse(&get_s("status")?)?;
    let updated_at = DateTime::parse_from_rfc3339(&get_s("updated_at")?)
        .context("invalid updated_at timestamp")?
        .with_timezone(&Utc);
    let last_entry_id = item
        .get("last_entry_id")
        .and_then(|v| v.as_s().ok())
        .and_then(|s| Uuid::parse_str(s).ok());
    let last_memo = item
        .get("last_memo")
        .and_then(|v| v.as_s().ok())
        .cloned();

    Ok(Some(SettlementProjection {
        settlement_id,
        account_id: get_s("account_id")?,
        reference: get_s("reference")?,
        debit_party: get_s("debit_party")?,
        credit_party: get_s("credit_party")?,
        status,
        clearing_stage: get_s("clearing_stage")?,
        last_entry_id,
        last_memo,
        version: get_n("version")?,
        entry_count: get_n("entry_count")?,
        updated_at,
    }))
}

pub async fn fetch_ledger_from_dynamodb(
    ddb: &DynamoDbClient,
    table_name: &str,
    settlement_id: Uuid,
) -> Result<Option<SettlementLedgerResponse>> {
    let output = ddb
        .query()
        .table_name(table_name)
        .consistent_read(true)
        .key_condition_expression("PK = :pk AND begins_with(SK, :prefix)")
        .expression_attribute_values(":pk", AttributeValue::S(projection_pk(settlement_id)))
        .expression_attribute_values(":prefix", AttributeValue::S("EVENT#".to_string()))
        .scan_index_forward(true)
        .send()
        .await
        .context("failed querying settlement ledger from DynamoDB")?;

    let items = output.items.unwrap_or_default();
    if items.is_empty() {
        return Ok(None);
    }

    let mut events = Vec::with_capacity(items.len());
    let mut max_version = 0;

    for item in items {
        let version = item
            .get("version")
            .and_then(|v| v.as_n().ok())
            .and_then(|s| s.parse::<i32>().ok())
            .unwrap_or(1);
        if version > max_version {
            max_version = version;
        }
        let event_id = item
            .get("event_id")
            .and_then(|v| v.as_s().ok())
            .and_then(|s| Uuid::parse_str(s).ok())
            .unwrap_or_else(Uuid::nil);
        let event_type = item
            .get("event_type")
            .and_then(|v| v.as_s().ok())
            .cloned()
            .unwrap_or_else(|| "LedgerEntryRecorded".to_string());
        let entry_id = item
            .get("entry_id")
            .and_then(|v| v.as_s().ok())
            .and_then(|s| Uuid::parse_str(s).ok());
        let status = item
            .get("status")
            .and_then(|v| v.as_s().ok())
            .cloned()
            .unwrap_or_else(|| "INITIATED".to_string());
        let clearing_stage = item
            .get("clearing_stage")
            .and_then(|v| v.as_s().ok())
            .cloned()
            .unwrap_or_default();
        let memo = item.get("memo").and_then(|v| v.as_s().ok()).cloned();
        let occurred_at = item
            .get("occurred_at")
            .and_then(|v| v.as_s().ok())
            .cloned()
            .unwrap_or_default();

        events.push(SettlementLedgerItem {
            event_id,
            version,
            event_type,
            entry_id,
            status,
            clearing_stage,
            memo,
            occurred_at,
        });
    }

    events.sort_by_key(|e| e.version);
    Ok(Some(SettlementLedgerResponse {
        settlement_id,
        version: max_version,
        events,
    }))
}

#[derive(Debug, Clone, Deserialize)]
struct JwksDocument {
    keys: Vec<JwkKey>,
}

#[derive(Debug, Clone, Deserialize)]
struct JwkKey {
    kid: String,
    n: String,
    e: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TokenClaims {
    pub iss: String,
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub aud: Option<serde_json::Value>,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub token_use: Option<String>,
    pub exp: usize,
}

impl TokenClaims {
    pub fn has_scope(&self, required_scope: &str) -> bool {
        self.scope
            .as_deref()
            .map(|s| s.split_whitespace().any(|part| part == required_scope))
            .unwrap_or(false)
    }

    pub fn client_identifier(&self) -> Option<String> {
        if let Some(cid) = &self.client_id {
            return Some(cid.clone());
        }
        match &self.aud {
            Some(serde_json::Value::String(s)) => Some(s.clone()),
            Some(serde_json::Value::Array(arr)) => {
                arr.first().and_then(|v| v.as_str()).map(|s| s.to_string())
            }
            _ => None,
        }
    }
}

#[derive(Clone)]
pub struct JwksValidator {
    accepted_issuers: Vec<String>,
    jwks_url: String,
    allowed_clients: Vec<String>,
    http: HttpClient,
    cache: Arc<RwLock<Option<(Instant, HashMap<String, (String, String)>)>>>,
}

impl JwksValidator {
    pub fn from_env() -> Result<Self> {
        let issuer = env::var("AUTH_ISSUER")
            .or_else(|_| env::var("COGNITO_ISSUER"))
            .context("AUTH_ISSUER is required")?;
        let trimmed_issuer = issuer.trim_end_matches('/').to_string();
        if trimmed_issuer.is_empty() {
            bail!("AUTH_ISSUER must not be empty");
        }
        let pool_id = trimmed_issuer
            .rsplit('/')
            .next()
            .unwrap_or(&trimmed_issuer)
            .to_string();
        let ep = aws_endpoint_url();
        let ep_trimmed = ep.trim_end_matches('/');

        let mut accepted_issuers = vec![trimmed_issuer.clone()];
        for candidate_iss in [
            format!("http://localhost:4566/{pool_id}"),
            format!("http://aws:4566/{pool_id}"),
            format!("{ep_trimmed}/{pool_id}"),
        ] {
            if !accepted_issuers.contains(&candidate_iss) {
                accepted_issuers.push(candidate_iss);
            }
        }

        let raw_jwks_url = env::var("AUTH_JWKS_URL")
            .or_else(|_| env::var("COGNITO_JWKS_URL"))
            .context("AUTH_JWKS_URL is required")?
            .trim()
            .to_string();
        if raw_jwks_url.is_empty() {
            bail!("AUTH_JWKS_URL must not be empty");
        }
        let jwks_url = normalize_http_endpoint_url(&raw_jwks_url);

        let allowed_clients = env::var("AUTH_AUDIENCES")
            .or_else(|_| env::var("COGNITO_AUDIENCES"))
            .context("AUTH_AUDIENCES is required")?
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>();
        if allowed_clients.is_empty() {
            bail!("AUTH_AUDIENCES must specify at least one allowed Cognito client ID");
        }

        Ok(Self {
            accepted_issuers,
            jwks_url,
            allowed_clients,
            http: HttpClient::builder()
                .no_proxy()
                .connect_timeout(Duration::from_secs(2))
                .timeout(Duration::from_secs(5))
                .build()?,
            cache: Arc::new(RwLock::new(None)),
        })
    }

    async fn get_key_components(&self, kid: &str) -> Result<(String, String)> {
        {
            let guard = self.cache.read().await;
            if let Some((fetched_at, keys)) = guard.as_ref() {
                if fetched_at.elapsed() < Duration::from_secs(300) {
                    if let Some(found) = keys.get(kid) {
                        return Ok(found.clone());
                    }
                }
            }
        }

        let resp: JwksDocument = self
            .http
            .get(&self.jwks_url)
            .send()
            .await
            .with_context(|| format!("failed fetching JWKS from {}", self.jwks_url))?
            .error_for_status()
            .context("JWKS endpoint returned error status")?
            .json()
            .await
            .context("invalid JWKS JSON document")?;

        let mut map = HashMap::new();
        for key in resp.keys {
            map.insert(key.kid, (key.n, key.e));
        }

        let found = map
            .get(kid)
            .cloned()
            .ok_or_else(|| anyhow!("kid {kid} not found in JWKS"))?;

        let mut guard = self.cache.write().await;
        *guard = Some((Instant::now(), map));
        Ok(found)
    }

    pub async fn verify(&self, token: &str) -> Result<TokenClaims> {
        let header = decode_header(token).context("invalid JWT header")?;
        let kid = header.kid.ok_or_else(|| anyhow!("JWT header missing kid"))?;
        let (n, e) = self.get_key_components(&kid).await?;
        let decoding_key =
            DecodingKey::from_rsa_components(&n, &e).context("invalid RSA JWK components")?;

        let mut validation = Validation::new(Algorithm::RS256);
        validation.validate_aud = false;
        validation.set_issuer(&self.accepted_issuers);

        let decoded = decode::<TokenClaims>(token, &decoding_key, &validation)
            .context("JWT signature or claims verification failed")?;

        let claims = decoded.claims;
        if let Some(token_use) = &claims.token_use {
            if token_use != "access" {
                bail!("invalid token_use: {token_use}");
            }
        }
        if !self.allowed_clients.is_empty() {
            let Some(cid) = claims.client_identifier() else {
                bail!("token missing client_id/aud claim");
            };
            if !self.allowed_clients.iter().any(|allowed| allowed == &cid) {
                bail!("client_id {cid} is not in allowed audiences");
            }
        }
        Ok(claims)
    }
}

#[derive(Clone)]
pub struct CloudWatchEmit {
    http: HttpClient,
    endpoint: String,
    log_group: Option<String>,
    log_stream: String,
}

impl CloudWatchEmit {
    pub fn new(_sdk_config: &aws_config::SdkConfig, default_stream_prefix: &str) -> Self {
        let log_group = env::var("CLOUDWATCH_LOG_GROUP")
            .ok()
            .filter(|v| !v.trim().is_empty());
        let instance = env::var("SERVICE_INSTANCE_ID")
            .or_else(|_| env::var("HOSTNAME"))
            .unwrap_or_else(|_| default_stream_prefix.to_string());
        let http = HttpClient::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(2))
            .timeout(Duration::from_secs(3))
            .build()
            .unwrap_or_default();
        Self {
            http,
            endpoint: aws_endpoint_url(),
            log_group,
            log_stream: format!("{default_stream_prefix}-{instance}"),
        }
    }

    async fn call_logs(&self, target: &str, body: serde_json::Value) {
        let _ = self
            .http
            .post(&self.endpoint)
            .header("Content-Type", "application/x-amz-json-1.1")
            .header("X-Amz-Target", target)
            .header("X-Amz-Date", "20260101T000000Z")
            .header(
                "Authorization",
                "AWS4-HMAC-SHA256 Credential=test/20260101/us-east-1/logs/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-target, Signature=0000000000000000000000000000000000000000000000000000000000000000",
            )
            .json(&body)
            .send()
            .await;
    }

    pub async fn emit_json(&self, value: serde_json::Value) {
        let message = value.to_string();
        tracing::info!(target: "clearledger_audit", raw_event = %message, "telemetry_event");
        let Some(group) = &self.log_group else {
            return;
        };
        self.call_logs(
            "Logs_20140328.CreateLogStream",
            json!({
                "logGroupName": group,
                "logStreamName": &self.log_stream,
            }),
        )
        .await;
        self.call_logs(
            "Logs_20140328.PutLogEvents",
            json!({
                "logGroupName": group,
                "logStreamName": &self.log_stream,
                "logEvents": [{
                    "timestamp": Utc::now().timestamp_millis(),
                    "message": message,
                }],
            }),
        )
        .await;
    }
}

pub fn parse_ndjson_batch_key(prefix: &str, first_seq: i64, last_seq: i64, body: &[u8]) -> String {
    let clean_prefix = prefix.trim_matches('/');
    let digest = &sha256_hex(body)[..16];
    if clean_prefix.is_empty() {
        format!("batch-{first_seq:08}-{last_seq:08}-{digest}.ndjson")
    } else {
        format!("{clean_prefix}/batch-{first_seq:08}-{last_seq:08}-{digest}.ndjson")
    }
}
