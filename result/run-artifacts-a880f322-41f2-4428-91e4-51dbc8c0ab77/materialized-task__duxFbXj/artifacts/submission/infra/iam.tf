locals {
  kms_arns = { for k in local.kms_usages : k => aws_kms_key.this[k].arn }

  log_group_arns = {
    for k, name in local.log_groups :
    k => "arn:aws:logs:${local.region}:${local.account_id}:log-group:${name}"
  }

  # Resources for a log group: the group ARN itself and its log streams.
  log_resources = {
    for k, arn in local.log_group_arns : k => [arn, "${arn}:*"]
  }

  queue_arn     = aws_sqs_queue.main.arn
  dlq_arn       = aws_sqs_queue.dlq.arn
  table_arn     = aws_dynamodb_table.projections.arn
  gsi_arn       = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn    = aws_s3_bucket.audit.arn
  bucket_object = "${aws_s3_bucket.audit.arn}/*"

  all_kms_arns = [for k in local.kms_usages : local.kms_arns[k]]

  log_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  kms_use_actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  sqs_core_actions  = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_core_actions  = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_core_actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]

  # Guardrail shared by every role: nobody may disable or delete the CMKs.
  deny_kms_destruction = {
    Sid      = "DenyKmsKeyDestruction"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_kms_arns
  }

  other_log_resources = {
    for k in keys(local.log_groups) : k => flatten([
      for o, res in local.log_resources : res if o != k
    ])
  }

  role_policies = {
    ecs_execution = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "AllowApiLogWrites"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources["api"]
        },
        local.deny_kms_destruction,
        {
          Sid      = "DenyKmsDataKeyUsage"
          Effect   = "Deny"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = local.all_kms_arns
        },
        {
          Sid      = "DenySqs"
          Effect   = "Deny"
          Action   = local.sqs_core_actions
          Resource = [local.queue_arn, local.dlq_arn]
        },
        {
          Sid      = "DenyDynamoDb"
          Effect   = "Deny"
          Action   = local.ddb_core_actions
          Resource = [local.table_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_core_actions
          Resource = [local.bucket_arn, local.bucket_object]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = local.other_log_resources["api"]
        },
      ]
    }

    ecs_task = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "AllowPublishMainQueue"
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
          Resource = [local.queue_arn]
        },
        {
          Sid      = "AllowReadProjections"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
          Resource = [local.table_arn, local.gsi_arn]
        },
        {
          Sid      = "AllowKmsMessagingProjection"
          Effect   = "Allow"
          Action   = local.kms_use_actions
          Resource = [local.kms_arns["messaging"], local.kms_arns["projection"]]
        },
        {
          Sid      = "AllowApiLogWrites"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources["api"]
        },
        local.deny_kms_destruction,
        {
          Sid      = "DenyForeignKmsKeys"
          Effect   = "Deny"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = [local.kms_arns["database"], local.kms_arns["audit"]]
        },
        {
          Sid      = "DenyConsumeMainQueue"
          Effect   = "Deny"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
          Resource = [local.queue_arn]
        },
        {
          Sid      = "DenyDlq"
          Effect   = "Deny"
          Action   = local.sqs_core_actions
          Resource = [local.dlq_arn]
        },
        {
          Sid      = "DenyMutateProjections"
          Effect   = "Deny"
          Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
          Resource = [local.table_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_core_actions
          Resource = [local.bucket_arn, local.bucket_object]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = local.other_log_resources["api"]
        },
      ]
    }

    projector = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "AllowConsumeMainQueue"
          Effect   = "Allow"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
          Resource = [local.queue_arn]
        },
        {
          Sid      = "AllowDeadLetterForwarding"
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = [local.dlq_arn]
        },
        {
          Sid      = "AllowProjectionUpserts"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
          Resource = [local.table_arn, local.gsi_arn]
        },
        {
          Sid      = "AllowKmsMessagingProjection"
          Effect   = "Allow"
          Action   = local.kms_use_actions
          Resource = [local.kms_arns["messaging"], local.kms_arns["projection"]]
        },
        {
          Sid      = "AllowProjectorLogWrites"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources["projector"]
        },
        local.deny_kms_destruction,
        {
          Sid      = "DenyForeignKmsKeys"
          Effect   = "Deny"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = [local.kms_arns["database"], local.kms_arns["audit"]]
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
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_core_actions
          Resource = [local.bucket_arn, local.bucket_object]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = local.other_log_resources["projector"]
        },
      ]
    }

    relay = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "AllowPublishMainQueue"
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
          Resource = [local.queue_arn]
        },
        {
          Sid      = "AllowKmsMessagingDatabase"
          Effect   = "Allow"
          Action   = local.kms_use_actions
          Resource = [local.kms_arns["messaging"], local.kms_arns["database"]]
        },
        {
          Sid      = "AllowRelayLogWrites"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources["relay"]
        },
        local.deny_kms_destruction,
        {
          Sid      = "DenyForeignKmsKeys"
          Effect   = "Deny"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = [local.kms_arns["projection"], local.kms_arns["audit"]]
        },
        {
          Sid      = "DenyConsumeMainQueue"
          Effect   = "Deny"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
          Resource = [local.queue_arn]
        },
        {
          Sid      = "DenyDlq"
          Effect   = "Deny"
          Action   = local.sqs_core_actions
          Resource = [local.dlq_arn]
        },
        {
          Sid      = "DenyDynamoDb"
          Effect   = "Deny"
          Action   = local.ddb_core_actions
          Resource = [local.table_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_core_actions
          Resource = [local.bucket_arn, local.bucket_object]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = local.other_log_resources["relay"]
        },
      ]
    }

    archiver = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "AllowAuditObjectAppend"
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
          Resource = ["${local.bucket_arn}/ledger-audit/*"]
        },
        {
          Sid      = "AllowAuditBucketMetadata"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = [local.bucket_arn]
        },
        {
          Sid      = "AllowKmsAuditDatabase"
          Effect   = "Allow"
          Action   = local.kms_use_actions
          Resource = [local.kms_arns["audit"], local.kms_arns["database"]]
        },
        {
          Sid      = "AllowArchiverLogWrites"
          Effect   = "Allow"
          Action   = local.log_write_actions
          Resource = local.log_resources["archiver"]
        },
        local.deny_kms_destruction,
        {
          Sid      = "DenyForeignKmsKeys"
          Effect   = "Deny"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = [local.kms_arns["messaging"], local.kms_arns["projection"]]
        },
        {
          Sid      = "DenyAuditDeletes"
          Effect   = "Deny"
          Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
          Resource = [local.bucket_arn, local.bucket_object]
        },
        {
          Sid      = "DenySqs"
          Effect   = "Deny"
          Action   = local.sqs_core_actions
          Resource = [local.queue_arn, local.dlq_arn]
        },
        {
          Sid      = "DenyDynamoDb"
          Effect   = "Deny"
          Action   = local.ddb_core_actions
          Resource = [local.table_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyForeignLogGroups"
          Effect   = "Deny"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = local.other_log_resources["archiver"]
        },
      ]
    }

    scheduler = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "AllowInvokeScheduledWorkers"
          Effect   = "Allow"
          Action   = ["lambda:InvokeFunction"]
          Resource = [aws_lambda_function.relay.arn, aws_lambda_function.archiver.arn]
        },
        local.deny_kms_destruction,
        {
          Sid      = "DenyInvokeProjector"
          Effect   = "Deny"
          Action   = ["lambda:InvokeFunction"]
          Resource = [aws_lambda_function.projector.arn, "${aws_lambda_function.projector.arn}:*"]
        },
        {
          Sid      = "DenyKmsDataKeyUsage"
          Effect   = "Deny"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = local.all_kms_arns
        },
        {
          Sid      = "DenySqs"
          Effect   = "Deny"
          Action   = local.sqs_core_actions
          Resource = [local.queue_arn, local.dlq_arn]
        },
        {
          Sid      = "DenyDynamoDb"
          Effect   = "Deny"
          Action   = local.ddb_core_actions
          Resource = [local.table_arn, local.gsi_arn]
        },
        {
          Sid      = "DenyAuditBucket"
          Effect   = "Deny"
          Action   = local.s3_core_actions
          Resource = [local.bucket_arn, local.bucket_object]
        },
        {
          Sid      = "DenyAllLogGroups"
          Effect   = "Deny"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = flatten([for k, res in local.log_resources : res])
        },
      ]
    }
  }

  role_trust = {
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
    relay         = "${local.prefix}-outbox-relay"
    archiver      = "${local.prefix}-audit-archiver"
    scheduler     = "${local.prefix}-scheduler"
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_trust

  name                  = local.role_names[each.key]
  description           = "ClearLedger ${local.prefix} ${each.key} role"
  force_detach_policies = true

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TrustService"
      Effect    = "Allow"
      Principal = { Service = each.value }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, {
    Name            = local.role_names[each.key]
    ClearLedgerRole = each.key
  })
}

resource "aws_iam_role_policy" "this" {
  for_each = local.role_trust

  name   = "${local.role_names[each.key]}-policy"
  role   = aws_iam_role.this[each.key].id
  policy = jsonencode(local.role_policies[each.key])
}
