locals {
  account_id = data.aws_caller_identity.current.account_id
  root_arn   = "arn:aws:iam::${local.account_id}:root"

  # Roles authorised to use each key.
  kms_users = {
    database   = ["relay", "archiver"]
    messaging  = ["ecs_task", "projector", "relay"]
    projection = ["ecs_task", "projector"]
    audit      = ["archiver"]
  }
  role_names = ["ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler"]
}

resource "aws_kms_key" "this" {
  for_each                = local.kms_users
  description             = "ClearLedger ${each.key} key (${local.prefix})"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  is_enabled              = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.prefix}-${each.key}"
    Statement = [
      {
        Sid       = "AccountRootAdministration"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AuthorizedWorkloadCryptoUse"
        Effect    = "Allow"
        Principal = { AWS = [for r in each.value : aws_iam_role.this[r].arn] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource  = "*"
      },
      {
        Sid       = "DenyKeyLifecycleForAllWorkloads"
        Effect    = "Deny"
        Principal = { AWS = [for r in local.role_names : aws_iam_role.this[r].arn] }
        Action    = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
        Resource  = "*"
      },
      {
        Sid    = "DenyCryptoForUnauthorizedWorkloads"
        Effect = "Deny"
        Principal = {
          AWS = [for r in local.role_names : aws_iam_role.this[r].arn if !contains(each.value, r)]
        }
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = "*"
      },
    ]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-${each.key}", ClearLedgerKeyUsage = each.key })
}

resource "aws_kms_alias" "this" {
  for_each      = local.kms_users
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
