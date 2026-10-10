locals {
  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }
  all_kms = [for k in ["database", "messaging", "projection", "audit"] : local.kms_arn[k]]

  q_main  = aws_sqs_queue.main.arn
  q_dlq   = aws_sqs_queue.dlq.arn
  queues  = [local.q_main, local.q_dlq]
  tbl     = aws_dynamodb_table.projections.arn
  tbl_idx = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  tables  = [local.tbl, local.tbl_idx]
  bkt     = aws_s3_bucket.audit.arn
  bkt_all = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

  # Log group ARNs (group itself and its streams) per workload.
  lg = {
    for k, v in aws_cloudwatch_log_group.this : k => [v.arn, "${v.arn}:*"]
  }
  lg_others = {
    for k in keys(local.log_groups) :
    k => flatten([for o in keys(local.log_groups) : local.lg[o] if o != k])
  }

  logs_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]

  fn_arn = {
    projector = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-projector"
    relay     = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-outbox-relay"
    archiver  = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-audit-archiver"
  }

  deny_key_lifecycle = {
    Sid      = "DenyKeyLifecycle"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_kms
  }

  roles = {
    ecs_execution = { name = "${local.prefix}-ecs-execution", principal = "ecs-tasks.amazonaws.com" }
    ecs_task      = { name = "${local.prefix}-ecs-task", principal = "ecs-tasks.amazonaws.com" }
    projector     = { name = "${local.prefix}-projector", principal = "lambda.amazonaws.com" }
    relay         = { name = "${local.prefix}-relay", principal = "lambda.amazonaws.com" }
    archiver      = { name = "${local.prefix}-archiver", principal = "lambda.amazonaws.com" }
    scheduler     = { name = "${local.prefix}-scheduler", principal = "scheduler.amazonaws.com" }
  }

  policies = {
    ecs_execution = [
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = local.logs_actions
        Resource = local.lg.api
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = local.queues
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
        Resource = local.tables
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = local.bkt_all
      },
      {
        Sid      = "DenyKmsUse"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.all_kms
      },
      {
        Sid      = "DenyForeignLogs"
        Effect   = "Deny"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = local.lg_others.api
      },
    ]

    ecs_task = [
      {
        Sid      = "PublishEvents"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_main]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = local.tables
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = local.logs_actions
        Resource = local.lg.api
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_main]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_dlq]
      },
      {
        Sid      = "DenyDynamoDbMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = local.tables
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = local.bkt_all
      },
      {
        Sid      = "DenyForeignKmsUse"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn.database, local.kms_arn.audit]
      },
      {
        Sid      = "DenyForeignLogs"
        Effect   = "Deny"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = local.lg_others.api
      },
    ]

    projector = [
      {
        Sid      = "ConsumeMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = [local.q_main]
      },
      {
        Sid      = "ForwardToDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [local.q_dlq]
      },
      {
        Sid      = "UpsertProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = local.tables
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = local.logs_actions
        Resource = local.lg.projector
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenyMainQueuePublish"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [local.q_main]
      },
      {
        Sid      = "DenyDlqConsume"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_dlq]
      },
      {
        Sid      = "DenyDynamoDbDelete"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = local.tables
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = local.bkt_all
      },
      {
        Sid      = "DenyForeignKmsUse"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn.database, local.kms_arn.audit]
      },
      {
        Sid      = "DenyForeignLogs"
        Effect   = "Deny"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = local.lg_others.projector
      },
    ]

    relay = [
      {
        Sid      = "PublishEvents"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_main]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms_arn.messaging, local.kms_arn.database]
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = local.logs_actions
        Resource = local.lg.relay
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_main]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_dlq]
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
        Resource = local.tables
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = local.bkt_all
      },
      {
        Sid      = "DenyForeignKmsUse"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn.projection, local.kms_arn.audit]
      },
      {
        Sid      = "DenyForeignLogs"
        Effect   = "Deny"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = local.lg_others.relay
      },
    ]

    archiver = [
      {
        Sid      = "AuditObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.bkt}/ledger-audit/*"]
      },
      {
        Sid      = "AuditBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [local.bkt]
      },
      {
        Sid      = "UseAuditAndDatabaseKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms_arn.audit, local.kms_arn.database]
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = local.logs_actions
        Resource = local.lg.archiver
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenyS3Delete"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = local.bkt_all
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = local.queues
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
        Resource = local.tables
      },
      {
        Sid      = "DenyForeignKmsUse"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "DenyForeignLogs"
        Effect   = "Deny"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = local.lg_others.archiver
      },
    ]

    scheduler = [
      {
        Sid      = "InvokeScheduledWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arn.relay, local.fn_arn.archiver]
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenyProjectorInvoke"
        Effect   = "Deny"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arn.projector]
      },
      {
        Sid      = "DenySqs"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = local.queues
      },
      {
        Sid      = "DenyDynamoDb"
        Effect   = "Deny"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
        Resource = local.tables
      },
      {
        Sid      = "DenyS3"
        Effect   = "Deny"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = local.bkt_all
      },
      {
        Sid      = "DenyKmsUse"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.all_kms
      },
      {
        Sid      = "DenyLogs"
        Effect   = "Deny"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = flatten(values(local.lg))
      },
    ]
  }
}

resource "aws_iam_role" "this" {
  for_each              = local.roles
  name                  = each.value.name
  force_detach_policies = true

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = each.value.principal }
    }]
  })

  tags = {
    Name            = each.value.name
    ClearLedgerRole = each.key
  }
}

resource "aws_iam_role_policy" "this" {
  for_each = local.roles
  name     = "${each.value.name}-policy"
  role     = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policies[each.key]
  })
}
