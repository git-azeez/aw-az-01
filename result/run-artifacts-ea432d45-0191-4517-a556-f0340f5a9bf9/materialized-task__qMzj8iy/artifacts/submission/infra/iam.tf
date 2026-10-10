locals {
  kms_arn = { for k, v in aws_kms_key.this : k => v.arn }

  log_arns = {
    api       = aws_cloudwatch_log_group.api.arn
    projector = aws_cloudwatch_log_group.projector.arn
    relay     = aws_cloudwatch_log_group.relay.arn
    archiver  = aws_cloudwatch_log_group.archiver.arn
  }
  # Log group + the log streams in it.
  log_res = { for k, v in local.log_arns : k => [v, "${v}:*"] }

  queue_arn  = aws_sqs_queue.main.arn
  dlq_arn    = aws_sqs_queue.dlq.arn
  all_queues = [local.queue_arn, local.dlq_arn]

  table_arn = aws_dynamodb_table.projections.arn
  table_res = [local.table_arn, "${local.table_arn}/index/AccountIndex"]

  bucket_arn = aws_s3_bucket.audit.arn
  bucket_res = [local.bucket_arn, "${local.bucket_arn}/*"]

  kms_use  = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny = ["kms:Decrypt", "kms:GenerateDataKey"]
  logs_rw  = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  logs_w   = ["logs:CreateLogStream", "logs:PutLogEvents"]
  s3_deny  = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  ddb_all5 = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  sqs_all3 = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]

  other_logs = {
    for w in keys(local.log_arns) :
    w => flatten([for o in keys(local.log_arns) : local.log_res[o] if o != w])
  }

  trust = {
    for svc in ["ecs-tasks", "lambda", "scheduler"] : svc => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Service = "${svc}.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }]
    })
  }

  policies = {
    ecs_execution = {
      trust = "ecs-tasks"
      statements = [
        { Sid = "AllowOwnLogGroup", Effect = "Allow", Action = local.logs_rw, Resource = local.log_res.api },
        { Sid = "DenyQueues", Effect = "Deny", Action = local.sqs_all3, Resource = local.all_queues },
        { Sid = "DenyProjectionTable", Effect = "Deny", Action = local.ddb_all5, Resource = local.table_res },
        { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_deny, Resource = local.bucket_res },
        { Sid = "DenyAllKmsKeys", Effect = "Deny", Action = local.kms_deny, Resource = values(local.kms_arn) },
        { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.logs_w, Resource = local.other_logs.api },
      ]
    }
    ecs_task = {
      trust = "ecs-tasks"
      statements = [
        { Sid = "AllowPublishMainQueue", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [local.queue_arn] },
        { Sid = "AllowReadProjection", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.table_res },
        { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.messaging, local.kms_arn.projection] },
        { Sid = "AllowOwnLogGroup", Effect = "Allow", Action = local.logs_rw, Resource = local.log_res.api },
        { Sid = "DenyQueueConsume", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.queue_arn] },
        { Sid = "DenyDlqAccess", Effect = "Deny", Action = local.sqs_all3, Resource = [local.dlq_arn] },
        { Sid = "DenyProjectionMutation", Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_res },
        { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_deny, Resource = local.bucket_res },
        { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.database, local.kms_arn.audit] },
        { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.logs_w, Resource = local.other_logs.api },
      ]
    }
    projector = {
      trust = "lambda"
      statements = [
        { Sid = "AllowConsumeMainQueue", Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [local.queue_arn] },
        { Sid = "AllowDlqForward", Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [local.dlq_arn] },
        { Sid = "AllowProjectionUpsert", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.table_res },
        { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.messaging, local.kms_arn.projection] },
        { Sid = "AllowOwnLogGroup", Effect = "Allow", Action = local.logs_rw, Resource = local.log_res.projector },
        { Sid = "DenyMainQueueSend", Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [local.queue_arn] },
        { Sid = "DenyDlqConsume", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.dlq_arn] },
        { Sid = "DenyProjectionDelete", Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_res },
        { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_deny, Resource = local.bucket_res },
        { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.database, local.kms_arn.audit] },
        { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.logs_w, Resource = local.other_logs.projector },
      ]
    }
    relay = {
      trust = "lambda"
      statements = [
        { Sid = "AllowPublishMainQueue", Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [local.queue_arn] },
        { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.messaging, local.kms_arn.database] },
        { Sid = "AllowOwnLogGroup", Effect = "Allow", Action = local.logs_rw, Resource = local.log_res.relay },
        { Sid = "DenyQueueConsume", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.queue_arn] },
        { Sid = "DenyDlqAccess", Effect = "Deny", Action = local.sqs_all3, Resource = [local.dlq_arn] },
        { Sid = "DenyProjectionTable", Effect = "Deny", Action = local.ddb_all5, Resource = local.table_res },
        { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_deny, Resource = local.bucket_res },
        { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.projection, local.kms_arn.audit] },
        { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.logs_w, Resource = local.other_logs.relay },
      ]
    }
    archiver = {
      trust = "lambda"
      statements = [
        { Sid = "AllowAuditObjects", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${local.bucket_arn}/ledger-audit/*"] },
        { Sid = "AllowAuditBucketMetadata", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [local.bucket_arn] },
        { Sid = "AllowKms", Effect = "Allow", Action = local.kms_use, Resource = [local.kms_arn.audit, local.kms_arn.database] },
        { Sid = "AllowOwnLogGroup", Effect = "Allow", Action = local.logs_rw, Resource = local.log_res.archiver },
        { Sid = "DenyAuditDelete", Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_res },
        { Sid = "DenyQueues", Effect = "Deny", Action = local.sqs_all3, Resource = local.all_queues },
        { Sid = "DenyProjectionTable", Effect = "Deny", Action = local.ddb_all5, Resource = local.table_res },
        { Sid = "DenyForeignKms", Effect = "Deny", Action = local.kms_deny, Resource = [local.kms_arn.messaging, local.kms_arn.projection] },
        { Sid = "DenyOtherLogGroups", Effect = "Deny", Action = local.logs_w, Resource = local.other_logs.archiver },
      ]
    }
  }
}

locals {
  role_trust = {
    ecs_execution = "ecs-tasks"
    ecs_task      = "ecs-tasks"
    projector     = "lambda"
    relay         = "lambda"
    archiver      = "lambda"
    scheduler     = "scheduler"
  }

  scheduler_statements = [
    { Sid = "AllowInvokeWorkers", Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.outbox_relay.arn, aws_lambda_function.audit_archiver.arn] },
    { Sid = "DenyInvokeProjector", Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.projector.arn] },
    { Sid = "DenyQueues", Effect = "Deny", Action = local.sqs_all3, Resource = local.all_queues },
    { Sid = "DenyProjectionTable", Effect = "Deny", Action = local.ddb_all5, Resource = local.table_res },
    { Sid = "DenyAuditBucket", Effect = "Deny", Action = local.s3_deny, Resource = local.bucket_res },
    { Sid = "DenyAllKmsKeys", Effect = "Deny", Action = local.kms_deny, Resource = values(local.kms_arn) },
    { Sid = "DenyAllLogGroups", Effect = "Deny", Action = local.logs_w, Resource = flatten(values(local.log_res)) },
  ]
}

resource "aws_iam_role" "this" {
  for_each           = local.role_trust
  name               = "${local.prefix}-${replace(each.key, "_", "-")}"
  assume_role_policy = local.trust[each.value]
  tags               = merge(local.tags, { Name = "${local.prefix}-${replace(each.key, "_", "-")}" })
}

resource "aws_iam_role_policy" "this" {
  for_each = local.policies
  name     = "${local.prefix}-${replace(each.key, "_", "-")}-policy"
  role     = aws_iam_role.this[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value.statements
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.prefix}-scheduler-policy"
  role = aws_iam_role.this["scheduler"].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.scheduler_statements
  })
}
