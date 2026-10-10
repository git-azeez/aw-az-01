locals {
  table_resources  = [aws_dynamodb_table.projection.arn, "${aws_dynamodb_table.projection.arn}/index/AccountIndex"]
  bucket_resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  queue_resources  = [aws_sqs_queue.events.arn, aws_sqs_queue.dlq.arn]
  all_key_arns     = [for k in local.keys : aws_kms_key.store[k].arn]
  logging_role     = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver", scheduler = "none" }
  sqs_actions      = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  dynamo_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_actions       = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  allow_statements = {
    ecs_execution = []
    ecs_task = [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.table_resources }
    ]
    projector = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.table_resources }
    ]
    relay = [{ Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.events.arn] }]
    archiver = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.audit.arn] }
    ]
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [local.function_arns.relay, local.function_arns.archiver] }]
  }
  deny_statements = {
    ecs_execution = [
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_resources },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    ecs_task = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.projection.arn] },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    projector = [
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.projection.arn] },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    relay = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    archiver = [
      { Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_resources },
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_resources },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources }
    ]
    scheduler = [
      { Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.function_arns.projector] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = local.queue_resources },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
  }
}
resource "aws_iam_role_policy" "workload" {
  for_each = local.roles
  name     = "${local.p}-${each.key}-canonical"
  role     = aws_iam_role.workload[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.allow_statements[each.key], local.deny_statements[each.key],
    each.key == "scheduler" ? [] : [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.workload[local.logging_role[each.key]].arn}:*"] }],
    length([for k in local.keys : k if contains(local.key_users[k], each.key)]) == 0 ? [] : [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.keys : aws_kms_key.store[k].arn if contains(local.key_users[k], each.key)] }],
    [
      { Effect = "Deny", Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = local.all_key_arns },
      { Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k in local.keys : aws_kms_key.store[k].arn if !contains(local.key_users[k], each.key)] },
      { Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, v in aws_cloudwatch_log_group.workload : "${v.arn}:*" if k != local.logging_role[each.key]] }
    ]
  ) })
}
