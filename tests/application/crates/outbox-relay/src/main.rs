use std::{env, sync::Arc};

use anyhow::{Context, Result};
use aws_sdk_sqs::Client as SqsClient;
use chrono::Utc;
use clearledger::{build_aws_config, connect_postgres, CloudWatchEmit};
use lambda_runtime::{run, service_fn, Error as LambdaError, LambdaEvent};
use serde_json::{json, Value};
use sqlx::{PgPool, Row};
use tracing::{error, info};
use uuid::Uuid;

#[derive(Clone)]
struct RelayState {
    pool: PgPool,
    sqs: SqsClient,
    cw: CloudWatchEmit,
    queue_url: String,
    batch_size: i64,
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

    let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let queue_url = env::var("SQS_QUEUE_URL")
        .or_else(|_| env::var("QUEUE_URL"))
        .context("SQS_QUEUE_URL is required")?;
    let batch_size_raw = env::var("OUTBOX_BATCH_SIZE").unwrap_or_else(|_| "50".to_string());
    let batch_size: i64 = batch_size_raw
        .trim()
        .parse()
        .context("OUTBOX_BATCH_SIZE must be an integer")?;
    if batch_size <= 0 {
        return Err("OUTBOX_BATCH_SIZE must be > 0".into());
    }

    let sdk_config = build_aws_config().await;
    let sqs = SqsClient::new(&sdk_config);
    let cw = CloudWatchEmit::new(&sdk_config, "outbox-relay");
    let pool = connect_postgres(&database_url).await?;

    let state = Arc::new(RelayState {
        pool,
        sqs,
        cw,
        queue_url,
        batch_size,
    });

    run(service_fn(move |event: LambdaEvent<Value>| {
        let state = state.clone();
        async move { handle_relay(state, event.payload).await }
    }))
    .await
}

async fn handle_relay(state: Arc<RelayState>, _payload: Value) -> Result<Value, LambdaError> {
    let rows = sqlx::query(
        r#"
        SELECT seq, event_id, settlement_id, aggregate_version, correlation_id, payload
        FROM clearledger.outbox
        WHERE published_at IS NULL
        ORDER BY seq ASC
        LIMIT $1
        "#,
    )
    .bind(state.batch_size)
    .fetch_all(&state.pool)
    .await?;

    let mut published = 0usize;
    let mut failed = 0usize;

    for row in rows {
        let seq: i64 = row.get("seq");
        let event_id: Uuid = row.get("event_id");
        let settlement_id: Uuid = row.get("settlement_id");
        let correlation_id: String = row.get("correlation_id");
        let payload: Value = row.get("payload");

        match state
            .sqs
            .send_message()
            .queue_url(&state.queue_url)
            .message_body(payload.to_string())
            .send()
            .await
        {
            Ok(_) => {
                sqlx::query(
                    "UPDATE clearledger.outbox SET published_at = NOW(), attempts = attempts + 1, last_error = NULL WHERE seq = $1",
                )
                .bind(seq)
                .execute(&state.pool)
                .await?;
                published += 1;
                info!(
                    seq = seq,
                    event_id = %event_id,
                    settlement_id = %settlement_id,
                    correlation_id = %correlation_id,
                    "relayed outbox event to SQS"
                );
            }
            Err(err) => {
                failed += 1;
                error!(
                    seq = seq,
                    event_id = %event_id,
                    settlement_id = %settlement_id,
                    error = %err,
                    "failed relaying outbox event to SQS"
                );
                sqlx::query(
                    "UPDATE clearledger.outbox SET attempts = attempts + 1, last_error = $2 WHERE seq = $1",
                )
                .bind(seq)
                .bind(err.to_string())
                .execute(&state.pool)
                .await?;
            }
        }
    }

    state
        .cw
        .emit_json(json!({
            "service": "clearledger-outbox-relay",
            "event": "relay_tick",
            "published": published,
            "failed": failed,
            "timestamp": Utc::now().to_rfc3339(),
        }))
        .await;

    Ok(json!({
        "published": published,
        "failed": failed,
    }))
}
