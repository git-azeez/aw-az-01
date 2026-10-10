locals {
  kms_usages = ["database", "messaging", "projection", "audit"]

  # Workload roles authorised for cryptographic usage of each key.
  kms_authorized = {
    database   = ["relay", "archiver"]
    messaging  = ["ecs_task", "projector", "relay"]
    projection = ["ecs_task", "projector"]
    audit      = ["archiver"]
  }

  kms_admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:CreateGrant",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListGrants",
    "kms:ListKeyPolicies",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:RetireGrant",
    "kms:RevokeGrant",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
  ]
}

resource "aws_kms_key" "this" {
  for_each                = toset(local.kms_usages)
  description             = "${local.prefix} ClearLedger ${each.key} key"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  is_enabled              = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.prefix}-${each.key}-key-policy"
    Statement = concat(
      [
        {
          Sid       = "RootKeyAdministration"
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::${local.account}:root" }
          Action    = local.kms_admin_actions
          Resource  = "*"
        },
        {
          Sid       = "AllowWorkloadCryptoUsage"
          Effect    = "Allow"
          Principal = { AWS = [for r in local.kms_authorized[each.key] : local.role_arns[r]] }
          Action    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
          Resource  = "*"
        },
        {
          Sid       = "DenyWorkloadKeyDestruction"
          Effect    = "Deny"
          Principal = { AWS = [for r in local.role_keys : local.role_arns[r]] }
          Action    = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
          Resource  = "*"
        },
      ],
      [
        {
          Sid       = "DenyUnauthorizedWorkloadCrypto"
          Effect    = "Deny"
          Principal = { AWS = [for r in local.role_keys : local.role_arns[r] if !contains(local.kms_authorized[each.key], r)] }
          Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource  = "*"
        },
      ]
    )
  })

  tags = merge(local.tags, {
    Name                = "${local.prefix}-${each.key}"
    ClearLedgerKeyUsage = each.key
  })

  depends_on = [aws_iam_role.role]
}

resource "aws_kms_alias" "this" {
  for_each      = toset(local.kms_usages)
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
