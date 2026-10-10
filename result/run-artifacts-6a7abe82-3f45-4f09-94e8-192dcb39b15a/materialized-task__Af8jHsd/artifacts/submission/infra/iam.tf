locals {
  role_keys = ["ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler"]

  role_names = {
    ecs_execution = "${local.prefix}-ecs-execution"
    ecs_task      = "${local.prefix}-ecs-task"
    projector     = "${local.prefix}-projector"
    relay         = "${local.prefix}-relay"
    archiver      = "${local.prefix}-archiver"
    scheduler     = "${local.prefix}-scheduler"
  }

  role_trust = {
    ecs_execution = "ecs-tasks.amazonaws.com"
    ecs_task      = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com"
    relay         = "lambda.amazonaws.com"
    archiver      = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }

  lambda_names = {
    projector = "${local.prefix}-projector"
    relay     = "${local.prefix}-outbox-relay"
    archiver  = "${local.prefix}-audit-archiver"
  }
  lambda_arns = { for k, n in local.lambda_names : k => "arn:aws:lambda:${local.region}:${local.account}:function:${n}" }

  role_arns = { for k in local.role_keys : k => "arn:aws:iam::${local.account}:role/${local.role_names[k]}" }

  # Resource ARNs referenced by policies
  queue_arn  = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  table_arn  = aws_dynamodb_table.projections.arn
  index_arn  = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bucket_arn = aws_s3_bucket.audit.arn
  kms_arn    = { for k in local.kms_usages : k => aws_kms_key.this[k].arn }
  all_kms    = [for k in local.kms_usages : aws_kms_key.this[k].arn]

  log_group_names = {
    api       = "/clearledger/${local.prefix}/api"
    projector = "/clearledger/${local.prefix}/projector"
    relay     = "/clearledger/${local.prefix}/outbox-relay"
    archiver  = "/clearledger/${local.prefix}/audit-archiver"
  }
  log_arns = {
    for k, n in local.log_group_names : k => [
      "arn:aws:logs:${local.region}:${local.account}:log-group:${n}",
      "arn:aws:logs:${local.region}:${local.account}:log-group:${n}:*",
    ]
  }

  log_actions  = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  log_write    = ["logs:CreateLogStream", "logs:PutLogEvents"]
  kms_use      = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_crypto   = ["kms:Decrypt", "kms:GenerateDataKey"]
  sqs_all      = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_all      = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_all       = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  s3_resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

  deny_key_destruction = {
    Sid      = "DenyKmsKeyDestruction"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_kms
  }

  role_policies = {
    ecs_execution = [
      {
        Sid      = "ApiLogStreams"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_arns.api
      },
      local.deny_key_destruction,
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all, Resource = [local.queue_arn, local.dlq_arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, local.index_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = local.kms_crypto, Resource = local.all_kms },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_write, Resource = concat(local.log_arns.projector, local.log_arns.relay, local.log_arns.archiver) },
    ]

    ecs_task = [
      {
        Sid      = "PublishMainQueue"
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
        Sid      = "KmsUsage"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "ApiLogStreams"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_arns.api
      },
      local.deny_key_destruction,
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.queue_arn] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all, Resource = [local.dlq_arn] },
      { Sid = "DenyDynamoDbMutation", Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.table_arn, local.index_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = local.kms_crypto, Resource = [local.kms_arn.database, local.kms_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_write, Resource = concat(local.log_arns.projector, local.log_arns.relay, local.log_arns.archiver) },
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
        Sid      = "WriteProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = [local.table_arn, local.index_arn]
      },
      {
        Sid      = "KmsUsage"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn.messaging, local.kms_arn.projection]
      },
      {
        Sid      = "ProjectorLogStreams"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_arns.projector
      },
      local.deny_key_destruction,
      { Sid = "DenyPublishMainQueue", Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [local.queue_arn] },
      { Sid = "DenyConsumeDlq", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.dlq_arn] },
      { Sid = "DenyDynamoDbDelete", Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.table_arn, local.index_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = local.kms_crypto, Resource = [local.kms_arn.database, local.kms_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_write, Resource = concat(local.log_arns.api, local.log_arns.relay, local.log_arns.archiver) },
    ]

    relay = [
      {
        Sid      = "PublishMainQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.queue_arn]
      },
      {
        Sid      = "KmsUsage"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn.messaging, local.kms_arn.database]
      },
      {
        Sid      = "RelayLogStreams"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_arns.relay
      },
      local.deny_key_destruction,
      { Sid = "DenyConsumeMainQueue", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.queue_arn] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all, Resource = [local.dlq_arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, local.index_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = local.kms_crypto, Resource = [local.kms_arn.projection, local.kms_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_write, Resource = concat(local.log_arns.api, local.log_arns.projector, local.log_arns.archiver) },
    ]

    archiver = [
      {
        Sid      = "AuditObjects"
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
        Sid      = "KmsUsage"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.kms_arn.audit, local.kms_arn.database]
      },
      {
        Sid      = "ArchiverLogStreams"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_arns.archiver
      },
      local.deny_key_destruction,
      { Sid = "DenyS3Delete", Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.s3_resources },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all, Resource = [local.queue_arn, local.dlq_arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, local.index_arn] },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = local.kms_crypto, Resource = [local.kms_arn.messaging, local.kms_arn.projection] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_write, Resource = concat(local.log_arns.api, local.log_arns.projector, local.log_arns.relay) },
    ]

    scheduler = [
      {
        Sid      = "InvokeScheduledWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.lambda_arns.relay, local.lambda_arns.archiver]
      },
      local.deny_key_destruction,
      { Sid = "DenyInvokeProjector", Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.lambda_arns.projector] },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all, Resource = [local.queue_arn, local.dlq_arn] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, local.index_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_all, Resource = local.s3_resources },
      { Sid = "DenyKmsCrypto", Effect = "Deny", Action = local.kms_crypto, Resource = local.all_kms },
      { Sid = "DenyAllLogs", Effect = "Deny", Action = local.log_write, Resource = concat(local.log_arns.api, local.log_arns.projector, local.log_arns.relay, local.log_arns.archiver) },
    ]
  }
}

resource "aws_iam_role" "role" {
  for_each = toset(local.role_keys)
  name     = local.role_names[each.key]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = local.role_trust[each.key] }
      Action    = "sts:AssumeRole"
    }]
  })

  force_detach_policies = true

  tags = merge(local.tags, {
    Name            = local.role_names[each.key]
    ClearLedgerRole = each.key
  })
}

resource "aws_iam_role_policy" "role" {
  for_each = toset(local.role_keys)
  name     = "${local.role_names[each.key]}-policy"
  role     = aws_iam_role.role[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.role_policies[each.key]
  })
}
