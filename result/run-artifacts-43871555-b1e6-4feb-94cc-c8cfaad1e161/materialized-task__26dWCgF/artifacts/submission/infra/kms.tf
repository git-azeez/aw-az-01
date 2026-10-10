locals {
  kms_keys = toset(["database", "messaging", "projection", "audit"])
}

resource "aws_kms_key" "this" {
  for_each                = local.kms_keys
  description             = "ClearLedger ${each.key} key (${local.prefix})"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  tags                    = merge(local.tags, { Name = "${local.prefix}-${each.key}" })
}

resource "aws_kms_alias" "this" {
  for_each      = local.kms_keys
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
