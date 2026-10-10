locals {
  queue_arn  = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  table_arn  = aws_dynamodb_table.projections.arn
  index_arn  = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn
  objects    = "${aws_s3_bucket.audit.arn}/*"
  audit_objs = "${aws_s3_bucket.audit.arn}/ledger-audit/*"

  kms = { for k, v in aws_kms_key.this : k => v.arn }

  fn_names = {
    projector = "${var.resource_prefix}-projector"
    relay     = "${var.resource_prefix}-outbox-relay"
    archiver  = "${var.resource_prefix}-audit-archiver"
  }
  fn_arns = { for k, n in local.fn_names : k => "arn:aws:lambda:${var.region}:${local.account_id}:function:${n}" }

  sqs_data_actions = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_data_actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_data_actions  = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  kms_use_actions  = ["kms:Decrypt", "kms:GenerateDataKey"]
  log_write        = ["logs:CreateLogStream", "logs:PutLogEvents"]
  log_allow        = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]

  # ------------------------------------------------------------------
  # Reusable deny guardrails
  # ------------------------------------------------------------------
  deny_all_sqs = {
    Sid      = "DenyAllQueueData"
    Effect   = "Deny"
    Action   = local.sqs_data_actions
    Resource = [local.queue_arn, local.dlq_arn]
  }
  deny_all_ddb = {
    Sid      = "DenyProjectionTable"
    Effect   = "Deny"
    Action   = local.ddb_data_actions
    Resource = [local.table_arn, local.index_arn]
  }
  deny_all_s3 = {
    Sid      = "DenyAuditBucket"
    Effect   = "Deny"
    Action   = local.s3_data_actions
    Resource = [local.bucket_arn, local.objects]
  }

  deny_kms = {
    for role, keys in {
      ecs_execution = ["database", "messaging", "projection", "audit"]
      ecs_task      = ["database", "audit"]
      projector     = ["database", "audit"]
      relay         = ["projection", "audit"]
      archiver      = ["messaging", "projection"]
      scheduler     = ["database", "messaging", "projection", "audit"]
      } : role => {
      Sid      = "DenyForeignKmsKeys"
      Effect   = "Deny"
      Action   = local.kms_use_actions
      Resource = [for k in keys : local.kms[k]]
    }
  }

  deny_logs = {
    for role, groups in {
      ecs_execution = ["projector", "relay", "archiver"]
      ecs_task      = ["projector", "relay", "archiver"]
      projector     = ["api", "relay", "archiver"]
      relay         = ["api", "projector", "archiver"]
      archiver      = ["api", "projector", "relay"]
      scheduler     = ["api", "projector", "relay", "archiver"]
      } : role => {
      Sid      = "DenyForeignLogGroups"
      Effect   = "Deny"
      Action   = local.log_write
      Resource = flatten([for g in groups : local.log_arns[g]])
    }
  }

  policies = {
    ecs_execution = [
      {
        Sid      = "ApiLogStreams"
        Effect   = "Allow"
        Action   = local.log_allow
        Resource = local.log_arns["api"]
      },
      local.deny_all_sqs,
      local.deny_all_ddb,
      local.deny_all_s3,
      local.deny_kms["ecs_execution"],
      local.deny_logs["ecs_execution"],
    ]

    ecs_task = [
      {
        Sid      = "PublishDomainEvents"
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
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms["messaging"], local.kms["projection"]]
      },
      {
        Sid      = "ApiLogStreams"
        Effect   = "Allow"
        Action   = local.log_allow
        Resource = local.log_arns["api"]
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
        Action   = local.sqs_data_actions
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn, local.index_arn]
      },
      local.deny_all_s3,
      local.deny_kms["ecs_task"],
      local.deny_logs["ecs_task"],
    ]

    projector = [
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
        Resource = [local.table_arn, local.index_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms["messaging"], local.kms["projection"]]
      },
      {
        Sid      = "ProjectorLogStreams"
        Effect   = "Allow"
        Action   = local.log_allow
        Resource = local.log_arns["projector"]
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
        Resource = [local.table_arn, local.index_arn]
      },
      local.deny_all_s3,
      local.deny_kms["projector"],
      local.deny_logs["projector"],
    ]

    relay = [
      {
        Sid      = "PublishDomainEvents"
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
        Sid      = "RelayLogStreams"
        Effect   = "Allow"
        Action   = local.log_allow
        Resource = local.log_arns["relay"]
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
        Action   = local.sqs_data_actions
        Resource = [local.dlq_arn]
      },
      local.deny_all_ddb,
      local.deny_all_s3,
      local.deny_kms["relay"],
      local.deny_logs["relay"],
    ]

    archiver = [
      {
        Sid      = "AppendAuditObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = [local.audit_objs]
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
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms["audit"], local.kms["database"]]
      },
      {
        Sid      = "ArchiverLogStreams"
        Effect   = "Allow"
        Action   = local.log_allow
        Resource = local.log_arns["archiver"]
      },
      {
        Sid      = "DenyAuditDeletes"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = [local.bucket_arn, local.objects]
      },
      {
        Sid      = "DenyBucketLevelPut"
        Effect   = "Deny"
        Action   = ["s3:PutObject"]
        Resource = [local.bucket_arn]
      },
      local.deny_all_sqs,
      local.deny_all_ddb,
      local.deny_kms["archiver"],
      local.deny_logs["archiver"],
    ]

    scheduler = [
      {
        Sid      = "InvokeScheduledWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arns["relay"], local.fn_arns["archiver"]]
      },
      {
        Sid      = "DenyInvokeProjector"
        Effect   = "Deny"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arns["projector"], "${local.fn_arns["projector"]}:*"]
      },
      local.deny_all_sqs,
      local.deny_all_ddb,
      local.deny_all_s3,
      local.deny_kms["scheduler"],
      local.deny_logs["scheduler"],
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
    ecs_execution = "${var.resource_prefix}-ecs-execution"
    ecs_task      = "${var.resource_prefix}-ecs-task"
    projector     = "${var.resource_prefix}-projector"
    relay         = "${var.resource_prefix}-outbox-relay"
    archiver      = "${var.resource_prefix}-audit-archiver"
    scheduler     = "${var.resource_prefix}-scheduler"
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_principals

  name = local.role_names[each.key]
  path = "/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TrustedService"
      Effect    = "Allow"
      Principal = { Service = each.value }
      Action    = "sts:AssumeRole"
    }]
  })
  force_detach_policies = true

  tags = { Name = local.role_names[each.key], Workload = each.key }
}

resource "aws_iam_role_policy" "this" {
  for_each = local.policies

  name = "${local.role_names[each.key]}-least-privilege"
  role = aws_iam_role.this[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value
  })
}

# Terraform owns the complete inline/attached policy set of every workload
# role: any out-of-band inline policy or attachment is removed on apply.
resource "aws_iam_role_policies_exclusive" "this" {
  for_each = local.policies

  role_name    = aws_iam_role.this[each.key].name
  policy_names = [aws_iam_role_policy.this[each.key].name]
}

resource "aws_iam_role_policy_attachments_exclusive" "this" {
  for_each = local.policies

  role_name   = aws_iam_role.this[each.key].name
  policy_arns = []
}
