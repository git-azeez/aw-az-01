locals {
  kms_purposes = {
    database   = "ClearLedger RDS PostgreSQL storage encryption"
    messaging  = "ClearLedger SQS main queue and DLQ encryption"
    projection = "ClearLedger DynamoDB projection table encryption"
    audit      = "ClearLedger S3 audit archive encryption"
  }
}

resource "aws_kms_key" "this" {
  for_each = local.kms_purposes

  description             = "${local.p}-${each.key}: ${each.value}"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = { Name = "${local.p}-${each.key}", Purpose = each.key }
}

resource "aws_kms_alias" "this" {
  for_each = local.kms_purposes

  name          = "alias/${local.p}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
