locals {
  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }

  lg_arn = { for k, v in aws_cloudwatch_log_group.this : k => "arn:aws:logs:${var.region}:${local.account}:log-group:${v.name}" }
  # Own-log-group resources (group ARN and its streams).
  lg_res = { for k, v in local.lg_arn : k => [v, "${v}:*", "${v}:log-stream:*"] }

  table_arn = aws_dynamodb_table.projection.arn
  gsi_arn   = "${aws_dynamodb_table.projection.arn}/index/AccountIndex"
  bucket    = aws_s3_bucket.audit.arn

  sqs_all_actions  = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_all_actions  = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_all_actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  kms_use_actions  = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny_actions = ["kms:Decrypt", "kms:GenerateDataKey"]
  logs_write       = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  logs_deny        = ["logs:CreateLogStream", "logs:PutLogEvents"]

  other_logs = {
    for k in keys(local.log_groups) : k => flatten([for o, r in local.lg_res : r if o != k])
  }
  all_logs = flatten(values(local.lg_res))

  lambda_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  ecs_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  scheduler_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ecs_execution" {
  name               = "${local.p}-ecs-execution"
  assume_role_policy = local.ecs_trust
  tags               = merge(local.tags, { Name = "${local.p}-ecs-execution" })
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.p}-ecs-task"
  assume_role_policy = local.ecs_trust
  tags               = merge(local.tags, { Name = "${local.p}-ecs-task" })
}

resource "aws_iam_role" "projector" {
  name               = "${local.p}-projector"
  assume_role_policy = local.lambda_trust
  tags               = merge(local.tags, { Name = "${local.p}-projector" })
}

resource "aws_iam_role" "relay" {
  name               = "${local.p}-outbox-relay"
  assume_role_policy = local.lambda_trust
  tags               = merge(local.tags, { Name = "${local.p}-outbox-relay" })
}

resource "aws_iam_role" "archiver" {
  name               = "${local.p}-audit-archiver"
  assume_role_policy = local.lambda_trust
  tags               = merge(local.tags, { Name = "${local.p}-audit-archiver" })
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.p}-scheduler"
  assume_role_policy = local.scheduler_trust
  tags               = merge(local.tags, { Name = "${local.p}-scheduler" })
}

# ---------------------------------------------------------------------------
# ecs_execution: write API logs only.
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "ecs_execution" {
  name = "${local.p}-ecs-execution-policy"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ApiLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg_res["api"]
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_actions
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_actions
        Resource = [local.bucket, "${local.bucket}/*"]
      },
      {
        Sid      = "DenyKms"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = values(local.kms_arn)
      },
      {
        Sid      = "DenyOtherLogs"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = local.other_logs["api"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# ecs_task: API runtime permissions.
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.p}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "KmsMessagingProjection"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "ApiLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg_res["api"]
      },
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "DenyDlq"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "DenyDynamoDbMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_actions
        Resource = [local.bucket, "${local.bucket}/*"]
      },
      {
        Sid      = "DenyKmsDatabaseAudit"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn["database"], local.kms_arn["audit"]]
      },
      {
        Sid      = "DenyOtherLogs"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = local.other_logs["api"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# projector
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "projector" {
  name = "${local.p}-projector-policy"
  role = aws_iam_role.projector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "ForwardToDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "UpsertProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "KmsMessagingProjection"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "ProjectorLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg_res["projector"]
      },
      {
        Sid      = "DenyPublishMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "DenyConsumeDlq"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "DenyDynamoDbDelete"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_actions
        Resource = [local.bucket, "${local.bucket}/*"]
      },
      {
        Sid      = "DenyKmsDatabaseAudit"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn["database"], local.kms_arn["audit"]]
      },
      {
        Sid      = "DenyOtherLogs"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = local.other_logs["projector"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# outbox relay
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "relay" {
  name = "${local.p}-outbox-relay-policy"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "KmsMessagingDatabase"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["messaging"], local.kms_arn["database"]]
      },
      {
        Sid      = "RelayLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg_res["relay"]
      },
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "DenyDlq"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_actions
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_actions
        Resource = [local.bucket, "${local.bucket}/*"]
      },
      {
        Sid      = "DenyKmsProjectionAudit"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn["projection"], local.kms_arn["audit"]]
      },
      {
        Sid      = "DenyOtherLogs"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = local.other_logs["relay"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# audit archiver
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "archiver" {
  name = "${local.p}-audit-archiver-policy"
  role = aws_iam_role.archiver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuditObjectsAppend"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.bucket}/ledger-audit/*"]
      },
      {
        Sid      = "AuditBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [local.bucket]
      },
      {
        Sid      = "KmsAuditDatabase"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["audit"], local.kms_arn["database"]]
      },
      {
        Sid      = "ArchiverLogsWrite"
        Effect   = "Allow"
        Action   = local.logs_write
        Resource = local.lg_res["archiver"]
      },
      {
        Sid      = "DenyAuditDeletion"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = [local.bucket, "${local.bucket}/*"]
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_actions
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "DenyKmsMessagingProjection"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "DenyOtherLogs"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = local.other_logs["archiver"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# scheduler
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "scheduler" {
  name = "${local.p}-scheduler-policy"
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
        Sid      = "DenyInvokeProjector"
        Effect   = "Deny"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.projector.arn]
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_actions
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = local.s3_all_actions
        Resource = [local.bucket, "${local.bucket}/*"]
      },
      {
        Sid      = "DenyKms"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = values(local.kms_arn)
      },
      {
        Sid      = "DenyLogs"
        Effect   = "Deny"
        Action   = local.logs_deny
        Resource = local.all_logs
      }
    ]
  })
}
