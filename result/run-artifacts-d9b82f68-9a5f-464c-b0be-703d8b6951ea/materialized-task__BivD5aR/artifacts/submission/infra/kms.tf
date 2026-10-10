locals {
  kms_usages = toset(["database", "messaging", "projection", "audit"])
}

resource "aws_kms_key" "this" {
  for_each                = local.kms_usages
  description             = "ClearLedger ${each.key} key (${local.prefix})"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = {
    Name                = "${local.prefix}-${each.key}"
    ClearLedgerKeyUsage = each.key
  }
}

resource "aws_kms_alias" "this" {
  for_each      = local.kms_usages
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
