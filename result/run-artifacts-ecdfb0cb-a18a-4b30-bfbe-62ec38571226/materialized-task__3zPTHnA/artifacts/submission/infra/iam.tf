locals {
  account_id = data.aws_caller_identity.current.account_id

  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }

  q_main = aws_sqs_queue.main.arn
  q_dlq  = aws_sqs_queue.dlq.arn
  q_both = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]

  ddb_table = aws_dynamodb_table.projections.arn
  ddb_both  = [aws_dynamodb_table.projections.arn, "${aws_dynamodb_table.projections.arn}/index/AccountIndex"]

  bucket_arn  = aws_s3_bucket.audit.arn
  bucket_both = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

  # Per-workload log group resources: the group itself plus its streams.
  lg = {
    for k, v in aws_cloudwatch_log_group.this : k => [v.arn, "${v.arn}:*"]
  }

  logs_write      = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  kms_use         = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny        = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  logs_deny       = ["logs:CreateLogStream", "logs:PutLogEvents"]
  sqs_all_deny    = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_read_deny   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_basic_deny   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  worker_log_keys = ["api", "projector", "relay", "archiver"]

  role_names = {
    ecs_execution = "${local.prefix}-ecs-execution"
    ecs_task      = "${local.prefix}-ecs-task"
    projector     = "${local.prefix}-projector"
    relay         = "${local.prefix}-outbox-relay"
    archiver      = "${local.prefix}-audit-archiver"
    scheduler     = "${local.prefix}-scheduler"
  }

  role_principals = {
    ecs_execution = "ecs-tasks.amazonaws.com"
    ecs_task      = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com"
    relay         = "lambda.amazonaws.com"
    archiver      = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }

  # Other-workload log groups for the explicit deny guardrails.
  other_logs = {
    for k in local.worker_log_keys : k => flatten([for o in local.worker_log_keys : local.lg[o] if o != k])
  }
  all_logs = flatten([for k in local.worker_log_keys : local.lg[k]])
  all_kms  = [for k in ["database", "messaging", "projection", "audit"] : local.kms_arn[k]]

  policies = {
    # ------------------------------------------------------------ ECS execution
    ecs_execution = [
      { Sid = "AllowOwnLogs", Effect = "Allow", Action = local.logs_write, Resource = local.lg.api },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_deny, Resource = local.q_both },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_read_deny, Resource = local.ddb_both },
      { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_basic_deny, Resource = local.bucket_both },
      { Sid = "DenyAllKms", Effect = "Deny", Action = local.kms_deny, Resource = local.all_kms },
      { Sid = "DenyOtherLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs["api"] },
    ]

    # ------------------------------------------------------------ ECS task (API)
    ecs_task = [
      { Sid = "AllowPublishMain", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [local.q_main] },
      { Sid = "AllowReadProjection", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.ddb_both },
      { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]] },
      { Sid = "AllowOwnLogs", Effect = "Allow", Action = local.logs_write, Resource = local.lg.api },
      { Sid = "DenyConsumeMain", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.q_main] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_deny, Resource = [local.q_dlq] },
      { Sid = "DenyProjectionMutation", Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.ddb_both },
      { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_basic_deny, Resource = local.bucket_both },
      { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn["database"], local.kms_arn["audit"]] },
      { Sid = "DenyOtherLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs["api"] },
    ]

    # ------------------------------------------------------------ Projector
    projector = [
      { Sid = "AllowConsumeMain", Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [local.q_main] },
      { Sid = "AllowDeadLetter", Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [local.q_dlq] },
      { Sid = "AllowProjectionUpsert", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.ddb_both },
      { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]] },
      { Sid = "AllowOwnLogs", Effect = "Allow", Action = local.logs_write, Resource = local.lg.projector },
      { Sid = "DenyPublishMain", Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [local.q_main] },
      { Sid = "DenyConsumeDlq", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.q_dlq] },
      { Sid = "DenyProjectionDelete", Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.ddb_both },
      { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_basic_deny, Resource = local.bucket_both },
      { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn["database"], local.kms_arn["audit"]] },
      { Sid = "DenyOtherLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs["projector"] },
    ]

    # ------------------------------------------------------------ Outbox relay
    relay = [
      { Sid = "AllowPublishMain", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [local.q_main] },
      { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn["messaging"], local.kms_arn["database"]] },
      { Sid = "AllowOwnLogs", Effect = "Allow", Action = local.logs_write, Resource = local.lg.relay },
      { Sid = "DenyConsumeMain", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.q_main] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_deny, Resource = [local.q_dlq] },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_read_deny, Resource = local.ddb_both },
      { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_basic_deny, Resource = local.bucket_both },
      { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn["projection"], local.kms_arn["audit"]] },
      { Sid = "DenyOtherLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs["relay"] },
    ]

    # ------------------------------------------------------------ Audit archiver
    archiver = [
      { Sid = "AllowAuditObjects", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${local.bucket_arn}/ledger-audit/*"] },
      { Sid = "AllowAuditBucket", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [local.bucket_arn] },
      { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn["audit"], local.kms_arn["database"]] },
      { Sid = "AllowOwnLogs", Effect = "Allow", Action = local.logs_write, Resource = local.lg.archiver },
      { Sid = "DenyAuditDelete", Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_both },
      { Sid = "DenyBucketLevelPut", Effect = "Deny", Action = ["s3:PutObject"], Resource = [local.bucket_arn] },
      { Sid = "DenyObjectLevelList", Effect = "Deny", Action = ["s3:ListBucket"], Resource = ["${local.bucket_arn}/*"] },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_deny, Resource = local.q_both },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_read_deny, Resource = local.ddb_both },
      { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn["messaging"], local.kms_arn["projection"]] },
      { Sid = "DenyOtherLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.other_logs["archiver"] },
    ]

    # ------------------------------------------------------------ Scheduler
    scheduler = [
      { Sid = "AllowInvokeWorkers", Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.relay.arn, aws_lambda_function.archiver.arn] },
      { Sid = "DenyInvokeProjector", Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.projector.arn] },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_deny, Resource = local.q_both },
      { Sid = "DenyDynamoDb", Effect = "Deny", Action = local.ddb_read_deny, Resource = local.ddb_both },
      { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_basic_deny, Resource = local.bucket_both },
      { Sid = "DenyAllKms", Effect = "Deny", Action = local.kms_deny, Resource = local.all_kms },
      { Sid = "DenyAllLogs", Effect = "Deny", Action = local.logs_deny, Resource = local.all_logs },
    ]
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_names

  name = each.value
  tags = merge(local.tags, { Name = each.value })

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = local.role_principals[each.key] }
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  for_each = local.role_names

  name = "${each.value}-policy"
  role = aws_iam_role.this[each.key].name

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policies[each.key]
  })
}
