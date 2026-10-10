locals {
  role_arns = {
    ecs_execution = aws_iam_role.ecs_execution.arn
    ecs_task      = aws_iam_role.ecs_task.arn
    projector     = aws_iam_role.projector.arn
    relay         = aws_iam_role.relay.arn
    archiver      = aws_iam_role.archiver.arn
    scheduler     = aws_iam_role.scheduler.arn
  }

  kms_usage = {
    database   = ["relay", "archiver"]
    messaging  = ["ecs_task", "projector", "relay"]
    projection = ["ecs_task", "projector"]
    audit      = ["archiver"]
  }

  kms_descriptions = {
    database   = "ClearLedger RDS PostgreSQL encryption"
    messaging  = "ClearLedger SQS queue and DLQ encryption"
    projection = "ClearLedger DynamoDB projection encryption"
    audit      = "ClearLedger S3 audit archive encryption"
  }
}

resource "aws_kms_key" "key" {
  for_each                = local.kms_usage
  description             = "${local.p} ${local.kms_descriptions[each.key]}"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  is_enabled              = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.p}-${each.key}-key-policy"
    Statement = [
      {
        Sid       = "EnableRootAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowAuthorizedWorkloadCryptoUsage"
        Effect    = "Allow"
        Principal = { AWS = [for r in each.value : local.role_arns[r]] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource  = "*"
      },
      {
        Sid       = "DenyWorkloadKeyDisableOrDeletion"
        Effect    = "Deny"
        Principal = { AWS = values(local.role_arns) }
        Action    = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
        Resource  = "*"
      },
      {
        Sid       = "DenyUnauthorizedWorkloadCryptoUsage"
        Effect    = "Deny"
        Principal = { AWS = [for r, arn in local.role_arns : arn if !contains(each.value, r)] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
      }
    ]
  })

  tags = merge(local.tags, {
    Name                = "${local.p}-${each.key}"
    ClearLedgerKeyUsage = each.key
  })
}

resource "aws_kms_alias" "key" {
  for_each      = local.kms_usage
  name          = "alias/${local.p}-${each.key}"
  target_key_id = aws_kms_key.key[each.key].key_id
}
