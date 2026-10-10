# ---------------------------------------------------------------------------
# IAM: six dedicated roles, each with least-privilege Allow statements and
# explicit Deny guardrails. No wildcard actions or wildcard resources in Allow.
# ---------------------------------------------------------------------------
locals {
  q_arn      = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  table_arn  = aws_dynamodb_table.projections.arn
  index_arn  = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn
  bucket_all = "${aws_s3_bucket.audit.arn}/*"
  bucket_ao  = "${aws_s3_bucket.audit.arn}/ledger-audit/*"

  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }

  # Each log group is addressed by its own ARN plus its log-stream ARNs.
  lg = {
    api       = [aws_cloudwatch_log_group.api.arn, "${aws_cloudwatch_log_group.api.arn}:*"]
    projector = [aws_cloudwatch_log_group.projector.arn, "${aws_cloudwatch_log_group.projector.arn}:*"]
    relay     = [aws_cloudwatch_log_group.relay.arn, "${aws_cloudwatch_log_group.relay.arn}:*"]
    archiver  = [aws_cloudwatch_log_group.archiver.arn, "${aws_cloudwatch_log_group.archiver.arn}:*"]
  }

  logs_write      = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  logs_deny       = ["logs:CreateLogStream", "logs:PutLogEvents"]
  kms_use         = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny        = ["kms:Decrypt", "kms:GenerateDataKey"]
  ddb_all_deny    = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_all_deny     = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  sqs_all_deny    = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_resources   = [local.table_arn, local.index_arn]
  bucket_all_arns = [local.bucket_arn, local.bucket_all]
}

data "aws_iam_policy_document" "trust_ecs" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "trust_lambda" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "trust_scheduler" {
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
  name               = "${local.prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.trust_ecs.json
  tags               = local.tags
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.trust_ecs.json
  tags               = local.tags
}

resource "aws_iam_role" "projector" {
  name               = "${local.prefix}-projector"
  assume_role_policy = data.aws_iam_policy_document.trust_lambda.json
  tags               = local.tags
}

resource "aws_iam_role" "relay" {
  name               = "${local.prefix}-relay"
  assume_role_policy = data.aws_iam_policy_document.trust_lambda.json
  tags               = local.tags
}

resource "aws_iam_role" "archiver" {
  name               = "${local.prefix}-archiver"
  assume_role_policy = data.aws_iam_policy_document.trust_lambda.json
  tags               = local.tags
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.trust_scheduler.json
  tags               = local.tags
}

# 1. ECS execution role: only writes to the API log group.
resource "aws_iam_role_policy" "ecs_execution" {
  name = "${local.prefix}-ecs-execution"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ApiLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg.api
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = local.sqs_all_deny
        Resource = [local.q_arn, local.dlq_arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_deny
        Resource = local.ddb_resources
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_deny
        Resource = local.bucket_all_arns
      },
      {
        Sid      = "DenyKms"
        Effect   = "Deny"
        Action   = local.kms_deny
        Resource = [for k in ["database", "messaging", "projection", "audit"] : local.kms_arn[k]]
      },
      {
        Sid      = "DenyOtherLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = concat(local.lg.projector, local.lg.relay, local.lg.archiver)
      },
    ]
  })
}

# 2. ECS task role (API): publish to SQS, read projections, own log group.
resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.prefix}-ecs-task"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = local.ddb_resources
      },
      {
        Sid      = "UseKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "ApiLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg.api
      },
      {
        Sid      = "DenySqsConsume"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = local.sqs_all_deny
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyDynamoDbMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn]
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_deny
        Resource = local.bucket_all_arns
      },
      {
        Sid      = "DenyForeignKms"
        Effect   = "Deny"
        Action   = local.kms_deny
        Resource = [local.kms_arn["database"], local.kms_arn["audit"]]
      },
      {
        Sid      = "DenyOtherLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = concat(local.lg.projector, local.lg.relay, local.lg.archiver)
      },
    ]
  })
}

# 3. Projector Lambda role.
resource "aws_iam_role_policy" "projector" {
  name = "${local.prefix}-projector"
  role = aws_iam_role.projector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "ForwardToDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "UpsertProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = local.ddb_resources
      },
      {
        Sid      = "UseKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "ProjectorLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg.projector
      },
      {
        Sid      = "DenyMainQueuePublish"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDlqConsume"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyDynamoDbDelete"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn]
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_deny
        Resource = local.bucket_all_arns
      },
      {
        Sid      = "DenyForeignKms"
        Effect   = "Deny"
        Action   = local.kms_deny
        Resource = [local.kms_arn["database"], local.kms_arn["audit"]]
      },
      {
        Sid      = "DenyOtherLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = concat(local.lg.api, local.lg.relay, local.lg.archiver)
      },
    ]
  })
}

# 4. Outbox relay Lambda role.
resource "aws_iam_role_policy" "relay" {
  name = "${local.prefix}-relay"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "UseKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn["messaging"], local.kms_arn["database"]]
      },
      {
        Sid      = "RelayLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg.relay
      },
      {
        Sid      = "DenyMainQueueConsume"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = local.sqs_all_deny
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_deny
        Resource = local.ddb_resources
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_deny
        Resource = local.bucket_all_arns
      },
      {
        Sid      = "DenyForeignKms"
        Effect   = "Deny"
        Action   = local.kms_deny
        Resource = [local.kms_arn["projection"], local.kms_arn["audit"]]
      },
      {
        Sid      = "DenyOtherLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = concat(local.lg.api, local.lg.projector, local.lg.archiver)
      },
    ]
  })
}

# 5. Audit archiver Lambda role.
resource "aws_iam_role_policy" "archiver" {
  name = "${local.prefix}-archiver"
  role = aws_iam_role.archiver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuditObjectAccess"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = [local.bucket_ao]
      },
      {
        Sid      = "AuditBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [local.bucket_arn]
      },
      {
        Sid      = "UseKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn["audit"], local.kms_arn["database"]]
      },
      {
        Sid      = "ArchiverLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg.archiver
      },
      {
        Sid      = "DenyAuditDeletes"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = local.bucket_all_arns
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = local.sqs_all_deny
        Resource = [local.q_arn, local.dlq_arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_deny
        Resource = local.ddb_resources
      },
      {
        Sid      = "DenyForeignKms"
        Effect   = "Deny"
        Action   = local.kms_deny
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "DenyOtherLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = concat(local.lg.api, local.lg.projector, local.lg.relay)
      },
    ]
  })
}

# 6. Scheduler role: invoke relay and archiver only.
resource "aws_iam_role_policy" "scheduler" {
  name = "${local.prefix}-scheduler"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeScheduledWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.relay.arn, aws_lambda_function.archiver.arn]
      },
      {
        Sid      = "DenyProjectorInvoke"
        Effect   = "Deny"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.projector.arn]
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = local.sqs_all_deny
        Resource = [local.q_arn, local.dlq_arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_deny
        Resource = local.ddb_resources
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_deny
        Resource = local.bucket_all_arns
      },
      {
        Sid      = "DenyKms"
        Effect   = "Deny"
        Action   = local.kms_deny
        Resource = [for k in ["database", "messaging", "projection", "audit"] : local.kms_arn[k]]
      },
      {
        Sid      = "DenyLogs"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = concat(local.lg.api, local.lg.projector, local.lg.relay, local.lg.archiver)
      },
    ]
  })
}
