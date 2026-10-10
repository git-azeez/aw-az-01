resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-events-dlq"
  kms_master_key_id         = aws_kms_key.messaging.arn
  message_retention_seconds = 1209600

  tags = local.tags
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.prefix}-events"
  kms_master_key_id          = aws_kms_key.messaging.arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 4
  })

  tags = local.tags
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.prefix}-events-policy"
    Statement = [
      {
        Sid       = "AllowPublishers"
        Effect    = "Allow"
        Principal = { AWS = [aws_iam_role.ecs_task.arn, aws_iam_role.relay.arn] }
        Action    = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource  = aws_sqs_queue.events.arn
      },
      {
        Sid       = "AllowProjectorConsume"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.projector.arn }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource  = aws_sqs_queue.events.arn
      },
      {
        Sid    = "DenySendForNonPublishers"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.projector.arn,
          aws_iam_role.archiver.arn,
          aws_iam_role.scheduler.arn,
        ] }
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.events.arn
      },
      {
        Sid    = "DenyConsumeForNonConsumers"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn,
          aws_iam_role.relay.arn,
          aws_iam_role.archiver.arn,
          aws_iam_role.scheduler.arn,
        ] }
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = aws_sqs_queue.events.arn
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
        Sid       = "AllowProjectorDeadLetterForwarding"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.projector.arn }
        Action    = ["sqs:SendMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid       = "DenyConsumeForAllWorkloads"
        Effect    = "Deny"
        Principal = { AWS = local.all_role_arns }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid    = "DenySendForNonProjectors"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn,
          aws_iam_role.relay.arn,
          aws_iam_role.archiver.arn,
          aws_iam_role.scheduler.arn,
        ] }
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
    ]
  })
}
