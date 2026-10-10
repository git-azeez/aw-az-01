locals {
  role_services    = { ecs_execution = "ecs-tasks", ecs_task = "ecs-tasks", projector = "lambda", relay = "lambda", archiver = "lambda", scheduler = "scheduler" }
  role_logs        = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver", scheduler = "" }
  role_keys        = { ecs_execution = [], ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"], relay = ["messaging", "database"], archiver = ["audit", "database"], scheduler = [] }
  table_resources  = [aws_dynamodb_table.projection.arn, "${aws_dynamodb_table.projection.arn}/index/AccountIndex"]
  bucket_resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  sqs_actions      = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  dynamo_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_actions       = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  lambda_arns      = { for k in ["projector", "relay", "archiver"] : k => "arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:${local.prefix}-${local.log_names[k]}" }
  extra_allow = {
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
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [local.lambda_arns.relay, local.lambda_arns.archiver] }]
  }
  extra_deny = {
    ecs_execution = [
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    ecs_task = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    projector = [
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    relay = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
    archiver = [
      { Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.bucket_resources },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources }
    ]
    scheduler = [
      { Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.lambda_arns.projector] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = local.dynamo_actions, Resource = local.table_resources },
      { Effect = "Deny", Action = local.s3_actions, Resource = local.bucket_resources }
    ]
  }
}
resource "aws_iam_role" "roles" {
  for_each           = local.role_services
  name               = "${local.prefix}-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "${each.value}.amazonaws.com" } }] })
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.role_services
  name     = "${local.prefix}-${each.key}-canonical"
  role     = aws_iam_role.roles[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.extra_allow[each.key], local.extra_deny[each.key],
    each.key == "scheduler" ? [] : [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.logs[local.role_logs[each.key]].arn}:*"] }],
    length(local.role_keys[each.key]) == 0 ? [] : [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.role_keys[each.key] : aws_kms_key.keys[k].arn] }],
    [{ Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in aws_kms_key.keys : v.arn if !contains(local.role_keys[each.key], k)] }],
    [{ Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, v in aws_cloudwatch_log_group.logs : "${v.arn}:*" if k != local.role_logs[each.key]] }]
  ) })
}
