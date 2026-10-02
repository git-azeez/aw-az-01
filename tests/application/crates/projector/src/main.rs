use std::{env, sync::Arc};

use anyhow::{Context, Result};
use aws_sdk_dynamodb::Client as DynamoDbClient;
use chrono::Utc;
use clearledger::{
    apply_event_to_dynamodb, build_aws_config, valkey_settlement_key, CloudWatchEmit,
    DomainEventEnvelope,
};
use lambda_runtime::{run, service_fn, Error as LambdaError, LambdaEvent};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tracing::{error, info};

#[derive(Clone)]
struct ProjectorState {
    ddb: DynamoDbClient,
    redis_client: Option<redis::Client>,
    cw: CloudWatchEmit,
    table_name: String,
}

#[derive(Debug, Deserialize)]
struct SqsBatchRecord {
    #[serde(rename = "messageId")]
    message_id: Option<String>,
    body: Option<String>,
}

#[derive(Debug, Serialize)]
struct BatchFailure {
    #[serde(rename = "itemIdentifier")]
    item_identifier: String,
}

#[tokio::main]
async fn main() -> Result<(), LambdaError> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .json()
        .init();

    let table_name = env::var("PROJECTION_TABLE").context("PROJECTION_TABLE is required")?;
    let valkey_url = env::var("VALKEY_URL").ok().filter(|v| !v.trim().is_empty());

    let sdk_config = build_aws_config().await;
    let ddb = DynamoDbClient::new(&sdk_config);
    let cw = CloudWatchEmit::new(&sdk_config, "projector");
    let redis_client = valkey_url.and_then(|url| redis::Client::open(url).ok());

    let state = Arc::new(ProjectorState {
        ddb,
        redis_client,
        cw,
        table_name,
    });

    run(service_fn(move |event: LambdaEvent<Value>| {
        let state = state.clone();
        async move { handle_event(state, event.payload).await }
    }))
    .await
}

async fn handle_event(state: Arc<ProjectorState>, payload: Value) -> Result<Value, LambdaError> {
    let records_val = payload
        .get("Records")
        .or_else(|| payload.get("records"))
        .cloned()
        .unwrap_or_else(|| Value::Array(vec![]));

    let records: Vec<SqsBatchRecord> = serde_json::from_value(records_val).unwrap_or_default();
    let mut failures = Vec::new();
    let mut applied = 0usize;
    let mut duplicates = 0usize;

    for record in records {
        let msg_id = record
            .message_id
            .clone()
            .unwrap_or_else(|| "unknown".to_string());
        let Some(body) = record.body else {
            failures.push(BatchFailure {
                item_identifier: msg_id,
            });
            continue;
        };

        let parsed: Result<DomainEventEnvelope, _> = serde_json::from_str(&body);
        let envelope = match parsed {
            Ok(env) => env,
            Err(err) => {
                error!(message_id = %msg_id, error = %err, "invalid event envelope in SQS message");
                state
                    .cw
                    .emit_json(json!({
                        "service": "clearledger-projector",
                        "event": "poison_message",
                        "messageId": msg_id,
                        "error": err.to_string(),
                        "timestamp": Utc::now().to_rfc3339(),
                    }))
                    .await;
                failures.push(BatchFailure {
                    item_identifier: msg_id,
                });
                continue;
            }
        };

        match apply_event_to_dynamodb(&state.ddb, &state.table_name, &envelope).await {
            Ok(updated) => {
                if updated {
                    applied += 1;
                } else {
                    duplicates += 1;
                }
                if let Some(client) = &state.redis_client {
                    if let Ok(mut conn) = client.get_multiplexed_async_connection().await {
                        let key = valkey_settlement_key(envelope.aggregate_id);
                        let _: std::result::Result<(), _> = conn.del(key).await;
                    }
                }
                info!(
                    settlement_id = %envelope.aggregate_id,
                    event_id = %envelope.event_id,
                    version = envelope.aggregate_version,
                    correlation_id = %envelope.correlation_id,
                    updated = updated,
                    "projected settlement event"
                );
                state
                    .cw
                    .emit_json(json!({
                        "service": "clearledger-projector",
                        "event": "projected",
                        "settlementId": envelope.aggregate_id,
                        "eventId": envelope.event_id,
                        "version": envelope.aggregate_version,
                        "correlationId": envelope.correlation_id,
                        "updated": updated,
                        "timestamp": Utc::now().to_rfc3339(),
                    }))
                    .await;
            }
            Err(err) => {
                error!(
                    message_id = %msg_id,
                    settlement_id = %envelope.aggregate_id,
                    error = %err,
                    "failed applying event to DynamoDB"
                );
                failures.push(BatchFailure {
                    item_identifier: msg_id,
                });
            }
        }
    }

    if !failures.is_empty() && records_val_len(&payload) == 1 {
        return Err(format!(
            "Failed processing SQS message {}",
            failures[0].item_identifier
        )
        .into());
    }

    Ok(json!({
        "applied": applied,
        "duplicates": duplicates,
        "batchItemFailures": failures,
    }))
}

fn records_val_len(payload: &Value) -> usize {
    payload
        .get("Records")
        .or_else(|| payload.get("records"))
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0)
}
