locals {
  kms_usages = ["database", "messaging", "projection", "audit"]

  log_groups = {
    api       = "/clearledger/${local.prefix}/api"
    projector = "/clearledger/${local.prefix}/projector"
    relay     = "/clearledger/${local.prefix}/outbox-relay"
    archiver  = "/clearledger/${local.prefix}/audit-archiver"
  }
}

resource "aws_kms_key" "this" {
  for_each = toset(local.kms_usages)

  description             = "ClearLedger ${local.prefix} ${each.key} key"
  key_usage               = "ENCRYPT_DECRYPT"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  is_enabled              = true

  tags = merge(local.tags, {
    Name                = "${local.prefix}-${each.key}"
    ClearLedgerKeyUsage = each.key
  })
}

resource "aws_kms_alias" "this" {
  for_each = toset(local.kms_usages)

  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups

  name              = each.value
  retention_in_days = 14

  tags = merge(local.tags, { ClearLedgerWorkload = each.key })
}
