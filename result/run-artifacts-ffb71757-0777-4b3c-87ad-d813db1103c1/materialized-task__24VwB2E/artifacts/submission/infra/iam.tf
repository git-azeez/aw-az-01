locals {
  trusts = {
    ecs_execution = "ecs-tasks.amazonaws.com", ecs_task = "ecs-tasks.amazonaws.com"
    projector     = "lambda.amazonaws.com", relay = "lambda.amazonaws.com", archiver = "lambda.amazonaws.com"
    scheduler     = "scheduler.amazonaws.com"
  }
  log_owner = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver", scheduler = "none" }
  key_access = {
    ecs_execution = [], ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"]
    relay         = ["database", "messaging"], archiver = ["database", "audit"], scheduler = []
  }
  ddb_resources = [aws_dynamodb_table.main.arn, "${aws_dynamodb_table.main.arn}/index/AccountIndex"]
  s3_resources  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  sqs_resources = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
  sqs_actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:DeleteTable"]
  s3_actions    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  allow = {
    ecs_execution = []
    ecs_task = [
      { Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] },
      { Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.ddb_resources }
    ]
    projector = [
      { Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.main.arn] },
      { Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.ddb_resources }
    ]
    relay = [{ Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] }]
    archiver = [
      { Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"] },
      { Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.audit.arn] }
    ]
    scheduler = [{ Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.workers["relay"].arn, aws_lambda_function.workers["archiver"].arn] }]
  }
  deny = {
    ecs_execution = [
      { Action = local.sqs_actions, Resource = local.sqs_resources },
      { Action = local.ddb_actions, Resource = local.ddb_resources },
      { Action = local.s3_actions, Resource = local.s3_resources }
    ]
    ecs_task = [
      { Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.ddb_resources },
      { Action = local.s3_actions, Resource = local.s3_resources }
    ]
    projector = [
      { Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = local.ddb_resources },
      { Action = local.s3_actions, Resource = local.s3_resources }
    ]
    relay = [
      { Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Action = local.ddb_actions, Resource = local.ddb_resources },
      { Action = local.s3_actions, Resource = local.s3_resources }
    ]
    archiver = [
      { Action = local.sqs_actions, Resource = local.sqs_resources },
      { Action = local.ddb_actions, Resource = local.ddb_resources },
      { Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.s3_resources }
    ]
    scheduler = [
      { Action = ["lambda:InvokeFunction"], Resource = [aws_lambda_function.workers["projector"].arn] },
      { Action = local.sqs_actions, Resource = local.sqs_resources },
      { Action = local.ddb_actions, Resource = local.ddb_resources },
      { Action = local.s3_actions, Resource = local.s3_resources }
    ]
  }
}
resource "aws_iam_role" "roles" {
  for_each              = local.trusts
  name                  = "${local.p}-${each.key}"
  force_detach_policies = true
  assume_role_policy    = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = each.value } }] })
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.trusts
  name     = "${local.p}-${each.key}-canonical"
  role     = aws_iam_role.roles[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    [for s in local.allow[each.key] : merge(s, { Effect = "Allow" })],
    [for k, g in aws_cloudwatch_log_group.logs : {
      Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${g.arn}:*"]
    } if k == local.log_owner[each.key]],
    length(local.key_access[each.key]) == 0 ? [] : [{
      Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.key_access[each.key] : aws_kms_key.keys[k].arn]
    }],
    [for s in local.deny[each.key] : merge(s, { Effect = "Deny" })],
    [{ Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, key in aws_kms_key.keys : key.arn if !contains(local.key_access[each.key], k)] }],
    [{ Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, g in aws_cloudwatch_log_group.logs : "${g.arn}:*" if k != local.log_owner[each.key]] }]
  ) })
}
