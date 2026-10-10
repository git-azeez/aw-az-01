# ---------------------------------------------------------------------------
# Lambda container workers
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  package_type  = "Image"
  image_uri     = var.projector_image
  role          = aws_iam_role.projector.arn
  timeout       = 30
  memory_size   = 256

  environment {
    variables = merge(local.aws_runtime_env, {
      PROJECTION_TABLE     = aws_dynamodb_table.projections.name
      VALKEY_URL           = local.valkey_url
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["projector"].name
  }

  tags = {
    Name = "${local.prefix}-projector"
  }

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  package_type  = "Image"
  image_uri     = var.relay_image
  role          = aws_iam_role.relay.arn
  timeout       = 60
  memory_size   = 256

  environment {
    variables = merge(local.aws_runtime_env, {
      DATABASE_URL         = local.database_url
      SQS_QUEUE_URL        = aws_sqs_queue.main.url
      OUTBOX_BATCH_SIZE    = "50"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["relay"].name
  }

  tags = {
    Name = "${local.prefix}-outbox-relay"
  }

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  package_type  = "Image"
  image_uri     = var.archiver_image
  role          = aws_iam_role.archiver.arn
  timeout       = 120
  memory_size   = 256

  environment {
    variables = merge(local.aws_runtime_env, {
      DATABASE_URL         = local.database_url
      AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX         = "ledger-audit/"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["archiver"].name
  }

  tags = {
    Name = "${local.prefix}-audit-archiver"
  }

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  tags = {
    Name = "${local.prefix}-projector-esm"
  }

  lifecycle {
    # Event source mappings have no ARN in the emulator, so tags cannot be read back.
    ignore_changes = [tags, tags_all]
  }
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler
# ---------------------------------------------------------------------------
resource "aws_scheduler_schedule" "outbox" {
  name                         = "${local.prefix}-outbox-relay"
  group_name                   = "default"
  state                        = "ENABLED"
  schedule_expression          = "rate(1 minute)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "clearledger.scheduler", job = "outbox-relay" })

    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 2
    }
  }
}

resource "aws_scheduler_schedule" "archive" {
  name                         = "${local.prefix}-audit-archiver"
  group_name                   = "default"
  state                        = "ENABLED"
  schedule_expression          = "rate(5 minutes)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "clearledger.scheduler", job = "audit-archiver" })

    retry_policy {
      maximum_event_age_in_seconds = 600
      maximum_retry_attempts       = 2
    }
  }
}
