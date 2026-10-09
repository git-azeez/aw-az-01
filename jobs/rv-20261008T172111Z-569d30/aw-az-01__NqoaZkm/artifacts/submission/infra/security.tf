resource "aws_kms_key" "database" {
  description             = "${local.prefix} RDS encryption key"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags = merge(local.common_tags, {
    Name = "${local.prefix}-database-kms"
  })
}

resource "aws_kms_alias" "database" {
  name          = "alias/${local.prefix}-database"
  target_key_id = aws_kms_key.database.key_id
}

resource "aws_kms_key" "messaging" {
  description             = "${local.prefix} SQS encryption key"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags = merge(local.common_tags, {
    Name = "${local.prefix}-messaging-kms"
  })
}

resource "aws_kms_alias" "messaging" {
  name          = "alias/${local.prefix}-messaging"
  target_key_id = aws_kms_key.messaging.key_id
}

resource "aws_kms_key" "projection" {
  description             = "${local.prefix} DynamoDB projection encryption key"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags = merge(local.common_tags, {
    Name = "${local.prefix}-projection-kms"
  })
}

resource "aws_kms_alias" "projection" {
  name          = "alias/${local.prefix}-projection"
  target_key_id = aws_kms_key.projection.key_id
}

resource "aws_kms_key" "audit" {
  description             = "${local.prefix} S3 audit encryption key"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags = merge(local.common_tags, {
    Name = "${local.prefix}-audit-kms"
  })
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${local.prefix}-audit"
  target_key_id = aws_kms_key.audit.key_id
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/clearledger/${local.prefix}/api"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "projector" {
  name              = "/clearledger/${local.prefix}/projector"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "relay" {
  name              = "/clearledger/${local.prefix}/outbox-relay"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "archiver" {
  name              = "/clearledger/${local.prefix}/audit-archiver"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-pool"
  tags = local.common_tags
}

resource "aws_cognito_resource_server" "clearledger" {
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger"
  user_pool_id = aws_cognito_user_pool.main.id

  scope {
    scope_name        = "read"
    scope_description = "Read settlement projections and ledger history"
  }

  scope {
    scope_name        = "write"
    scope_description = "Initiate settlements and record ledger entries"
  }

  scope {
    scope_name        = "admin"
    scope_description = "Rebuild settlement projections"
  }
}

resource "aws_cognito_user_pool_client" "read" {
  name                                 = "${local.prefix}-read-client"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/read"]
  supported_identity_providers         = ["COGNITO"]

  depends_on = [aws_cognito_resource_server.clearledger]
}

resource "aws_cognito_user_pool_client" "write" {
  name                                 = "${local.prefix}-write-client"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/write"]
  supported_identity_providers         = ["COGNITO"]

  depends_on = [aws_cognito_resource_server.clearledger]
}

resource "aws_cognito_user_pool_client" "admin" {
  name                                 = "${local.prefix}-admin-client"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/admin"]
  supported_identity_providers         = ["COGNITO"]

  depends_on = [aws_cognito_resource_server.clearledger]
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "ecs_execution" {
  name = "${local.prefix}-ecs-execution-policy"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowApiLogDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.api.arn,
          "${aws_cloudwatch_log_group.api.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventPublish"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.events.arn
      },
      {
        Sid    = "AllowProjectionReads"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:DescribeTable"
        ]
        Resource = [
          aws_dynamodb_table.projections.arn,
          "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
        ]
      },
      {
        Sid    = "AllowKmsForQueueAndProjections"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.messaging.arn,
          aws_kms_key.projection.arn
        ]
      },
      {
        Sid    = "AllowStructuredLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.api.arn,
          "${aws_cloudwatch_log_group.api.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "projector" {
  name               = "${local.prefix}-projector-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "projector" {
  name = "${local.prefix}-projector-policy"
  role = aws_iam_role.projector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowConsumeMainQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.events.arn
      },
      {
        Sid      = "AllowDlqRedrive"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
      {
        Sid    = "AllowProjectionWrites"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.projections.arn,
          "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
        ]
      },
      {
        Sid    = "AllowProjectorKms"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.messaging.arn,
          aws_kms_key.projection.arn
        ]
      },
      {
        Sid    = "AllowProjectorLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.projector.arn,
          "${aws_cloudwatch_log_group.projector.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "relay" {
  name               = "${local.prefix}-relay-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "relay" {
  name = "${local.prefix}-relay-policy"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowOutboxPublishToQueue"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.events.arn
      },
      {
        Sid    = "AllowRelayKms"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.messaging.arn,
          aws_kms_key.database.arn
        ]
      },
      {
        Sid    = "AllowRelayLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.relay.arn,
          "${aws_cloudwatch_log_group.relay.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "archiver" {
  name               = "${local.prefix}-archiver-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "archiver" {
  name = "${local.prefix}-archiver-policy"
  role = aws_iam_role.archiver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAuditArchiveObjectWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${aws_s3_bucket.audit.arn}/ledger-audit/*"
      },
      {
        Sid    = "AllowAuditBucketList"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.audit.arn
      },
      {
        Sid    = "AllowArchiverKms"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.audit.arn,
          aws_kms_key.database.arn
        ]
      },
      {
        Sid    = "AllowArchiverLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.archiver.arn,
          "${aws_cloudwatch_log_group.archiver.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.prefix}-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.prefix}-scheduler-policy"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowScheduledLambdaInvocation"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.outbox_relay.arn,
          aws_lambda_function.audit_archiver.arn
        ]
      }
    ]
  })
}
