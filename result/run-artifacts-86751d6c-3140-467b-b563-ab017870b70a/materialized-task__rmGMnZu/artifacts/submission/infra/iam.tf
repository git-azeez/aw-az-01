locals {
  roles            = { ecs_execution = "ecs-tasks.amazonaws.com", ecs_task = "ecs-tasks.amazonaws.com", projector = "lambda.amazonaws.com", relay = "lambda.amazonaws.com", archiver = "lambda.amazonaws.com", scheduler = "scheduler.amazonaws.com" }
  log_owner        = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver", scheduler = "none" }
  crypto           = { ecs_execution = [], ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"], relay = ["messaging", "database"], archiver = ["audit", "database"], scheduler = [] }
  table_resources  = [aws_dynamodb_table.main.arn, "${aws_dynamodb_table.main.arn}/index/AccountIndex"]
  bucket_resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  queue_actions    = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  table_actions    = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  bucket_actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  allow_data = {
    ecs_execution = []
    ecs_task = [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.table_resources }
    ]
    projector = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.table_resources }
    ]
    relay = [{ Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] }]
    archiver = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.audit.arn] }
    ]
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [for k in ["relay", "archiver"] : "arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:${local.prefix}-${local.worker_names[k]}"] }]
  }
}
resource "aws_iam_role" "workload" {
  for_each              = local.roles
  name                  = "${local.prefix}-${each.key}"
  force_detach_policies = true
  assume_role_policy    = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = each.value } }] })
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.roles
  name     = "${local.prefix}-canonical"
  role     = aws_iam_role.workload[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.allow_data[each.key],
    each.key == "scheduler" ? [] : [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.workload[local.log_owner[each.key]].arn}:*"] }],
    length(local.crypto[each.key]) == 0 ? [] : [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.crypto[each.key] : aws_kms_key.store[k].arn] }],
    [{ Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in aws_kms_key.store : v.arn if !contains(local.crypto[each.key], k)] }],
    [{ Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, v in aws_cloudwatch_log_group.workload : "${v.arn}:*" if k != local.log_owner[each.key]] }],
    contains(["ecs_task", "relay"], each.key) ? [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.queue_actions, Resource = [aws_sqs_queue.dlq.arn] }
    ] : [],
    each.key == "projector" ? [
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] }
    ] : [],
    contains(["ecs_execution", "archiver", "scheduler"], each.key) ? [{ Effect = "Deny", Action = local.queue_actions, Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn] }] : [],
    each.key == "ecs_task" ? [{ Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.main.arn] }] : each.key == "projector" ? [{ Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.main.arn] }] : [{ Effect = "Deny", Action = local.table_actions, Resource = local.table_resources }],
    each.key == "archiver" ? [{ Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_resources }] : [{ Effect = "Deny", Action = local.bucket_actions, Resource = local.bucket_resources }],
    each.key == "scheduler" ? [{ Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = ["arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:${local.prefix}-projector"] }] : []
  ) })
}
