locals {
  sqs_publish   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
  sqs_consume   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
  sqs_forbidden = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_all       = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_all        = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  log_write     = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
  crypto        = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  allowed = {
    ecs_execution = []
    ecs_task = [
      { Effect = "Allow", Action = local.sqs_publish, Resource = [local.queue_arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = [local.table_arn, "${local.table_arn}/index/AccountIndex"] }
    ]
    projector = [
      { Effect = "Allow", Action = local.sqs_consume, Resource = [local.queue_arn] },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [local.dlq_arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = [local.table_arn, "${local.table_arn}/index/AccountIndex"] }
    ]
    relay = [{ Effect = "Allow", Action = local.sqs_publish, Resource = [local.queue_arn] }]
    archiver = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${local.bucket_arn}/ledger-audit/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [local.bucket_arn] }
    ]
    scheduler = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [local.worker_arns.relay, local.worker_arns.archiver] }]
  }
  forbidden = {
    ecs_execution = [
      { Effect = "Deny", Action = local.sqs_forbidden, Resource = [local.queue_arn, local.dlq_arn] },
      { Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, "${local.table_arn}/index/AccountIndex"] },
      { Effect = "Deny", Action = local.s3_all, Resource = [local.bucket_arn, "${local.bucket_arn}/*"] }
    ]
    ecs_task = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.queue_arn] },
      { Effect = "Deny", Action = local.sqs_forbidden, Resource = [local.dlq_arn] },
      { Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.table_arn] },
      { Effect = "Deny", Action = local.s3_all, Resource = [local.bucket_arn, "${local.bucket_arn}/*"] }
    ]
    projector = [
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [local.queue_arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.dlq_arn] },
      { Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.table_arn] },
      { Effect = "Deny", Action = local.s3_all, Resource = [local.bucket_arn, "${local.bucket_arn}/*"] }
    ]
    relay = [
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.queue_arn] },
      { Effect = "Deny", Action = local.sqs_forbidden, Resource = [local.dlq_arn] },
      { Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, "${local.table_arn}/index/AccountIndex"] },
      { Effect = "Deny", Action = local.s3_all, Resource = [local.bucket_arn, "${local.bucket_arn}/*"] }
    ]
    archiver = [
      { Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = [local.bucket_arn, "${local.bucket_arn}/*"] },
      { Effect = "Deny", Action = local.sqs_forbidden, Resource = [local.queue_arn, local.dlq_arn] },
      { Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, "${local.table_arn}/index/AccountIndex"] }
    ]
    scheduler = [
      { Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.worker_arns.projector] },
      { Effect = "Deny", Action = local.sqs_forbidden, Resource = [local.queue_arn, local.dlq_arn] },
      { Effect = "Deny", Action = local.ddb_all, Resource = [local.table_arn, "${local.table_arn}/index/AccountIndex"] },
      { Effect = "Deny", Action = local.s3_all, Resource = [local.bucket_arn, "${local.bucket_arn}/*"] }
    ]
  }
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.roles
  name     = "${local.p}-${each.key}-canonical"
  role     = aws_iam_role.workload[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    local.allowed[each.key], local.forbidden[each.key],
    contains(keys(local.role_logs), each.key) ? [{ Effect = "Allow", Action = local.log_write, Resource = ["${aws_cloudwatch_log_group.workload[local.role_logs[each.key]].arn}:*"] }] : [],
    [{ Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, g in aws_cloudwatch_log_group.workload : "${g.arn}:*" if k != lookup(local.role_logs, each.key, "")] }],
    [{ Effect = "Deny", Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = [for k in aws_kms_key.store : k.arn] }],
    [{ Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, v in local.usages : aws_kms_key.store[k].arn if !contains(v, each.key)] }],
    contains(["ecs_execution", "scheduler"], each.key) ? [] : [{ Effect = "Allow", Action = local.crypto, Resource = [for k, v in local.usages : aws_kms_key.store[k].arn if contains(v, each.key)] }]
  ) })
}
