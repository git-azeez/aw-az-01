locals {
  queue_arns   = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
  table_arns   = [aws_dynamodb_table.projection.arn, "${aws_dynamodb_table.projection.arn}/index/AccountIndex"]
  bucket_arns  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  key_arns     = [for k in aws_kms_key.keys : k.arn]
  log_arns     = { for k, g in aws_cloudwatch_log_group.logs : k => "${g.arn}:*" }
  workload_log = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver" }
  crypto_keys  = { ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"], relay = ["messaging", "database"], archiver = ["audit", "database"] }
  sqs_actions  = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_actions  = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  allows = {
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
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.workers["relay"].arn, aws_lambda_function.workers["archiver"].arn] }]
  }
  denies = {
    ecs_execution = [
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_arns },
      { Effect = "Deny", Action = local.ddb_actions, Resource = local.table_arns },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
    ecs_task = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_arns },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
    projector = [
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_arns },
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
      { Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.workers["projector"].arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_arns },
      { Effect = "Deny", Action = local.ddb_actions, Resource = local.table_arns },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_arns }
    ]
  }
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.roles
  name     = "${local.p}-${each.key}-canonical"
  role     = aws_iam_role.roles[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.allows[each.key], local.denies[each.key],
    [{ Effect = "Deny", Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = local.key_arns }],
    [{ Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in aws_kms_key.keys : v.arn if !contains(lookup(local.crypto_keys, each.key, []), k)] }],
    [{ Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, v in local.log_arns : v if k != lookup(local.workload_log, each.key, "none")] }],
    contains(keys(local.workload_log), each.key) ? [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = [local.log_arns[local.workload_log[each.key]]] }] : [],
    contains(keys(local.crypto_keys), each.key) ? [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.crypto_keys[each.key] : aws_kms_key.keys[k].arn] }] : []
  ) })
}
