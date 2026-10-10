locals {
  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }
  all_kms = [for k in local.kms_usages : aws_kms_key.this[k].arn]

  # Per-workload log group ARN patterns ("...:log-group:/clearledger/<prefix>/<workload>*")
  lg = { for k, v in aws_cloudwatch_log_group.this : k => "${v.arn}*" }

  queue_arn  = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  table_arn  = aws_dynamodb_table.projections.arn
  gsi_arn    = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn

  log_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  log_deny_actions  = ["logs:CreateLogStream", "logs:PutLogEvents"]
  kms_use_actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny_actions  = ["kms:Decrypt", "kms:GenerateDataKey"]
  sqs_core_actions  = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_core_actions  = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_core_actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]

  # Guardrail shared by every role.
  deny_key_destruction = {
    Sid      = "DenyKmsKeyDestruction"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_kms
  }

  deny_s3_all = {
    Sid      = "DenyAuditBucketAccess"
    Effect   = "Deny"
    Action   = local.s3_core_actions
    Resource = [local.bucket_arn, "${local.bucket_arn}/*"]
  }

  deny_ddb_all = {
    Sid      = "DenyProjectionTableAccess"
    Effect   = "Deny"
    Action   = local.ddb_core_actions
    Resource = [local.table_arn, local.gsi_arn]
  }

  deny_sqs_all = {
    Sid      = "DenyQueueAccess"
    Effect   = "Deny"
    Action   = local.sqs_core_actions
    Resource = [local.queue_arn, local.dlq_arn]
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

# ---------------------------------------------------------------------------
# 1. ECS execution role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ecs_execution" {
  name               = local.role_names.ecs_execution
  assume_role_policy = data.aws_iam_policy_document.trust_ecs.json
  tags               = { ClearLedgerRole = "ecs_execution" }
}

resource "aws_iam_role_policy" "ecs_execution" {
  name = "${local.prefix}-ecs-execution-policy"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ApiLogStreams"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = [local.lg.api]
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyAllWorkloadKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = local.all_kms
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = [local.lg.projector, local.lg.relay, local.lg.archiver]
      },
      local.deny_key_destruction,
    ]
  })
}

# ---------------------------------------------------------------------------
# 2. ECS task role (API)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task" {
  name               = local.role_names.ecs_task
  assume_role_policy = data.aws_iam_policy_document.trust_ecs.json
  tags               = { ClearLedgerRole = "ecs_task" }
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "ApiLogStreams"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = [local.lg.api]
      },
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyDeadLetterQueue"
        Effect   = "Deny"
        Action   = local.sqs_core_actions
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
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn.database, local.kms_arn.audit]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = [local.lg.projector, local.lg.relay, local.lg.archiver]
      },
      local.deny_key_destruction,
    ]
  })
}

# ---------------------------------------------------------------------------
# 3. Projector Lambda role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "projector" {
  name               = local.role_names.projector
  assume_role_policy = data.aws_iam_policy_document.trust_lambda.json
  tags               = { ClearLedgerRole = "projector" }
}

resource "aws_iam_role_policy" "projector" {
  name = "${local.prefix}-projector-policy"
  role = aws_iam_role.projector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeDomainEvents"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = [local.queue_arn]
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
        Resource = [local.table_arn, local.gsi_arn]
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "ProjectorLogStreams"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = [local.lg.projector]
      },
      {
        Sid      = "DenyPublishMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:SendMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyConsumeDeadLetterQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "DenyProjectionDeletion"
        Effect   = "Deny"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"]
        Resource = [local.table_arn, local.gsi_arn]
      },
      local.deny_s3_all,
      {
        Sid      = "DenyDatabaseAndAuditKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn.database, local.kms_arn.audit]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = [local.lg.api, local.lg.relay, local.lg.archiver]
      },
      local.deny_key_destruction,
    ]
  })
}

# ---------------------------------------------------------------------------
# 4. Outbox relay Lambda role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "relay" {
  name               = local.role_names.relay
  assume_role_policy = data.aws_iam_policy_document.trust_lambda.json
  tags               = { ClearLedgerRole = "relay" }
}

resource "aws_iam_role_policy" "relay" {
  name = "${local.prefix}-outbox-relay-policy"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishDomainEvents"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn.messaging, local.kms_arn.database]
      },
      {
        Sid      = "RelayLogStreams"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = [local.lg.relay]
      },
      {
        Sid      = "DenyConsumeMainQueue"
        Effect   = "Deny"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "DenyDeadLetterQueue"
        Effect   = "Deny"
        Action   = local.sqs_core_actions
        Resource = [local.dlq_arn]
      },
      local.deny_ddb_all,
      local.deny_s3_all,
      {
        Sid      = "DenyProjectionAndAuditKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn.projection, local.kms_arn.audit]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = [local.lg.api, local.lg.projector, local.lg.archiver]
      },
      local.deny_key_destruction,
    ]
  })
}

# ---------------------------------------------------------------------------
# 5. Audit archiver Lambda role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "archiver" {
  name               = local.role_names.archiver
  assume_role_policy = data.aws_iam_policy_document.trust_lambda.json
  tags               = { ClearLedgerRole = "archiver" }
}

resource "aws_iam_role_policy" "archiver" {
  name = "${local.prefix}-audit-archiver-policy"
  role = aws_iam_role.archiver.id
  policy = jsonencode({
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
        Action   = local.kms_use_actions
        Resource = [local.kms_arn.audit, local.kms_arn.database]
      },
      {
        Sid      = "ArchiverLogStreams"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = [local.lg.archiver]
      },
      {
        Sid      = "DenyAuditDeletion"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = [local.bucket_arn, "${local.bucket_arn}/*"]
      },
      local.deny_sqs_all,
      local.deny_ddb_all,
      {
        Sid      = "DenyMessagingAndProjectionKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "DenyForeignLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = [local.lg.api, local.lg.projector, local.lg.relay]
      },
      local.deny_key_destruction,
    ]
  })
}

# ---------------------------------------------------------------------------
# 6. EventBridge Scheduler role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name               = local.role_names.scheduler
  assume_role_policy = data.aws_iam_policy_document.trust_scheduler.json
  tags               = { ClearLedgerRole = "scheduler" }
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.prefix}-scheduler-policy"
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
        Sid      = "DenyAllWorkloadKeys"
        Effect   = "Deny"
        Action   = local.kms_deny_actions
        Resource = local.all_kms
      },
      {
        Sid      = "DenyAllLogGroups"
        Effect   = "Deny"
        Action   = local.log_deny_actions
        Resource = [local.lg.api, local.lg.projector, local.lg.relay, local.lg.archiver]
      },
      local.deny_key_destruction,
    ]
  })
}

# ---------------------------------------------------------------------------
# Exclusive ownership: any out-of-band inline policy or managed policy
# attachment on the six workload roles is removed on every apply.
# ---------------------------------------------------------------------------
locals {
  workload_roles = {
    ecs_execution = { role = aws_iam_role.ecs_execution.name, policy = aws_iam_role_policy.ecs_execution.name }
    ecs_task      = { role = aws_iam_role.ecs_task.name, policy = aws_iam_role_policy.ecs_task.name }
    projector     = { role = aws_iam_role.projector.name, policy = aws_iam_role_policy.projector.name }
    relay         = { role = aws_iam_role.relay.name, policy = aws_iam_role_policy.relay.name }
    archiver      = { role = aws_iam_role.archiver.name, policy = aws_iam_role_policy.archiver.name }
    scheduler     = { role = aws_iam_role.scheduler.name, policy = aws_iam_role_policy.scheduler.name }
  }
}

resource "aws_iam_role_policies_exclusive" "this" {
  for_each     = local.workload_roles
  role_name    = each.value.role
  policy_names = [each.value.policy]
}

resource "aws_iam_role_policy_attachments_exclusive" "this" {
  for_each    = local.workload_roles
  role_name   = each.value.role
  policy_arns = []
}
