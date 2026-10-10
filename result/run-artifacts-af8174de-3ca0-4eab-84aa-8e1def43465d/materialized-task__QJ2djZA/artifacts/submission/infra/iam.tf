locals {
  queue_arn  = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  table_arn  = aws_dynamodb_table.projections.arn
  gsi_arn    = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn

  kms_arns = { for k, v in aws_kms_key.key : k => v.arn }
  all_kms  = values(local.kms_arns)

  log_arns = {
    for k, name in local.log_group_names : k => [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:${name}",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:${name}:*",
    ]
  }

  log_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  log_deny_actions  = ["logs:CreateLogStream", "logs:PutLogEvents"]
  sqs_all_actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_all_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_all_actions    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  s3_resources      = [local.bucket_arn, "${local.bucket_arn}/*"]

  kms_guardrail = {
    Sid      = "DenyKmsKeyDisableOrDeletion"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_kms
  }

  other_logs = {
    for k in keys(local.log_group_names) : k => flatten([for o, arns in local.log_arns : arns if o != k])
  }

  trust = {
    ecs       = "ecs-tasks.amazonaws.com"
    lambda    = "lambda.amazonaws.com"
    scheduler = "scheduler.amazonaws.com"
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.trust
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = [each.value]
    }
  }
}

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.p}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.trust["ecs"].json
  tags               = merge(local.tags, { ClearLedgerRole = "ecs_execution" })
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.p}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.trust["ecs"].json
  tags               = merge(local.tags, { ClearLedgerRole = "ecs_task" })
}

resource "aws_iam_role" "projector" {
  name               = "${local.p}-projector"
  assume_role_policy = data.aws_iam_policy_document.trust["lambda"].json
  tags               = merge(local.tags, { ClearLedgerRole = "projector" })
}

resource "aws_iam_role" "relay" {
  name               = "${local.p}-relay"
  assume_role_policy = data.aws_iam_policy_document.trust["lambda"].json
  tags               = merge(local.tags, { ClearLedgerRole = "relay" })
}

resource "aws_iam_role" "archiver" {
  name               = "${local.p}-archiver"
  assume_role_policy = data.aws_iam_policy_document.trust["lambda"].json
  tags               = merge(local.tags, { ClearLedgerRole = "archiver" })
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.p}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.trust["scheduler"].json
  tags               = merge(local.tags, { ClearLedgerRole = "scheduler" })
}

# ---------------------------------------------------------------------------
# Inline least-privilege policies
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy" "ecs_execution" {
  name = "${local.p}-ecs-execution-policy"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ApiLogWrite", Effect = "Allow", Action = local.log_write_actions, Resource = local.log_arns.api },
      local.kms_guardrail,
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = [local.queue_arn, local.dlq_arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = local.all_kms },
      { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs.api },
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.p}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "PublishMainQueue", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = local.queue_arn },
      { Sid = "ReadProjections", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "KmsCrypto", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [local.kms_arns.messaging, local.kms_arns.projection] },
      { Sid = "ApiLogWrite", Effect = "Allow", Action = local.log_write_actions, Resource = local.log_arns.api },
      local.kms_guardrail,
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = local.queue_arn },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.dlq_arn },
      { Sid = "DenyDynamoDbMutation", Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [local.kms_arns.database, local.kms_arns.audit] },
      { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs.api },
    ]
  })
}

resource "aws_iam_role_policy" "projector" {
  name = "${local.p}-projector-policy"
  role = aws_iam_role.projector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ConsumeMainQueue", Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = local.queue_arn },
      { Sid = "ForwardToDlq", Effect = "Allow", Action = ["sqs:SendMessage"], Resource = local.dlq_arn },
      { Sid = "UpsertProjections", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "KmsCrypto", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [local.kms_arns.messaging, local.kms_arns.projection] },
      { Sid = "ProjectorLogWrite", Effect = "Allow", Action = local.log_write_actions, Resource = local.log_arns.projector },
      local.kms_guardrail,
      { Sid = "DenyPublishMainQueue", Effect = "Deny", Action = ["sqs:SendMessage"], Resource = local.queue_arn },
      { Sid = "DenyConsumeDlq", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = local.dlq_arn },
      { Sid = "DenyDynamoDbDelete", Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [local.kms_arns.database, local.kms_arns.audit] },
      { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs.projector },
    ]
  })
}

resource "aws_iam_role_policy" "relay" {
  name = "${local.p}-relay-policy"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "PublishMainQueue", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = local.queue_arn },
      { Sid = "KmsCrypto", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [local.kms_arns.messaging, local.kms_arns.database] },
      { Sid = "RelayLogWrite", Effect = "Allow", Action = local.log_write_actions, Resource = local.log_arns.relay },
      local.kms_guardrail,
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = local.queue_arn },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.dlq_arn },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [local.kms_arns.projection, local.kms_arns.audit] },
      { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs.relay },
    ]
  })
}

resource "aws_iam_role_policy" "archiver" {
  name = "${local.p}-archiver-policy"
  role = aws_iam_role.archiver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "AuditObjectAppend", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = "${local.bucket_arn}/ledger-audit/*" },
      { Sid = "AuditBucketMetadata", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = local.bucket_arn },
      { Sid = "KmsCrypto", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [local.kms_arns.audit, local.kms_arns.database] },
      { Sid = "ArchiverLogWrite", Effect = "Allow", Action = local.log_write_actions, Resource = local.log_arns.archiver },
      local.kms_guardrail,
      { Sid = "DenyS3Delete", Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.s3_resources },
      { Sid = "DenyPutOutsideAuditPrefix", Effect = "Deny", Action = ["s3:PutObject"], NotResource = "${local.bucket_arn}/ledger-audit/*" },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = [local.queue_arn, local.dlq_arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [local.kms_arns.messaging, local.kms_arns.projection] },
      { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs.archiver },
    ]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.p}-scheduler-policy"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "InvokeScheduledWorkers", Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.relay.arn, aws_lambda_function.archiver.arn] },
      local.kms_guardrail,
      { Sid = "DenyInvokeProjector", Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.projector.arn] },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = [local.queue_arn, local.dlq_arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = [local.table_arn, local.gsi_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = local.all_kms },
      { Sid = "DenyAllLogGroups", Effect = "Deny", Action = local.log_deny_actions, Resource = flatten(values(local.log_arns)) },
    ]
  })
}

# ---------------------------------------------------------------------------
# Exclusivity: strip any out-of-band inline or attached managed policies.
# ---------------------------------------------------------------------------

locals {
  canonical_inline = {
    ecs_execution = { role = aws_iam_role.ecs_execution.name, policy = aws_iam_role_policy.ecs_execution.name }
    ecs_task      = { role = aws_iam_role.ecs_task.name, policy = aws_iam_role_policy.ecs_task.name }
    projector     = { role = aws_iam_role.projector.name, policy = aws_iam_role_policy.projector.name }
    relay         = { role = aws_iam_role.relay.name, policy = aws_iam_role_policy.relay.name }
    archiver      = { role = aws_iam_role.archiver.name, policy = aws_iam_role_policy.archiver.name }
    scheduler     = { role = aws_iam_role.scheduler.name, policy = aws_iam_role_policy.scheduler.name }
  }
}

resource "aws_iam_role_policies_exclusive" "role" {
  for_each     = local.canonical_inline
  role_name    = each.value.role
  policy_names = [each.value.policy]
}

resource "aws_iam_role_policy_attachments_exclusive" "role" {
  for_each    = local.canonical_inline
  role_name   = each.value.role
  policy_arns = []
}
