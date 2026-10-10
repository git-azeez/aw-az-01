locals {
  kms_usage_actions = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]

  role_arns = {
    ecs_execution = aws_iam_role.ecs_execution.arn
    ecs_task      = aws_iam_role.ecs_task.arn
    projector     = aws_iam_role.projector.arn
    relay         = aws_iam_role.relay.arn
    archiver      = aws_iam_role.archiver.arn
    scheduler     = aws_iam_role.scheduler.arn
  }

  all_role_arns = [for k in ["ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler"] : local.role_arns[k]]

  kms_authorized_roles = {
    database   = ["relay", "archiver"]
    messaging  = ["ecs_task", "projector", "relay"]
    projection = ["ecs_task", "projector"]
    audit      = ["archiver"]
  }

  kms_policies = {
    for usage, allowed in local.kms_authorized_roles : usage => jsonencode({
      Version = "2012-10-17"
      Id      = "${local.prefix}-${usage}-key-policy"
      Statement = [
        {
          Sid       = "RootAccountKeyAdministration"
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
          Action = [
            "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*",
            "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*",
            "kms:TagResource", "kms:UntagResource", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
          ]
          Resource = "*"
        },
        {
          Sid       = "AuthorizedWorkloadCryptographicUse"
          Effect    = "Allow"
          Principal = { AWS = [for r in allowed : local.role_arns[r]] }
          Action    = local.kms_usage_actions
          Resource  = "*"
        },
        {
          Sid       = "DenyWorkloadKeyLifecycle"
          Effect    = "Deny"
          Principal = { AWS = local.all_role_arns }
          Action    = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
          Resource  = "*"
        },
        {
          Sid       = "DenyUnauthorizedWorkloadCryptographicUse"
          Effect    = "Deny"
          Principal = { AWS = [for r in ["ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler"] : local.role_arns[r] if !contains(allowed, r)] }
          Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource  = "*"
        },
      ]
    })
  }
}

resource "aws_kms_key" "database" {
  description             = "${local.prefix} ClearLedger RDS PostgreSQL encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  policy                  = local.kms_policies["database"]

  tags = merge(local.tags, { ClearLedgerKeyUsage = "database" })
}

resource "aws_kms_key" "messaging" {
  description             = "${local.prefix} ClearLedger SQS encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  policy                  = local.kms_policies["messaging"]

  tags = merge(local.tags, { ClearLedgerKeyUsage = "messaging" })
}

resource "aws_kms_key" "projection" {
  description             = "${local.prefix} ClearLedger DynamoDB projection encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  policy                  = local.kms_policies["projection"]

  tags = merge(local.tags, { ClearLedgerKeyUsage = "projection" })
}

resource "aws_kms_key" "audit" {
  description             = "${local.prefix} ClearLedger S3 audit archive encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  policy                  = local.kms_policies["audit"]

  tags = merge(local.tags, { ClearLedgerKeyUsage = "audit" })
}

resource "aws_kms_alias" "database" {
  name          = "alias/${local.prefix}-database"
  target_key_id = aws_kms_key.database.key_id
}

resource "aws_kms_alias" "messaging" {
  name          = "alias/${local.prefix}-messaging"
  target_key_id = aws_kms_key.messaging.key_id
}

resource "aws_kms_alias" "projection" {
  name          = "alias/${local.prefix}-projection"
  target_key_id = aws_kms_key.projection.key_id
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${local.prefix}-audit"
  target_key_id = aws_kms_key.audit.key_id
}
