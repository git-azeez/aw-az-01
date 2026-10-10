resource "aws_iam_role" "role" {
  for_each = local.roles
  name     = "${local.p}-${each.key}"
  tags     = { ClearLedgerRole = each.key }
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = startswith(each.key, "ecs_") ? "ecs-tasks.amazonaws.com" : each.key == "scheduler" ? "scheduler.amazonaws.com" : "lambda.amazonaws.com" }
  }] })
}
locals {
  queues      = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
  ddb         = [aws_dynamodb_table.main.arn, "${aws_dynamodb_table.main.arn}/index/AccountIndex"]
  s3          = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  sqs_actions = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
  ddb_actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  s3_actions  = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  role_log    = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver", scheduler = "none" }
  key_arns    = [for k in aws_kms_key.key : k.arn]
}
resource "aws_iam_role_policy" "canonical" {
  for_each = local.roles
  name     = "${local.p}-canonical"
  role     = aws_iam_role.role[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    [{ Effect = "Deny", Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = local.key_arns }],
    [{ Effect = "Deny", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [for k, rs in local.key_roles : aws_kms_key.key[k].arn if !contains(rs, each.key)] }],
    [{ Effect = "Deny", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for k, g in aws_cloudwatch_log_group.log : "${g.arn}:*" if k != local.role_log[each.key]] }],
    each.key != "scheduler" ? [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.log[local.role_log[each.key]].arn}:*"] }] : [],
    contains(["ecs_task", "projector", "relay", "archiver"], each.key) ? [{ Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = [for k, rs in local.key_roles : aws_kms_key.key[k].arn if contains(rs, each.key)] }] : [],
    contains(["ecs_task", "relay"], each.key) ? [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = local.sqs_actions, Resource = [aws_sqs_queue.dlq.arn] }
    ] : [],
    each.key == "projector" ? [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.dlq.arn] },
      { Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main.arn] },
      { Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [aws_sqs_queue.dlq.arn] }
    ] : [],
    contains(["ecs_execution", "archiver", "scheduler"], each.key) ? [{ Effect = "Deny", Action = local.sqs_actions, Resource = local.queues }] : [],
    each.key == "ecs_task" ? [
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = local.ddb },
      { Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.main.arn] }
    ] : [],
    each.key == "projector" ? [
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = local.ddb },
      { Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [aws_dynamodb_table.main.arn] }
    ] : [],
    contains(["ecs_execution", "relay", "archiver", "scheduler"], each.key) ? [{ Effect = "Deny", Action = local.ddb_actions, Resource = local.ddb }] : [],
    each.key == "archiver" ? [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.audit.arn] },
      { Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.s3 }
    ] : [{ Effect = "Deny", Action = local.s3_actions, Resource = local.s3 }],
    each.key == "scheduler" ? [
      { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [local.worker_arns.relay, local.worker_arns.archiver] },
      { Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.worker_arns.projector] }
    ] : []
  ) })
}
resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.url
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = [local.role_arns.ecs_task, local.role_arns.relay] }, Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = aws_sqs_queue.main.arn },
    { Effect = "Allow", Principal = { AWS = local.role_arns.projector }, Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = aws_sqs_queue.main.arn },
    { Effect = "Deny", Principal = { AWS = [for r in ["ecs_execution", "projector", "archiver", "scheduler"] : local.role_arns[r]] }, Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.main.arn },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : local.role_arns[r] if r != "projector"] }, Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = aws_sqs_queue.main.arn }
  ] })
}
resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.url
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = local.role_arns.projector }, Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.dlq.arn },
    { Effect = "Deny", Principal = { AWS = values(local.role_arns) }, Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = aws_sqs_queue.dlq.arn },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : local.role_arns[r] if r != "projector"] }, Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.dlq.arn }
  ] })
}
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = local.role_arns.archiver }, Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = "${aws_s3_bucket.audit.arn}/ledger-audit/*" },
    { Effect = "Allow", Principal = { AWS = local.role_arns.archiver }, Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.audit.arn },
    { Effect = "Deny", Principal = { AWS = values(local.role_arns) }, Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.s3 },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : local.role_arns[r] if r != "archiver"] }, Action = ["s3:PutObject"], Resource = local.s3 }
  ] })
}
