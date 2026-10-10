locals {
  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }

  log_group_arns = {
    for k, name in local.log_groups : k => [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:${name}",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:${name}:*",
    ]
  }

  all_kms_arns = [for k in local.kms_usages : local.kms_arn[k]]

  queue_arns  = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
  table_arns  = [aws_dynamodb_table.projections.arn, "${aws_dynamodb_table.projections.arn}/index/AccountIndex"]
  bucket_arns = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

  sqs_all_actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_all_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_all_actions    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  log_write_actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  log_deny_actions  = ["logs:CreateLogStream", "logs:PutLogEvents"]
  kms_use_actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny_actions  = ["kms:Decrypt", "kms:GenerateDataKey"]
  kms_guard_statement = {
    Sid      = "DenyKmsKeyDestruction"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_kms_arns
  }

  other_logs = {
    for k in keys(local.log_groups) : k => flatten([
      for o, arns in local.log_group_arns : arns if o != k
    ])
  }
  all_log_arns = flatten(values(local.log_group_arns))

  role_trust = {
    ecs_execution = "ecs-tasks.amazonaws.com"
    ecs_task      = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com"
    relay         = "lambda.amazonaws.com"
    archiver      = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }

  role_names = {
    ecs_execution = "${local.p}-ecs-execution"
    ecs_task      = "${local.p}-ecs-task"
    projector     = "${local.p}-projector"
    relay         = "${local.p}-outbox-relay"
    archiver      = "${local.p}-audit-archiver"
    scheduler     = "${local.p}-scheduler"
  }

  role_policies = {
    ecs_execution = [
      {
        Sid      = "ApiLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_group_arns["api"]
      },
      local.kms_guard_statement,
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.queue_arns },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = local.table_arns },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.bucket_arns },
      { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny_actions, Resource = local.all_kms_arns },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs["api"] },
    ]

    ecs_task = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = local.table_arns
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "ApiLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_group_arns["api"]
      },
      local.kms_guard_statement,
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Sid = "DenyDynamoDbMutation", Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_arns },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.bucket_arns },
      { Sid = "DenyForeignKmsUse", Effect = "Deny", Action = local.kms_deny_actions, Resource = [local.kms_arn["database"], local.kms_arn["audit"]] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs["api"] },
    ]

    projector = [
      {
        Sid      = "ConsumeMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "ForwardToDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.dlq.arn]
      },
      {
        Sid      = "UpsertProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = local.table_arns
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]]
      },
      {
        Sid      = "ProjectorLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_group_arns["projector"]
      },
      local.kms_guard_statement,
      { Sid = "DenyPublishMainQueue", Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Sid = "DenyConsumeDlq", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Sid = "DenyDynamoDbDelete", Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_arns },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.bucket_arns },
      { Sid = "DenyForeignKmsUse", Effect = "Deny", Action = local.kms_deny_actions, Resource = [local.kms_arn["database"], local.kms_arn["audit"]] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs["projector"] },
    ]

    relay = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [aws_sqs_queue.main.arn]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["messaging"], local.kms_arn["database"]]
      },
      {
        Sid      = "RelayLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_group_arns["relay"]
      },
      local.kms_guard_statement,
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = local.table_arns },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.bucket_arns },
      { Sid = "DenyForeignKmsUse", Effect = "Deny", Action = local.kms_deny_actions, Resource = [local.kms_arn["projection"], local.kms_arn["audit"]] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs["relay"] },
    ]

    archiver = [
      {
        Sid      = "AppendAuditObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"]
      },
      {
        Sid      = "AuditBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.audit.arn]
      },
      {
        Sid      = "UseAuditAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use_actions
        Resource = [local.kms_arn["audit"], local.kms_arn["database"]]
      },
      {
        Sid      = "ArchiverLogWrite"
        Effect   = "Allow"
        Action   = local.log_write_actions
        Resource = local.log_group_arns["archiver"]
      },
      local.kms_guard_statement,
      { Sid = "DenyAuditDeletion", Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_arns },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.queue_arns },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = local.table_arns },
      { Sid = "DenyForeignKmsUse", Effect = "Deny", Action = local.kms_deny_actions, Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_deny_actions, Resource = local.other_logs["archiver"] },
    ]

  }
}

locals {
  scheduler_policy_statements = [
    {
      Sid      = "InvokeScheduledWorkers"
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.relay.arn, aws_lambda_function.archiver.arn]
    },
    local.kms_guard_statement,
    { Sid = "DenyInvokeProjector", Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.projector.arn] },
    { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.queue_arns },
    { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all_actions, Resource = local.table_arns },
    { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all_actions, Resource = local.bucket_arns },
    { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny_actions, Resource = local.all_kms_arns },
    { Sid = "DenyLogs", Effect = "Deny", Action = local.log_deny_actions, Resource = local.all_log_arns },
  ]
}

resource "aws_iam_role" "this" {
  for_each = local.role_trust
  name     = local.role_names[each.key]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = each.value }
    }]
  })

  force_detach_policies = true

  tags = {
    Name            = local.role_names[each.key]
    ClearLedgerRole = each.key
  }
}

resource "aws_iam_role_policy" "this" {
  for_each = { for k, v in local.role_trust : k => v if k != "scheduler" }
  name     = "${local.role_names[each.key]}-policy"
  role     = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.role_policies[each.key]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.role_names["scheduler"]}-policy"
  role = aws_iam_role.this["scheduler"].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.scheduler_policy_statements
  })
}
