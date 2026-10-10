locals {
  roles = {
    ecs_execution = "ecs-tasks.amazonaws.com", ecs_task = "ecs-tasks.amazonaws.com",
    projector     = "lambda.amazonaws.com", relay = "lambda.amazonaws.com",
    archiver      = "lambda.amazonaws.com", scheduler = "scheduler.amazonaws.com"
  }
  log_roles        = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver" }
  crypto           = { ecs_execution = [], ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"], relay = ["database", "messaging"], archiver = ["database", "audit"], scheduler = [] }
  log_actions      = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  sqs_actions      = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_actions      = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:DeleteTable"]
  s3_actions       = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  ddb_resources    = [aws_dynamodb_table.projection.arn, "${aws_dynamodb_table.projection.arn}/index/AccountIndex"]
  bucket_resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  extra_allow = {
    ecs_execution = []
    ecs_task = [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.ddb_resources }
    ]
    projector = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.ddb_resources }
    ]
    relay = [{ Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.events.arn] }]
    archiver = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.audit.arn] }
    ]
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [for k in ["relay", "archiver"] : aws_lambda_function.worker[k].arn] }]
  }
}
resource "aws_iam_role" "role" {
  for_each           = local.roles
  name               = "${local.prefix}-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = each.value }, Action = "sts:AssumeRole" }] })
  tags               = { ClearLedgerRole = each.key }
}
resource "aws_iam_role_policy" "policy" {
  for_each = local.roles
  name     = "${local.prefix}-${each.key}-canonical"
  role     = aws_iam_role.role[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.extra_allow[each.key],
    contains(keys(local.log_roles), each.key) ? [{ Effect = "Allow", Action = local.log_actions, Resource = ["${aws_cloudwatch_log_group.log[local.log_roles[each.key]].arn}:*"] }] : [],
    length(local.crypto[each.key]) > 0 ? [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.crypto[each.key] : aws_kms_key.key[k].arn] }] : [],
    [
      { Effect = "Deny", Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = [for k in aws_kms_key.key : k.arn] },
      { Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in aws_kms_key.key : v.arn if !contains(local.crypto[each.key], k)] },
      { Effect = "Deny", Action = local.log_actions, Resource = [for k, v in aws_cloudwatch_log_group.log : "${v.arn}:*" if k != lookup(local.log_roles, each.key, "none")] },
      { Effect = "Deny", Action = contains(["ecs_task", "relay"], each.key) ? ["sqs:ReceiveMessage", "sqs:DeleteMessage"] : each.key == "projector" ? ["sqs:SendMessage"] : local.sqs_actions, Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Deny", Action = each.key == "projector" ? ["sqs:ReceiveMessage", "sqs:DeleteMessage"] : local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = each.key == "ecs_task" ? ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"] : each.key == "projector" ? ["dynamodb:DeleteItem", "dynamodb:DeleteTable"] : local.ddb_actions, Resource = local.ddb_resources },
      { Effect = "Deny", Action = each.key == "archiver" ? ["s3:DeleteObject", "s3:DeleteObjectVersion"] : local.s3_actions, Resource = local.bucket_resources }
    ],
    each.key == "scheduler" ? [{ Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.worker["projector"].arn] }] : []
  ) })
}
