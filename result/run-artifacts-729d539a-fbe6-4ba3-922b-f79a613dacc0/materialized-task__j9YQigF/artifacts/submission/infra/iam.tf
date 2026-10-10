locals {
  role_services = { ecs_execution = "ecs-tasks", ecs_task = "ecs-tasks", projector = "lambda", relay = "lambda", archiver = "lambda", scheduler = "scheduler" }
  role_logs     = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver" }
  role_keys     = { ecs_execution = [], ecs_task = ["messaging", "projection"], projector = ["messaging", "projection"], relay = ["messaging", "database"], archiver = ["audit", "database"], scheduler = [] }
  queues        = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
  ddb_resources = [aws_dynamodb_table.main.arn, "${aws_dynamodb_table.main.arn}/index/AccountIndex"]
  s3_resources  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  sqs_actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:DeleteTable"]
  s3_actions    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  extra_allow = {
    ecs_execution = []
    ecs_task = [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.ddb_resources }
    ]
    projector = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.ddb_resources }
    ]
    relay = [{ Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] }]
    archiver = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.audit.arn] }
    ]
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [for k in ["relay", "archiver"] : "arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:${local.prefix}-${k}"] }]
  }
  sqs_deny = {
    ecs_execution = [{ Effect = "Deny", Action = local.sqs_actions, Resource = local.queues }]
    ecs_task = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] }
    ]
    projector = [
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] }
    ]
    relay = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] }
    ]
    archiver  = [{ Effect = "Deny", Action = local.sqs_actions, Resource = local.queues }]
    scheduler = [{ Effect = "Deny", Action = local.sqs_actions, Resource = local.queues }]
  }
  ddb_deny_actions = { ecs_execution = local.ddb_actions, ecs_task = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], projector = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], relay = local.ddb_actions, archiver = local.ddb_actions, scheduler = local.ddb_actions }
}
resource "aws_iam_role" "roles" {
  for_each              = local.role_services
  name                  = "${local.prefix}-${each.key}"
  force_detach_policies = true
  assume_role_policy    = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "${each.value}.amazonaws.com" } }] })
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.role_services
  name     = "${local.prefix}-${each.key}-canonical"
  role     = aws_iam_role.roles[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.extra_allow[each.key],
    each.key == "scheduler" ? [] : [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.workloads[local.role_logs[each.key]].arn}:*"] }],
    length(local.role_keys[each.key]) == 0 ? [] : [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k in local.role_keys[each.key] : aws_kms_key.keys[k].arn] }],
    local.sqs_deny[each.key],
    [{ Effect = "Deny", Action = local.ddb_deny_actions[each.key], Resource = local.ddb_resources }],
    [{ Effect = "Deny", Action = each.key == "archiver" ? ["s3:DeleteObject", "s3:DeleteObjectVersion"] : local.s3_actions, Resource = local.s3_resources }],
    [{ Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in aws_kms_key.keys : v.arn if !contains(local.role_keys[each.key], k)] }],
    [{ Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, v in aws_cloudwatch_log_group.workloads : "${v.arn}:*" if k != lookup(local.role_logs, each.key, "")] }],
    each.key == "scheduler" ? [{ Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = ["arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:${local.prefix}-projector"] }] : []
  ) })
}
