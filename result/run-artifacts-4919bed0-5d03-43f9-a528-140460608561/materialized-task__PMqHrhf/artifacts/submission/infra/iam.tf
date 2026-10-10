locals {
  roles = {
    ecs_execution = "ecs-tasks.amazonaws.com", ecs_task = "ecs-tasks.amazonaws.com",
    projector     = "lambda.amazonaws.com", relay = "lambda.amazonaws.com",
    archiver      = "lambda.amazonaws.com", scheduler = "scheduler.amazonaws.com"
  }
  log_owner     = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver", scheduler = "none" }
  key_access    = { ecs_execution = [], ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"], relay = ["database", "messaging"], archiver = ["database", "audit"], scheduler = [] }
  lambda_arns   = { for k in ["projector", "relay", "archiver"] : k => "arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:${local.p}-${k}" }
  ddb_resources = [aws_dynamodb_table.projection.arn, "${aws_dynamodb_table.projection.arn}/index/AccountIndex"]
  s3_resources  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  sqs_actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:DeleteTable"]
  s3_actions    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  workload_allow = {
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
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [local.lambda_arns.relay, local.lambda_arns.archiver] }]
  }
}
resource "aws_iam_role" "roles" {
  for_each           = local.roles
  name               = "${local.p}-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = each.value } }] })
  tags               = { ClearLedgerRole = each.key }
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.roles
  name     = "${local.p}-${each.key}-canonical"
  role     = aws_iam_role.roles[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.workload_allow[each.key],
    each.key == "scheduler" ? [] : [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.logs[local.log_owner[each.key]].arn}:*"] }],
    length(local.key_access[each.key]) == 0 ? [] : [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.key_access[each.key] : aws_kms_key.keys[k].arn] }],
    [
      { Effect = "Deny", Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = [for k in aws_kms_key.keys : k.arn] },
      { Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in aws_kms_key.keys : v.arn if !contains(local.key_access[each.key], k)] },
      { Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, v in aws_cloudwatch_log_group.logs : "${v.arn}:*" if k != local.log_owner[each.key]] },
      { Effect = "Deny", Action = each.key == "projector" ? ["sqs:SendMessage"] : contains(["ecs_task", "relay"], each.key) ? ["sqs:ReceiveMessage", "sqs:DeleteMessage"] : local.sqs_actions, Resource = [aws_sqs_queue.events.arn] },
      { Effect = "Deny", Action = each.key == "projector" ? ["sqs:ReceiveMessage", "sqs:DeleteMessage"] : local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = each.key == "projector" ? ["dynamodb:DeleteItem", "dynamodb:DeleteTable"] : each.key == "ecs_task" ? ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"] : local.ddb_actions, Resource = local.ddb_resources },
      { Effect = "Deny", Action = each.key == "archiver" ? ["s3:DeleteObject", "s3:DeleteObjectVersion"] : local.s3_actions, Resource = local.s3_resources }
    ],
    each.key == "scheduler" ? [{ Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.lambda_arns.projector] }] : []
  ) })
}
