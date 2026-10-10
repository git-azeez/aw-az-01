locals {
  role_trust = {
    ecs_execution = "ecs-tasks.amazonaws.com"
    ecs_task      = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com"
    relay         = "lambda.amazonaws.com"
    archiver      = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }

  # Resource ARNs, built from names so the policies never depend on resources
  # that in turn depend on the roles.
  q_arn      = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  table_arn  = aws_dynamodb_table.projections.arn
  gsi_arn    = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn
  kms_arn    = { for k, v in aws_kms_key.this : k => v.arn }
  fn_arn     = { for k, v in aws_lambda_function.this : k => v.arn }

  logs_base = "arn:aws:logs:${local.region}:${local.account_id}:log-group:"
  lg_arn    = { for k, v in local.log_groups : k => "${local.logs_base}${v}*" }

  all_kms_arns = [for k in ["database", "messaging", "projection", "audit"] : local.kms_arn[k]]
  s3_arns      = [local.bucket_arn, "${local.bucket_arn}/*"]
  ddb_arns     = [local.table_arn, local.gsi_arn]
  both_queues  = [local.q_arn, local.dlq_arn]

  # Own log group per logging workload.
  own_log = {
    ecs_execution = "api"
    ecs_task      = "api"
    projector     = "projector"
    relay         = "relay"
    archiver      = "archiver"
  }

  log_write = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  crypto    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]

  deny_key_lifecycle = {
    Sid      = "DenyKmsKeyLifecycle"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_kms_arns
  }

  # Deny log writes on every log group except the workload's own.
  deny_foreign_logs = { for r in keys(local.own_log) : r => {
    Sid      = "DenyForeignLogGroups"
    Effect   = "Deny"
    Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    Resource = [for k, v in local.lg_arn : v if k != local.own_log[r]]
  } }

  allow_own_logs = { for r, g in local.own_log : r => {
    Sid      = "WriteOwnLogGroup"
    Effect   = "Allow"
    Action   = local.log_write
    Resource = [local.lg_arn[g]]
  } }

  deny_ddb_all = {
    Sid      = "DenyDynamoDbAccess"
    Effect   = "Deny"
    Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
    Resource = local.ddb_arns
  }
  deny_s3_all = {
    Sid      = "DenyAuditBucketAccess"
    Effect   = "Deny"
    Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    Resource = local.s3_arns
  }
  deny_sqs_all = {
    Sid      = "DenyQueueAccess"
    Effect   = "Deny"
    Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
    Resource = local.both_queues
  }

  role_policies = {
    ecs_execution = [
      local.allow_own_logs["ecs_execution"],
      local.deny_key_lifecycle,
      local.deny_sqs_all,
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyKmsCrypto"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.all_kms_arns
      },
      local.deny_foreign_logs["ecs_execution"],
    ]

    ecs_task = [
      {
        Sid      = "PublishToEventQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = local.ddb_arns
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.crypto
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      local.allow_own_logs["ecs_task"],
      local.deny_key_lifecycle,
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDeadLetterQueue"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn]
      },
      local.deny_s3_all,
      {
        Sid      = "DenyForeignKmsCrypto"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn["database"], local.kms_arn["audit"]]
      },
      local.deny_foreign_logs["ecs_task"],
    ]

    projector = [
      {
        Sid      = "ConsumeEventQueue"
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
        Resource = local.ddb_arns
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.crypto
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      local.allow_own_logs["projector"],
      local.deny_key_lifecycle,
      {
        Sid      = "DenyPublishToMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyConsumeDeadLetterQueue"
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
      local.deny_s3_all,
      {
        Sid      = "DenyForeignKmsCrypto"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn["database"], local.kms_arn["audit"]]
      },
      local.deny_foreign_logs["projector"],
    ]

    relay = [
      {
        Sid      = "PublishToEventQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.crypto
        Resource = [local.kms_arn["messaging"], local.kms_arn["database"]]
      },
      local.allow_own_logs["relay"],
      local.deny_key_lifecycle,
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDeadLetterQueue"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyForeignKmsCrypto"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn["projection"], local.kms_arn["audit"]]
      },
      local.deny_foreign_logs["relay"],
    ]

    archiver = [
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
        Action   = local.crypto
        Resource = [local.kms_arn["audit"], local.kms_arn["database"]]
      },
      local.allow_own_logs["archiver"],
      local.deny_key_lifecycle,
      {
        Sid      = "DenyAuditDeletes"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = local.s3_arns
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      {
        Sid      = "DenyForeignKmsCrypto"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      local.deny_foreign_logs["archiver"],
    ]

    scheduler = [
      {
        Sid      = "InvokeScheduledWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arn["relay"], local.fn_arn["archiver"]]
      },
      local.deny_key_lifecycle,
      {
        Sid      = "DenyInvokeProjector"
        Effect   = "Deny"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arn["projector"]]
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyKmsCrypto"
        Effect   = "Deny"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.all_kms_arns
      },
      {
        Sid      = "DenyAllLogWrites"
        Effect   = "Deny"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = values(local.lg_arn)
      },
    ]
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_trust
  name     = "${local.prefix}-${replace(each.key, "_", "-")}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = each.value }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { ClearLedgerRole = each.key })
}

resource "aws_iam_role_policy" "this" {
  for_each = local.role_policies
  name     = "${local.prefix}-${replace(each.key, "_", "-")}-policy"
  role     = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value
  })
}
