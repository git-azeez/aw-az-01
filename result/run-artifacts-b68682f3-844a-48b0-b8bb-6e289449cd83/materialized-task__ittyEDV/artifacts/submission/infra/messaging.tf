resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-events-dlq"
  kms_master_key_id         = aws_kms_key.this["messaging"].arn
  message_retention_seconds = 1209600

  tags = merge(local.tags, { Name = "${local.prefix}-events-dlq" })
}

resource "aws_sqs_queue" "main" {
  name                       = "${local.prefix}-events"
  kms_master_key_id          = aws_kms_key.this["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 4
  })

  tags = merge(local.tags, { Name = "${local.prefix}-events" })
}

locals {
  r_arn = { for k, v in aws_iam_role.this : k => v.arn }

  q_allow_publish = [local.r_arn["ecs_task"], local.r_arn["relay"]]
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.prefix}-events-policy"
    Statement = [
      {
        Sid       = "AllowPublishers"
        Effect    = "Allow"
        Principal = { AWS = local.q_allow_publish }
        Action    = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid       = "AllowProjectorConsume"
        Effect    = "Allow"
        Principal = { AWS = local.r_arn["projector"] }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid    = "DenySendFromNonPublishers"
        Effect = "Deny"
        Principal = {
          AWS = [for r in ["ecs_execution", "projector", "archiver", "scheduler"] : local.r_arn[r]]
        }
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.main.arn
      },
      {
        Sid    = "DenyConsumeFromNonConsumers"
        Effect = "Deny"
        Principal = {
          AWS = [for r in ["ecs_execution", "ecs_task", "relay", "archiver", "scheduler"] : local.r_arn[r]]
        }
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = aws_sqs_queue.main.arn
      },
    ]
  })
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.prefix}-events-dlq-policy"
    Statement = [
      {
        Sid       = "AllowProjectorDeadLetter"
        Effect    = "Allow"
        Principal = { AWS = local.r_arn["projector"] }
        Action    = ["sqs:SendMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid       = "DenyConsumeFromAllWorkloads"
        Effect    = "Deny"
        Principal = { AWS = [for r in local.role_names : local.r_arn[r]] }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid    = "DenySendFromNonProjectors"
        Effect = "Deny"
        Principal = {
          AWS = [for r in ["ecs_execution", "ecs_task", "relay", "archiver", "scheduler"] : local.r_arn[r]]
        }
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
    ]
  })
}
