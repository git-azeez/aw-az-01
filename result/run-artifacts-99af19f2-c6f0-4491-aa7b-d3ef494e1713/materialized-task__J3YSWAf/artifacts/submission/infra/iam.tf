locals {
  iam_roles = ["ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler"]

  trust_services = {
    ecs_execution = "ecs-tasks.amazonaws.com"
    ecs_task      = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com"
    relay         = "lambda.amazonaws.com"
    archiver      = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }

  # Resource ARNs referenced by the policy documents
  q_arn      = aws_sqs_queue.events.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  tbl_arn    = aws_dynamodb_table.projections.arn
  gsi_arn    = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn
  bucket_all = ["${aws_s3_bucket.audit.arn}", "${aws_s3_bucket.audit.arn}/*"]

  key_arns = {
    database   = aws_kms_key.database.arn
    messaging  = aws_kms_key.messaging.arn
    projection = aws_kms_key.projection.arn
    audit      = aws_kms_key.audit.arn
  }
  all_key_arns = [local.key_arns.database, local.key_arns.messaging, local.key_arns.projection, local.key_arns.audit]

  # CloudWatch log group ARNs (group and its streams)
  log_groups = {
    api       = aws_cloudwatch_log_group.api.arn
    projector = aws_cloudwatch_log_group.projector.arn
    relay     = aws_cloudwatch_log_group.relay.arn
    archiver  = aws_cloudwatch_log_group.archiver.arn
  }
  log_resources = { for k, arn in local.log_groups : k => [arn, "${arn}:*"] }

  log_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  log_deny_actions  = ["logs:CreateLogStream", "logs:PutLogEvents"]

  ddb_all_actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_deny_actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  sqs_all_actions = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  kms_deny_use    = ["kms:Decrypt", "kms:GenerateDataKey"]

  other_logs = {
    ecs_execution = flatten([local.log_resources.projector, local.log_resources.relay, local.log_resources.archiver])
    ecs_task      = flatten([local.log_resources.projector, local.log_resources.relay, local.log_resources.archiver])
    projector     = flatten([local.log_resources.api, local.log_resources.relay, local.log_resources.archiver])
    relay         = flatten([local.log_resources.api, local.log_resources.projector, local.log_resources.archiver])
    archiver      = flatten([local.log_resources.api, local.log_resources.projector, local.log_resources.relay])
  }

  # Guardrail present in every role policy
  deny_key_lifecycle = {
    Sid      = "DenyKeyLifecycle"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_key_arns
  }

  iam_policies = {
    ecs_execution = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "WriteOwnApiLogs"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources.api
        },
        local.deny_key_lifecycle,
        {
          Sid      = "DenySqs"
          Effect   = "Deny"
          Action   = local.sqs_all_actions
          Resource = [local.q_arn, local.dlq_arn]
        },
        {
          Sid      = "DenyDynamoDb"
          Effect   = "Deny"
          Action   = local.ddb_all_actions
          Resource = [local.tbl_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_deny_actions
          Resource = local.bucket_all
        },
        {
          Sid      = "DenyAllKeyUse"
          Effect   = "Deny"
          Action   = local.kms_deny_use
          Resource = local.all_key_arns
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = local.log_deny_actions
          Resource = local.other_logs.ecs_execution
        },
      ]
    }

    ecs_task = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "PublishEvents"
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
          Resource = [local.q_arn]
        },
        {
          Sid      = "ReadProjections"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
          Resource = [local.tbl_arn, local.gsi_arn]
        },
        {
          Sid      = "UseMessagingAndProjectionKeys"
          Effect   = "Allow"
          Action   = local.kms_usage_actions
          Resource = [local.key_arns.messaging, local.key_arns.projection]
        },
        {
          Sid      = "WriteOwnApiLogs"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources.api
        },
        local.deny_key_lifecycle,
        {
          Sid      = "DenyMainQueueConsume"
          Effect   = "Deny"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
          Resource = [local.q_arn]
        },
        {
          Sid      = "DenyDeadLetterQueue"
          Effect   = "Deny"
          Action   = local.sqs_all_actions
          Resource = [local.dlq_arn]
        },
        {
          Sid      = "DenyProjectionMutation"
          Effect   = "Deny"
          Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
          Resource = [local.tbl_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_deny_actions
          Resource = local.bucket_all
        },
        {
          Sid      = "DenyDatabaseAndAuditKeyUse"
          Effect   = "Deny"
          Action   = local.kms_deny_use
          Resource = [local.key_arns.database, local.key_arns.audit]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = local.log_deny_actions
          Resource = local.other_logs.ecs_task
        },
      ]
    }

    projector = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ConsumeEvents"
          Effect   = "Allow"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
          Resource = [local.q_arn]
        },
        {
          Sid      = "ForwardToDeadLetterQueue"
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = [local.dlq_arn]
        },
        {
          Sid      = "UpsertProjections"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
          Resource = [local.tbl_arn, local.gsi_arn]
        },
        {
          Sid      = "UseMessagingAndProjectionKeys"
          Effect   = "Allow"
          Action   = local.kms_usage_actions
          Resource = [local.key_arns.messaging, local.key_arns.projection]
        },
        {
          Sid      = "WriteOwnProjectorLogs"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources.projector
        },
        local.deny_key_lifecycle,
        {
          Sid      = "DenyMainQueuePublish"
          Effect   = "Deny"
          Action   = ["sqs:SendMessage"]
          Resource = [local.q_arn]
        },
        {
          Sid      = "DenyDeadLetterQueueConsume"
          Effect   = "Deny"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
          Resource = [local.dlq_arn]
        },
        {
          Sid      = "DenyProjectionDelete"
          Effect   = "Deny"
          Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
          Resource = [local.tbl_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_deny_actions
          Resource = local.bucket_all
        },
        {
          Sid      = "DenyDatabaseAndAuditKeyUse"
          Effect   = "Deny"
          Action   = local.kms_deny_use
          Resource = [local.key_arns.database, local.key_arns.audit]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = local.log_deny_actions
          Resource = local.other_logs.projector
        },
      ]
    }

    relay = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "PublishEvents"
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
          Resource = [local.q_arn]
        },
        {
          Sid      = "UseMessagingAndDatabaseKeys"
          Effect   = "Allow"
          Action   = local.kms_usage_actions
          Resource = [local.key_arns.messaging, local.key_arns.database]
        },
        {
          Sid      = "WriteOwnRelayLogs"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources.relay
        },
        local.deny_key_lifecycle,
        {
          Sid      = "DenyMainQueueConsume"
          Effect   = "Deny"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
          Resource = [local.q_arn]
        },
        {
          Sid      = "DenyDeadLetterQueue"
          Effect   = "Deny"
          Action   = local.sqs_all_actions
          Resource = [local.dlq_arn]
        },
        {
          Sid      = "DenyDynamoDb"
          Effect   = "Deny"
          Action   = local.ddb_all_actions
          Resource = [local.tbl_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_deny_actions
          Resource = local.bucket_all
        },
        {
          Sid      = "DenyProjectionAndAuditKeyUse"
          Effect   = "Deny"
          Action   = local.kms_deny_use
          Resource = [local.key_arns.projection, local.key_arns.audit]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = local.log_deny_actions
          Resource = local.other_logs.relay
        },
      ]
    }

    archiver = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "AppendAuditObjects"
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
          Resource = ["${local.bucket_arn}/ledger-audit/*"]
        },
        {
          Sid      = "AuditBucketMetadata"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = [local.bucket_arn]
        },
        {
          Sid      = "UseAuditAndDatabaseKeys"
          Effect   = "Allow"
          Action   = local.kms_usage_actions
          Resource = [local.key_arns.audit, local.key_arns.database]
        },
        {
          Sid      = "WriteOwnArchiverLogs"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources.archiver
        },
        local.deny_key_lifecycle,
        {
          Sid      = "DenyAuditDeletes"
          Effect   = "Deny"
          Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
          Resource = local.bucket_all
        },
        {
          Sid      = "DenySqs"
          Effect   = "Deny"
          Action   = local.sqs_all_actions
          Resource = [local.q_arn, local.dlq_arn]
        },
        {
          Sid      = "DenyDynamoDb"
          Effect   = "Deny"
          Action   = local.ddb_all_actions
          Resource = [local.tbl_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyMessagingAndProjectionKeyUse"
          Effect   = "Deny"
          Action   = local.kms_deny_use
          Resource = [local.key_arns.messaging, local.key_arns.projection]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = local.log_deny_actions
          Resource = local.other_logs.archiver
        },
      ]
    }
  }
}

locals {
  scheduler_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeScheduledWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.relay.arn, aws_lambda_function.archiver.arn]
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenyProjectorInvoke"
        Effect   = "Deny"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.projector.arn]
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [local.q_arn, local.dlq_arn]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = local.ddb_all_actions
        Resource = [local.tbl_arn, local.gsi_arn]
      },
      {
        Sid      = "DenyAuditBucket"
        Effect   = "Deny"
        Action   = local.s3_deny_actions
        Resource = local.bucket_all
      },
      {
        Sid      = "DenyAllKeyUse"
        Effect   = "Deny"
        Action   = local.kms_deny_use
        Resource = local.all_key_arns
      },
      {
        Sid      = "DenyAllLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = flatten(values(local.log_resources))
      },
    ]
  }
}

resource "aws_iam_role" "ecs_execution" {
  name = "${local.prefix}-ecs-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.tags, { ClearLedgerRole = "ecs_execution" })
}

resource "aws_iam_role" "ecs_task" {
  name = "${local.prefix}-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.tags, { ClearLedgerRole = "ecs_task" })
}

resource "aws_iam_role" "projector" {
  name = "${local.prefix}-projector"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.tags, { ClearLedgerRole = "projector" })
}

resource "aws_iam_role" "relay" {
  name = "${local.prefix}-relay"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.tags, { ClearLedgerRole = "relay" })
}

resource "aws_iam_role" "archiver" {
  name = "${local.prefix}-archiver"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.tags, { ClearLedgerRole = "archiver" })
}

resource "aws_iam_role" "scheduler" {
  name = "${local.prefix}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.tags, { ClearLedgerRole = "scheduler" })
}

resource "aws_iam_role_policy" "ecs_execution" {
  name   = "${local.prefix}-ecs-execution"
  role   = aws_iam_role.ecs_execution.id
  policy = jsonencode(local.iam_policies.ecs_execution)
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${local.prefix}-ecs-task"
  role   = aws_iam_role.ecs_task.id
  policy = jsonencode(local.iam_policies.ecs_task)
}

resource "aws_iam_role_policy" "projector" {
  name   = "${local.prefix}-projector"
  role   = aws_iam_role.projector.id
  policy = jsonencode(local.iam_policies.projector)
}

resource "aws_iam_role_policy" "relay" {
  name   = "${local.prefix}-relay"
  role   = aws_iam_role.relay.id
  policy = jsonencode(local.iam_policies.relay)
}

resource "aws_iam_role_policy" "archiver" {
  name   = "${local.prefix}-archiver"
  role   = aws_iam_role.archiver.id
  policy = jsonencode(local.iam_policies.archiver)
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.prefix}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = jsonencode(local.scheduler_policy)
}
