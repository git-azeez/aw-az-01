locals {
  kms_usages = ["database", "messaging", "projection", "audit"]
}

resource "aws_kms_key" "this" {
  for_each = toset(local.kms_usages)

  description             = "ClearLedger ${local.prefix} ${each.key} key"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = {
    Name                = "${local.prefix}-${each.key}"
    ClearLedgerKeyUsage = each.key
  }
}

resource "aws_kms_alias" "this" {
  for_each = toset(local.kms_usages)

  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_group_names

  name              = each.value
  retention_in_days = 14

  tags = {
    Name = "${local.prefix}-${each.key}-logs"
  }
}
