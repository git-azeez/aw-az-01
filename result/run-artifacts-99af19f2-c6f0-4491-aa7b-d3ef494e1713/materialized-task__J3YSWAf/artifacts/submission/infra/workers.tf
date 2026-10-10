resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  package_type  = "Image"
  image_uri     = local.config.projector_image
  role          = aws_iam_role.projector.arn
  timeout       = 30
  memory_size   = 512

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = {
      AWS_REGION            = local.region
      AWS_DEFAULT_REGION    = local.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.endpoint
      PROJECTION_TABLE      = aws_dynamodb_table.projections.name
      VALKEY_URL            = local.valkey_url
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.projector.name
    }
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.projector]
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  package_type  = "Image"
  image_uri     = local.config.relay_image
  role          = aws_iam_role.relay.arn
  timeout       = 55
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = {
      AWS_REGION            = local.region
      AWS_DEFAULT_REGION    = local.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.endpoint
      DATABASE_URL          = local.database_url
      SQS_QUEUE_URL         = aws_sqs_queue.events.url
      OUTBOX_BATCH_SIZE     = local.outbox_batch_size
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.relay.name
    }
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.relay]
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  package_type  = "Image"
  image_uri     = local.config.archiver_image
  role          = aws_iam_role.archiver.arn
  timeout       = 120
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = {
      AWS_REGION            = local.region
      AWS_DEFAULT_REGION    = local.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.endpoint
      DATABASE_URL          = local.database_url
      AUDIT_BUCKET          = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX          = local.audit_prefix
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.archiver.name
    }
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.archiver]
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.projector, aws_sqs_queue_policy.events]
}

resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.prefix}-outbox-relay"
  state               = "ENABLED"
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = "{}"
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

resource "aws_scheduler_schedule" "archive" {
  name                = "${local.prefix}-audit-archiver"
  state               = "ENABLED"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = "{}"
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
