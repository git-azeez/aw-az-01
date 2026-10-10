locals {
  queue_arns   = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
  table_arns   = [aws_dynamodb_table.projection.arn, "${aws_dynamodb_table.projection.arn}/index/AccountIndex"]
  bucket_arns  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  key_arns     = [for k in aws_kms_key.store : k.arn]
  allowed_keys = { ecs_execution = [], ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"], relay = ["database", "messaging"], archiver = ["database", "audit"], scheduler = [] }
  role_logs    = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver", scheduler = "" }
  sqs_actions  = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_actions  = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  role_allows = {
    ecs_execution = []
    ecs_task = [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.table_arns }
    ]
    projector = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.table_arns }
    ]
    relay = [{ Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] }]
    archiver = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.audit.arn] }
    ]
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [local.function_arns.relay, local.function_arns.archiver] }]
  }
  role_denies = {
    ecs_execution = [
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_arns },
      { Effect = "Deny", Action = local.ddb_actions, Resource = local.table_arns },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
    ecs_task = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.projection.arn] },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
    projector = [
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.projection.arn] },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
    relay = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = local.ddb_actions, Resource = local.table_arns },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
    archiver = [
      { Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_arns },
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_arns },
      { Effect = "Deny", Action = local.ddb_actions, Resource = local.table_arns }
    ]
    scheduler = [
      { Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.function_arns.projector] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_arns },
      { Effect = "Deny", Action = local.ddb_actions, Resource = local.table_arns },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
  }
}
resource "aws_iam_role" "workload" {
  for_each           = local.roles
  name               = "${local.prefix}-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = contains(["ecs_execution", "ecs_task"], each.key) ? "ecs-tasks.amazonaws.com" : (each.key == "scheduler" ? "scheduler.amazonaws.com" : "lambda.amazonaws.com") } }] })
  tags               = { ClearLedgerRole = each.key }
}
resource "aws_iam_role_policy" "workload" {
  for_each = local.roles
  name     = "${local.prefix}-${each.key}-canonical"
  role     = aws_iam_role.workload[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.role_allows[each.key],
    each.key == "scheduler" ? [] : [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.workload[local.role_logs[each.key]].arn}:*"] }],
    length(local.allowed_keys[each.key]) == 0 ? [] : [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.allowed_keys[each.key] : aws_kms_key.store[k].arn] }],
    local.role_denies[each.key],
    [
      { Effect = "Deny", Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = local.key_arns },
      { Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in aws_kms_key.store : v.arn if !contains(local.allowed_keys[each.key], k)] },
      { Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, v in aws_cloudwatch_log_group.workload : "${v.arn}:*" if k != local.role_logs[each.key]] }
    ]
  ) })
}
