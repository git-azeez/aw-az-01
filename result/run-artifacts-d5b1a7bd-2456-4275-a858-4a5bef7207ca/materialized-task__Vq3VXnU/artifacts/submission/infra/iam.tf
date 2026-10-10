locals {
  queue_arn = local.queue_arn_det
  dlq_arn   = local.dlq_arn_det
  table_arn = aws_dynamodb_table.projections.arn
  gsi_arn   = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket    = aws_s3_bucket.audit.arn
  kms       = { for k, v in aws_kms_key.this : k => v.arn }

  log_arn = {
    for k, name in local.log_groups :
    k => "arn:aws:logs:${var.region}:${local.account_id}:log-group:${name}"
  }
  log_res = { for k, a in local.log_arn : k => [a, "${a}:*"] }

  log_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  log_deny_actions  = ["logs:CreateLogStream", "logs:PutLogEvents"]

  # ---- reusable explicit Deny guardrails ----
  deny_sqs_all = {
    Sid      = "DenySqsAccess"
    Effect   = "Deny"
    Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
    Resource = [local.queue_arn, local.dlq_arn]
  }
  deny_ddb_all = {
    Sid      = "DenyDynamoDbAccess"
    Effect   = "Deny"
    Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
    Resource = [local.table_arn, local.gsi_arn]
  }
  deny_s3_all = {
    Sid      = "DenyAuditBucketAccess"
    Effect   = "Deny"
    Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    Resource = [local.bucket, "${local.bucket}/*"]
  }

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
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

############################
# Roles
############################

resource "aws_iam_role" "ecs_execution" {
  name                  = "${local.p}-ecs-execution"
  description           = "ClearLedger ECS task execution role (log shipping only)"
  assume_role_policy    = local.ecs_trust
  force_detach_policies = true
  max_session_duration  = 3600
  tags                  = { Name = "${local.p}-ecs-execution" }
}

resource "aws_iam_role" "ecs_task" {
  name                  = "${local.p}-ecs-task"
  description           = "ClearLedger API task role"
  assume_role_policy    = local.ecs_trust
  force_detach_policies = true
  tags                  = { Name = "${local.p}-ecs-task" }
}

resource "aws_iam_role" "projector" {
  name                  = "${local.p}-projector"
  description           = "ClearLedger projector Lambda role"
  assume_role_policy    = local.lambda_trust
  force_detach_policies = true
  tags                  = { Name = "${local.p}-projector" }
}

resource "aws_iam_role" "relay" {
  name                  = "${local.p}-relay"
  description           = "ClearLedger outbox relay Lambda role"
  assume_role_policy    = local.lambda_trust
  force_detach_policies = true
  tags                  = { Name = "${local.p}-relay" }
}

resource "aws_iam_role" "archiver" {
  name                  = "${local.p}-archiver"
  description           = "ClearLedger audit archiver Lambda role"
  assume_role_policy    = local.lambda_trust
  force_detach_policies = true
  tags                  = { Name = "${local.p}-archiver" }
}

resource "aws_iam_role" "scheduler" {
  name                  = "${local.p}-scheduler"
  description           = "ClearLedger EventBridge Scheduler invocation role"
  assume_role_policy    = local.scheduler_trust
  force_detach_policies = true
  tags                  = { Name = "${local.p}-scheduler" }
}

############################
# Policies
############################

resource "aws_iam_role_policy" "ecs_execution" {
  name = "${local.p}-ecs-execution-policy"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ApiLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_res["api"]
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyAllClearLedgerKmsKeys"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = values(local.kms)
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.log_res["projector"], local.log_res["relay"], local.log_res["archiver"])
      },
    ]
  })
}

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
        Resource = [local.queue_arn]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms["messaging"], local.kms["projection"]]
      },
      {
        Sid      = "ApiLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_res["api"]
      },
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      local.deny_s3_all,
      {
        Sid      = "DenyDatabaseAndAuditKeys"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms["database"], local.kms["audit"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.log_res["projector"], local.log_res["relay"], local.log_res["archiver"])
      },
    ]
  })
}

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
        Resource = [local.queue_arn]
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
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms["messaging"], local.kms["projection"]]
      },
      {
        Sid      = "ProjectorLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_res["projector"]
      },
      {
        Sid      = "DenyPublishMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyConsumeDlq"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionDeletes"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      local.deny_s3_all,
      {
        Sid      = "DenyDatabaseAndAuditKeys"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms["database"], local.kms["audit"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.log_res["api"], local.log_res["relay"], local.log_res["archiver"])
      },
    ]
  })
}

resource "aws_iam_role_policy" "relay" {
  name = "${local.p}-relay-policy"
  role = aws_iam_role.relay.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms["messaging"], local.kms["database"]]
      },
      {
        Sid      = "RelayLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_res["relay"]
      },
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyProjectionAndAuditKeys"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms["projection"], local.kms["audit"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.log_res["api"], local.log_res["projector"], local.log_res["archiver"])
      },
    ]
  })
}

resource "aws_iam_role_policy" "archiver" {
  name = "${local.p}-archiver-policy"
  role = aws_iam_role.archiver.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AppendAuditObjects"
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
        Sid      = "UseAuditAndDatabaseKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms["audit"], local.kms["database"]]
      },
      {
        Sid      = "ArchiverLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_res["archiver"]
      },
      {
        Sid      = "DenyAuditDeletes"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = [local.bucket, "${local.bucket}/*"]
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      {
        Sid      = "DenyMessagingAndProjectionKeys"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms["messaging"], local.kms["projection"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.log_res["api"], local.log_res["projector"], local.log_res["relay"])
      },
    ]
  })
}

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
      local.deny_sqs_all,
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyAllClearLedgerKmsKeys"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = values(local.kms)
      },
      {
        Sid      = "DenyAllClearLedgerLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = flatten(values(local.log_res))
      },
    ]
  })
}
