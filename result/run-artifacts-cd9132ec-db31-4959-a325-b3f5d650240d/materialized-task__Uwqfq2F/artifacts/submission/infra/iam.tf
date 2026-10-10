locals {
  names = {
    queue        = "${local.prefix}-settlement-events"
    dlq          = "${local.prefix}-settlement-events-dlq"
    table        = "${local.prefix}-projections"
    bucket       = "${local.prefix}-ledger-audit"
    projector_fn = "${local.prefix}-projector"
    relay_fn     = "${local.prefix}-outbox-relay"
    archiver_fn  = "${local.prefix}-audit-archiver"
  }

  # ARNs are derived from deterministic names so that IAM policies never need
  # wildcard resources and never form dependency cycles with their consumers.
  arn = {
    queue        = "arn:aws:sqs:${local.region}:${local.account_id}:${local.names.queue}"
    dlq          = "arn:aws:sqs:${local.region}:${local.account_id}:${local.names.dlq}"
    table        = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.names.table}"
    gsi          = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.names.table}/index/AccountIndex"
    bucket       = "arn:aws:s3:::${local.names.bucket}"
    bucket_obj   = "arn:aws:s3:::${local.names.bucket}/*"
    audit_prefix = "arn:aws:s3:::${local.names.bucket}/ledger-audit/*"
    projector_fn = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.names.projector_fn}"
    relay_fn     = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.names.relay_fn}"
    archiver_fn  = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.names.archiver_fn}"
  }

  log_arns = {
    for k, name in local.log_groups : k => [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:${name}",
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:${name}:*",
    ]
  }

  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }

  sqs_core   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_core   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_core    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  kms_use    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny   = ["kms:Decrypt", "kms:GenerateDataKey"]
  logs_write = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  logs_deny  = ["logs:CreateLogStream", "logs:PutLogEvents"]

  table_and_gsi = [local.arn.table, local.arn.gsi]
  bucket_all    = [local.arn.bucket, local.arn.bucket_obj]

  other_logs = {
    for k in keys(local.log_groups) : k => flatten([
      for o, arns in local.log_arns : arns if o != k
    ])
  }

  all_logs = flatten(values(local.log_arns))

  policies = {
    ecs_execution = [
      { Sid = "ApiLogsWrite", Effect = "Allow", Action = local.logs_write, Resource = local.log_arns.api },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_core, Resource = [local.arn.queue, local.arn.dlq] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_core, Resource = local.table_and_gsi },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_core, Resource = local.bucket_all },
      { Sid = "DenyKms", Effect = "Deny", Action = local.kms_deny, Resource = values(local.kms_arn) },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs.api },
    ]

    ecs_task = [
      { Sid = "PublishMainQueue", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [local.arn.queue] },
      { Sid = "ReadProjections", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.table_and_gsi },
      { Sid = "UseMessagingProjectionKeys", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.messaging, local.kms_arn.projection] },
      { Sid = "ApiLogsWrite", Effect = "Allow", Action = local.logs_write, Resource = local.log_arns.api },
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.arn.queue] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_core, Resource = [local.arn.dlq] },
      { Sid = "DenyProjectionMutation", Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_and_gsi },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_core, Resource = local.bucket_all },
      { Sid = "DenyDatabaseAuditKeys", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.database, local.kms_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs.api },
    ]

    projector = [
      { Sid = "ConsumeMainQueue", Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [local.arn.queue] },
      { Sid = "ForwardToDlq", Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [local.arn.dlq] },
      { Sid = "UpsertProjections", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.table_and_gsi },
      { Sid = "UseMessagingProjectionKeys", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.messaging, local.kms_arn.projection] },
      { Sid = "ProjectorLogsWrite", Effect = "Allow", Action = local.logs_write, Resource = local.log_arns.projector },
      { Sid = "DenyPublishMainQueue", Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [local.arn.queue] },
      { Sid = "DenyConsumeDlq", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.arn.dlq] },
      { Sid = "DenyProjectionDeletes", Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_and_gsi },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_core, Resource = local.bucket_all },
      { Sid = "DenyDatabaseAuditKeys", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.database, local.kms_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs.projector },
    ]

    relay = [
      { Sid = "PublishMainQueue", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [local.arn.queue] },
      { Sid = "UseMessagingDatabaseKeys", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.messaging, local.kms_arn.database] },
      { Sid = "RelayLogsWrite", Effect = "Allow", Action = local.logs_write, Resource = local.log_arns.relay },
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.arn.queue] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_core, Resource = [local.arn.dlq] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_core, Resource = local.table_and_gsi },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_core, Resource = local.bucket_all },
      { Sid = "DenyProjectionAuditKeys", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.projection, local.kms_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs.relay },
    ]

    archiver = [
      { Sid = "AuditObjectsAppend", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = [local.arn.audit_prefix] },
      { Sid = "AuditBucketMetadata", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [local.arn.bucket] },
      { Sid = "UseAuditDatabaseKeys", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.audit, local.kms_arn.database] },
      { Sid = "ArchiverLogsWrite", Effect = "Allow", Action = local.logs_write, Resource = local.log_arns.archiver },
      { Sid = "DenyAuditDeletes", Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_all },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_core, Resource = [local.arn.queue, local.arn.dlq] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_core, Resource = local.table_and_gsi },
      { Sid = "DenyMessagingProjectionKeys", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.messaging, local.kms_arn.projection] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs.archiver },
    ]

    scheduler = [
      { Sid = "InvokeScheduledWorkers", Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [local.arn.relay_fn, local.arn.archiver_fn] },
      { Sid = "DenyInvokeProjector", Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.arn.projector_fn, "${local.arn.projector_fn}:*"] },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_core, Resource = [local.arn.queue, local.arn.dlq] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_core, Resource = local.table_and_gsi },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_core, Resource = local.bucket_all },
      { Sid = "DenyKms", Effect = "Deny", Action = local.kms_deny, Resource = values(local.kms_arn) },
      { Sid = "DenyLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.all_logs },
    ]
  }

  role_defs = {
    ecs_execution = { name = "${local.prefix}-ecs-execution", principal = "ecs-tasks.amazonaws.com" }
    ecs_task      = { name = "${local.prefix}-ecs-task", principal = "ecs-tasks.amazonaws.com" }
    projector     = { name = "${local.prefix}-projector", principal = "lambda.amazonaws.com" }
    relay         = { name = "${local.prefix}-outbox-relay", principal = "lambda.amazonaws.com" }
    archiver      = { name = "${local.prefix}-audit-archiver", principal = "lambda.amazonaws.com" }
    scheduler     = { name = "${local.prefix}-scheduler", principal = "scheduler.amazonaws.com" }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_defs

  name                  = each.value.name
  description           = "ClearLedger ${each.key} role (${local.prefix})"
  force_detach_policies = true

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TrustedService"
      Effect    = "Allow"
      Principal = { Service = each.value.principal }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = each.value.name }
}

resource "aws_iam_role_policy" "this" {
  for_each = local.role_defs

  name = "${each.value.name}-least-privilege"
  role = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policies[each.key]
  })
}

# Exclusive ownership: any inline policy or managed-policy attachment added to
# these roles out-of-band is removed on the next apply.
resource "aws_iam_role_policies_exclusive" "this" {
  for_each = local.role_defs

  role_name    = aws_iam_role.this[each.key].name
  policy_names = [aws_iam_role_policy.this[each.key].name]
}

resource "aws_iam_role_policy_attachments_exclusive" "this" {
  for_each = local.role_defs

  role_name   = aws_iam_role.this[each.key].name
  policy_arns = []
}
