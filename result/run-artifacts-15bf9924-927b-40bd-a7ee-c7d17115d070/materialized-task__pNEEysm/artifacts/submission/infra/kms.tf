locals {
  kms_usages = toset(["database", "messaging", "projection", "audit"])
}

resource "aws_kms_key" "this" {
  for_each                = local.kms_usages
  description             = "ClearLedger ${each.key} key (${local.prefix})"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  is_enabled              = true
  tags = merge(local.tags, {
    Name                = "${local.prefix}-${each.key}"
    ClearLedgerKeyUsage = each.key
  })
}

resource "aws_kms_alias" "this" {
  for_each      = local.kms_usages
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

resource "aws_cloudwatch_log_group" "api" {
  name              = local.api_log_group_name
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "projector" {
  name              = local.projector_log_group_name
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "relay" {
  name              = local.relay_log_group_name
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "archiver" {
  name              = local.archiver_log_group_name
  retention_in_days = 14
  tags              = local.tags
}
