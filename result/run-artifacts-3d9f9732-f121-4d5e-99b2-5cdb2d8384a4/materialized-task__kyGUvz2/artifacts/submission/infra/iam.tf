# Six dedicated workload roles. Each role gets exactly one canonical inline policy that contains
# scoped Allow statements plus explicit Deny guardrails. deploy.sh removes anything else attached
# out-of-band.

locals {
  roles = {
    ecs_execution = "ecs-tasks.amazonaws.com"
    ecs_task      = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com"
    relay         = "lambda.amazonaws.com"
    archiver      = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }

  q_arn    = aws_sqs_queue.main.arn
  dlq_arn  = aws_sqs_queue.dlq.arn
  t_arn    = aws_dynamodb_table.projection.arn
  idx_arn  = "${aws_dynamodb_table.projection.arn}/index/AccountIndex"
  b_arn    = aws_s3_bucket.audit.arn
  b_objs   = "${aws_s3_bucket.audit.arn}/*"
  b_prefix = "${aws_s3_bucket.audit.arn}/${local.audit_prefix}*"

  key_arn = { for k, v in aws_kms_key.this : k => v.arn }

  # Log group ARN plus its stream ARN form (arn:...:log-group:<name>:*).
  log_arns = {
    for k, v in aws_cloudwatch_log_group.this : k => [v.arn, "${v.arn}:*"]
  }

  logs_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  logs_deny_actions  = ["logs:CreateLogStream", "logs:PutLogEvents"]
  kms_use_actions    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny_actions   = ["kms:Decrypt", "kms:GenerateDataKey"]

  ddb_rw_actions  = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_deny_actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]

  keys_except = {
    for role, allowed in {
      ecs_execution = []
      ecs_task      = ["messaging", "projection"]
      projector     = ["messaging", "projection"]
      relay         = ["messaging", "database"]
      archiver      = ["audit", "database"]
      scheduler     = []
    } : role => [for k in sort(tolist(local.kms_purposes)) : local.key_arn[k] if !contains(allowed, k)]
  }

  keys_allowed = {
    ecs_task  = [local.key_arn["messaging"], local.key_arn["projection"]]
    projector = [local.key_arn["messaging"], local.key_arn["projection"]]
    relay     = [local.key_arn["messaging"], local.key_arn["database"]]
    archiver  = [local.key_arn["audit"], local.key_arn["database"]]
  }

  other_logs = {
    for role, own in {
      ecs_execution = ["api"]
      ecs_task      = ["api"]
      projector     = ["projector"]
      relay         = ["relay"]
      archiver      = ["archiver"]
      scheduler     = []
    } : role => flatten([for k in ["api", "projector", "relay", "archiver"] : local.log_arns[k] if !contains(own, k)])
  }

  policy_statements = {
    ecs_execution = [
      {
        Sid      = "WriteOwnApiLogs"
        Effect   = "Allow"
        Action   = local.logs_write_actions
        Resource = local.log_arns["api"]
      },
      {
        Sid      = "DenyQueueAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn, local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionAccess"
        Effect   = "Deny"
        Action   = local.ddb_rw_actions
        Resource = [local.t_arn, local.idx_arn]
      },
      {
        Sid      = "DenyAuditBucketAccess"
        Effect   = "Deny"
        Action   = local.s3_deny_actions
        Resource = [local.b_arn, local.b_objs]
      },
      {
        Sid      = "DenyAllKeyUsage"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = local.keys_except["ecs_execution"]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny_actions
        Resource = local.other_logs["ecs_execution"]
      },
    ]

    ecs_task = [
      {
        Sid      = "PublishToMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "ReadProjection"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = [local.t_arn, local.idx_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = local.keys_allowed["ecs_task"]
      },
      {
        Sid      = "WriteOwnApiLogs"
        Effect   = "Allow"
        Action   = local.logs_write_actions
        Resource = local.log_arns["api"]
      },
      {
        Sid      = "DenyQueueConsumption"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDeadLetterQueueAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionMutation"
        Effect   = "Deny"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.t_arn]
      },
      {
        Sid      = "DenyAuditBucketAccess"
        Effect   = "Deny"
        Action   = local.s3_deny_actions
        Resource = [local.b_arn, local.b_objs]
      },
      {
        Sid      = "DenyForeignKeyUsage"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = local.keys_except["ecs_task"]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny_actions
        Resource = local.other_logs["ecs_task"]
      },
    ]

    projector = [
      {
        Sid      = "ConsumeMainQueue"
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
        Sid      = "UpsertProjection"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = [local.t_arn, local.idx_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = local.keys_allowed["projector"]
      },
      {
        Sid      = "WriteOwnProjectorLogs"
        Effect   = "Allow"
        Action   = local.logs_write_actions
        Resource = local.log_arns["projector"]
      },
      {
        Sid      = "DenyMainQueuePublish"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDeadLetterQueueConsumption"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionDeletion"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.t_arn]
      },
      {
        Sid      = "DenyAuditBucketAccess"
        Effect   = "Deny"
        Action   = local.s3_deny_actions
        Resource = [local.b_arn, local.b_objs]
      },
      {
        Sid      = "DenyForeignKeyUsage"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = local.keys_except["projector"]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny_actions
        Resource = local.other_logs["projector"]
      },
    ]

    relay = [
      {
        Sid      = "PublishToMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = local.keys_allowed["relay"]
      },
      {
        Sid      = "WriteOwnRelayLogs"
        Effect   = "Allow"
        Action   = local.logs_write_actions
        Resource = local.log_arns["relay"]
      },
      {
        Sid      = "DenyMainQueueConsumption"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "DenyDeadLetterQueueAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionAccess"
        Effect   = "Deny"
        Action   = local.ddb_rw_actions
        Resource = [local.t_arn, local.idx_arn]
      },
      {
        Sid      = "DenyAuditBucketAccess"
        Effect   = "Deny"
        Action   = local.s3_deny_actions
        Resource = [local.b_arn, local.b_objs]
      },
      {
        Sid      = "DenyForeignKeyUsage"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = local.keys_except["relay"]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny_actions
        Resource = local.other_logs["relay"]
      },
    ]

    archiver = [
      {
        Sid      = "AppendAuditObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = [local.b_prefix]
      },
      {
        Sid      = "AuditBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [local.b_arn]
      },
      {
        Sid      = "UseAuditAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = local.keys_allowed["archiver"]
      },
      {
        Sid      = "WriteOwnArchiverLogs"
        Effect   = "Allow"
        Action   = local.logs_write_actions
        Resource = local.log_arns["archiver"]
      },
      {
        Sid      = "DenyAuditDeletion"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = [local.b_arn, local.b_objs]
      },
      {
        Sid      = "DenyQueueAccess"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.q_arn, local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionAccess"
        Effect   = "Deny"
        Action   = local.ddb_rw_actions
        Resource = [local.t_arn, local.idx_arn]
      },
      {
        Sid      = "DenyForeignKeyUsage"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = local.keys_except["archiver"]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.logs_deny_actions
        Resource = local.other_logs["archiver"]
      },
    ]

  }
}

locals {
  scheduler_statements = [
    {
      Sid      = "InvokeScheduledWorkers"
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.outbox_relay.arn, aws_lambda_function.audit_archiver.arn]
    },
    {
      Sid      = "DenyProjectorInvoke"
      Effect   = "Deny"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.projector.arn]
    },
    {
      Sid      = "DenyQueueAccess"
      Effect   = "Deny"
      Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
      Resource = [local.q_arn, local.dlq_arn]
    },
    {
      Sid      = "DenyProjectionAccess"
      Effect   = "Deny"
      Action   = local.ddb_rw_actions
      Resource = [local.t_arn, local.idx_arn]
    },
    {
      Sid      = "DenyAuditBucketAccess"
      Effect   = "Deny"
      Action   = local.s3_deny_actions
      Resource = [local.b_arn, local.b_objs]
    },
    {
      Sid      = "DenyAllKeyUsage"
      Effect   = "Deny"
      Action   = local.kms_deny_actions
      Resource = local.keys_except["scheduler"]
    },
    {
      Sid      = "DenyAllLogWrites"
      Effect   = "Deny"
      Action   = local.logs_deny_actions
      Resource = flatten(values(local.log_arns))
    },
  ]
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name = "${local.prefix}-${replace(each.key, "_", "-")}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = each.value }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-${replace(each.key, "_", "-")}" })
}

resource "aws_iam_role_policy" "this" {
  for_each = toset([for r in keys(local.roles) : r if r != "scheduler"])

  name = "${local.prefix}-${replace(each.key, "_", "-")}-canonical"
  role = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policy_statements[each.key]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.prefix}-scheduler-canonical"
  role = aws_iam_role.this["scheduler"].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.scheduler_statements
  })
}
