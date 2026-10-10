locals {
  kms_purposes = {
    database   = "RDS PostgreSQL storage"
    messaging  = "SQS main queue and DLQ"
    projection = "DynamoDB projection table"
    audit      = "S3 audit archive"
  }
}

resource "aws_kms_key" "this" {
  for_each                = local.kms_purposes
  description             = "${local.prefix} ${each.key}: ${each.value}"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  tags                    = merge(local.tags, { Name = "${local.prefix}-${each.key}", Purpose = each.key })
}

resource "aws_kms_alias" "this" {
  for_each      = local.kms_purposes
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
