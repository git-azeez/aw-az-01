resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-events-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.messaging.arn

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-events-dlq"
  })
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.prefix}-events"
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  kms_master_key_id          = aws_kms_key.messaging.arn
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 4
  })

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-events"
  })
}

resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  role          = aws_iam_role.projector.arn
  package_type  = "Image"
  image_uri     = var.projector_image
  timeout       = 15
  memory_size   = 256

  environment {
    variables = {
      AWS_REGION            = var.region
      AWS_DEFAULT_REGION    = var.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = var.aws_endpoint_url
      PROJECTION_TABLE      = aws_dynamodb_table.projections.name
      VALKEY_URL            = local.valkey_url
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.projector.name
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-projector"
  })

  depends_on = [aws_iam_role_policy.projector]
}

resource "aws_lambda_event_source_mapping" "projector_sqs" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.projector.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  enabled                            = true
  function_response_types            = ["ReportBatchItemFailures"]
}

resource "aws_lambda_function" "outbox_relay" {
  function_name = "${local.prefix}-outbox-relay"
  role          = aws_iam_role.relay.arn
  package_type  = "Image"
  image_uri     = var.relay_image
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      AWS_REGION            = var.region
      AWS_DEFAULT_REGION    = var.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = var.aws_endpoint_url
      DATABASE_URL          = local.database_url
      SQS_QUEUE_URL         = aws_sqs_queue.events.url
      OUTBOX_BATCH_SIZE     = "50"
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.relay.name
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-outbox-relay"
  })

  depends_on = [aws_iam_role_policy.relay]
}

resource "aws_lambda_function" "audit_archiver" {
  function_name = "${local.prefix}-audit-archiver"
  role          = aws_iam_role.archiver.arn
  package_type  = "Image"
  image_uri     = var.archiver_image
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      AWS_REGION            = var.region
      AWS_DEFAULT_REGION    = var.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = var.aws_endpoint_url
      DATABASE_URL          = local.database_url
      AUDIT_BUCKET          = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX          = "ledger-audit/"
      AUDIT_BATCH_SIZE      = "100"
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.archiver.name
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-audit-archiver"
  })

  depends_on = [aws_iam_role_policy.archiver]
}

resource "aws_scheduler_schedule" "outbox_relay" {
  name                = "${local.prefix}-outbox-relay-schedule"
  group_name          = "default"
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.outbox_relay.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "clearledger.scheduler", job = "outbox-relay" })
  }
}

resource "aws_scheduler_schedule" "audit_archiver" {
  name                = "${local.prefix}-audit-archiver-schedule"
  group_name          = "default"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.audit_archiver.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "clearledger.scheduler", job = "audit-archiver" })
  }
}
