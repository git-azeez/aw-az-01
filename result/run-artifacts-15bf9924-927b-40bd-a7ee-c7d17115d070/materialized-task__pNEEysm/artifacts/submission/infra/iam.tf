locals {
  key_arn = { for k, v in aws_kms_key.this : k => v.arn }
  all_key_arns = [
    local.key_arn["database"],
    local.key_arn["messaging"],
    local.key_arn["projection"],
    local.key_arn["audit"],
  ]

  queue_arn  = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  table_arn  = aws_dynamodb_table.projections.arn
  index_arn  = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn
  bucket_all = "${aws_s3_bucket.audit.arn}/*"
  bucket_obj = "${aws_s3_bucket.audit.arn}/ledger-audit/*"

  # Log group resources: the group itself and its streams, nothing broader.
  lg = {
    api       = [aws_cloudwatch_log_group.api.arn, "${aws_cloudwatch_log_group.api.arn}:*"]
    projector = [aws_cloudwatch_log_group.projector.arn, "${aws_cloudwatch_log_group.projector.arn}:*"]
    relay     = [aws_cloudwatch_log_group.relay.arn, "${aws_cloudwatch_log_group.relay.arn}:*"]
    archiver  = [aws_cloudwatch_log_group.archiver.arn, "${aws_cloudwatch_log_group.archiver.arn}:*"]
  }

  fn_arn_projector = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-projector"
  fn_arn_relay     = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-outbox-relay"
  fn_arn_archiver  = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-audit-archiver"

  log_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  log_deny_actions  = ["logs:CreateLogStream", "logs:PutLogEvents"]
  kms_use_actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny_use      = ["kms:Decrypt", "kms:GenerateDataKey"]
  ddb_all_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_all_actions    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  sqs_all_actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]

  # Every role: never allowed to disable / schedule deletion of the CMKs.
  deny_kms_admin = {
    Sid      = "DenyKmsKeyLifecycle"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_key_arns
  }

  deny_s3_audit = {
    Sid      = "DenyAuditBucketAccess"
    Effect   = "Deny"
    Action   = local.s3_all_actions
    Resource = [local.bucket_arn, local.bucket_all]
  }

  deny_ddb_all = {
    Sid      = "DenyProjectionTableAccess"
    Effect   = "Deny"
    Action   = local.ddb_all_actions
    Resource = [local.table_arn, local.index_arn]
  }

  deny_sqs_all = {
    Sid      = "DenyQueueAccess"
    Effect   = "Deny"
    Action   = local.sqs_all_actions
    Resource = [local.queue_arn, local.dlq_arn]
  }

  policies = {
    ecs_execution = [
      {
        Sid      = "WriteApiLogs"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.lg.api
      },
      local.deny_kms_admin,
      local.deny_sqs_all,
      local.deny_ddb_all,
      local.deny_s3_audit,
      {
        Sid      = "DenyAllKmsUse"
        Effect   = "Deny"
        Action   = local.kms_deny_use
        Resource = local.all_key_arns
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.lg.projector, local.lg.relay, local.lg.archiver)
      },
    ]

    ecs_task = [
      {
        Sid      = "PublishEvents"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = [local.table_arn, local.index_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.key_arn["messaging"], local.key_arn["projection"]]
      },
      {
        Sid      = "WriteApiLogs"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.lg.api
      },
      local.deny_kms_admin,
      {
        Sid      = "DenyQueueConsumeAndDlq"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn]
      },
      local.deny_s3_audit,
      {
        Sid      = "DenyForeignKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_use
        Resource = [local.key_arn["database"], local.key_arn["audit"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.lg.projector, local.lg.relay, local.lg.archiver)
      },
    ]

    projector = [
      {
        Sid      = "ConsumeEvents"
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
        Resource = [local.table_arn, local.index_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.key_arn["messaging"], local.key_arn["projection"]]
      },
      {
        Sid      = "WriteProjectorLogs"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.lg.projector
      },
      local.deny_kms_admin,
      {
        Sid      = "DenyQueueProduce"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyDlqConsume"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionDeletes"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn]
      },
      local.deny_s3_audit,
      {
        Sid      = "DenyForeignKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_use
        Resource = [local.key_arn["database"], local.key_arn["audit"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.lg.api, local.lg.relay, local.lg.archiver)
      },
    ]

    relay = [
      {
        Sid      = "PublishEvents"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.key_arn["messaging"], local.key_arn["database"]]
      },
      {
        Sid      = "WriteRelayLogs"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.lg.relay
      },
      local.deny_kms_admin,
      {
        Sid      = "DenyQueueConsume"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyDlqAccess"
        Effect   = "Deny"
        Action   = local.sqs_all_actions
        Resource = [local.dlq_arn]
      },
      local.deny_ddb_all,
      local.deny_s3_audit,
      {
        Sid      = "DenyForeignKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_use
        Resource = [local.key_arn["projection"], local.key_arn["audit"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.lg.api, local.lg.projector, local.lg.archiver)
      },
    ]

    archiver = [
      {
        Sid      = "AppendAuditObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = [local.bucket_obj]
      },
      {
        Sid      = "ListAuditBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [local.bucket_arn]
      },
      {
        Sid      = "UseAuditAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.key_arn["audit"], local.key_arn["database"]]
      },
      {
        Sid      = "WriteArchiverLogs"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.lg.archiver
      },
      local.deny_kms_admin,
      {
        Sid      = "DenyAuditDeletes"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = [local.bucket_arn, local.bucket_all]
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      {
        Sid      = "DenyForeignKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_use
        Resource = [local.key_arn["messaging"], local.key_arn["projection"]]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.lg.api, local.lg.projector, local.lg.relay)
      },
    ]

    scheduler = [
      {
        Sid      = "InvokeScheduledWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arn_relay, local.fn_arn_archiver]
      },
      local.deny_kms_admin,
      {
        Sid      = "DenyInvokeProjector"
        Effect   = "Deny"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arn_projector]
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      local.deny_s3_audit,
      {
        Sid      = "DenyAllKmsUse"
        Effect   = "Deny"
        Action   = local.kms_deny_use
        Resource = local.all_key_arns
      },
      {
        Sid      = "DenyAllLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = concat(local.lg.api, local.lg.projector, local.lg.relay, local.lg.archiver)
      },
    ]
  }

  role_principals = {
    ecs_execution = "ecs-tasks.amazonaws.com"
    ecs_task      = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com"
    relay         = "lambda.amazonaws.com"
    archiver      = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }

  role_names = {
    ecs_execution = "${local.prefix}-ecs-execution"
    ecs_task      = "${local.prefix}-ecs-task"
    projector     = "${local.prefix}-projector"
    relay         = "${local.prefix}-relay"
    archiver      = "${local.prefix}-archiver"
    scheduler     = "${local.prefix}-scheduler"
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_principals
  name     = local.role_names[each.key]

  force_detach_policies = true

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = each.value }
    }]
  })

  tags = merge(local.tags, { ClearLedgerRole = each.key })
}

resource "aws_iam_role_policy" "this" {
  for_each = toset(keys(local.policies))
  name     = "${local.prefix}-${each.key}-policy"
  role     = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policies[each.key]
  })
}
