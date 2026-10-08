use std::{env, sync::Arc};

use anyhow::{Context, Result};
use aws_sdk_s3::{primitives::ByteStream, Client as S3Client};
use chrono::Utc;
use clearledger::{
    build_aws_config, connect_postgres, init_runtime_env, parse_ndjson_batch_key,
    validate_envelope, CloudWatchEmit, DomainEventEnvelope,
};
use lambda_runtime::{run, service_fn, Error as LambdaError, LambdaEvent};
use serde_json::{json, Value};
use sqlx::{PgPool, Row};
use tracing::info;

#[derive(Clone)]
struct ArchiverState {
    pool: PgPool,
    s3: S3Client,
    cw: CloudWatchEmit,
    bucket: String,
    prefix: String,
    batch_size: i64,
}

#[tokio::main]
async fn main() -> Result<(), LambdaError> {
    init_runtime_env();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .json()
        .init();

    let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let bucket = env::var("AUDIT_BUCKET").context("AUDIT_BUCKET is required")?;
    let prefix = env::var("AUDIT_PREFIX").context("AUDIT_PREFIX is required")?;
    if prefix.trim().is_empty() {
        return Err("AUDIT_PREFIX must not be empty".into());
    }
    let batch_size: i64 = env::var("AUDIT_BATCH_SIZE")
        .unwrap_or_else(|_| "100".to_string())
        .parse()
        .unwrap_or(100);

    let sdk_config = build_aws_config().await;
    let s3_config = aws_sdk_s3::config::Builder::from(&sdk_config)
        .force_path_style(true)
        .build();
    let s3 = S3Client::from_conf(s3_config);
    let cw = CloudWatchEmit::new(&sdk_config, "audit-archiver");
    let pool = connect_postgres(&database_url).await?;

    let state = Arc::new(ArchiverState {
        pool,
        s3,
        cw,
        bucket,
        prefix,
        batch_size,
    });

    run(service_fn(move |event: LambdaEvent<Value>| {
        let state = state.clone();
        async move { handle_archive(state, event.payload).await }
    }))
    .await
}

async fn handle_archive(state: Arc<ArchiverState>, _payload: Value) -> Result<Value, LambdaError> {
    let rows = sqlx::query(
        r#"
        SELECT seq, payload
        FROM clearledger.outbox
        WHERE published_at IS NOT NULL AND archived_at IS NULL
        ORDER BY seq ASC
        LIMIT $1
        "#,
    )
    .bind(state.batch_size)
    .fetch_all(&state.pool)
    .await?;

    if rows.is_empty() {
        return Ok(json!({
            "archived": 0,
            "key": Value::Null,
        }));
    }

    let mut seqs = Vec::with_capacity(rows.len());
    let mut lines = Vec::with_capacity(rows.len());

    for row in rows {
        let seq: i64 = row.get("seq");
        let payload: Value = row.get("payload");
        let envelope: DomainEventEnvelope = serde_json::from_value(payload)?;
        validate_envelope(&envelope)?;
        lines.push(serde_json::to_string(&envelope)?);
        seqs.push(seq);
    }

    let first_seq = *seqs.first().unwrap();
    let last_seq = *seqs.last().unwrap();
    let ndjson = format!("{}\n", lines.join("\n"));
    let body_bytes = ndjson.into_bytes();
    let key = parse_ndjson_batch_key(&state.prefix, first_seq, last_seq, &body_bytes);

    state
        .s3
        .put_object()
        .bucket(&state.bucket)
        .key(&key)
        .content_type("application/x-ndjson")
        .body(ByteStream::from(body_bytes))
        .send()
        .await?;

    sqlx::query("UPDATE clearledger.outbox SET archived_at = NOW() WHERE seq = ANY($1)")
        .bind(&seqs)
        .execute(&state.pool)
        .await?;

    info!(
        archived = seqs.len(),
        bucket = %state.bucket,
        key = %key,
        "archived published outbox events to S3"
    );
    state
        .cw
        .emit_json(json!({
            "service": "clearledger-audit-archiver",
            "event": "archive_batch",
            "archived": seqs.len(),
            "bucket": state.bucket,
            "key": key,
            "timestamp": Utc::now().to_rfc3339(),
        }))
        .await;

    Ok(json!({
        "archived": seqs.len(),
        "bucket": state.bucket,
        "key": key,
    }))
}
