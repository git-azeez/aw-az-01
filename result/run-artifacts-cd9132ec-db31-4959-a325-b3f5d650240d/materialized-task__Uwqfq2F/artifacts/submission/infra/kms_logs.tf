locals {
  kms_purposes = {
    database   = "RDS PostgreSQL storage encryption"
    messaging  = "SQS main queue and DLQ encryption"
    projection = "DynamoDB projection table encryption"
    audit      = "S3 audit archive encryption"
  }

  log_groups = {
    api       = "/clearledger/${local.prefix}/api"
    projector = "/clearledger/${local.prefix}/projector"
    relay     = "/clearledger/${local.prefix}/outbox-relay"
    archiver  = "/clearledger/${local.prefix}/audit-archiver"
  }
}

resource "aws_kms_key" "this" {
  for_each = local.kms_purposes

  description             = "${local.prefix} ${each.key}: ${each.value}"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = { Name = "${local.prefix}-${each.key}" }
}

resource "aws_kms_alias" "this" {
  for_each = local.kms_purposes

  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups

  name              = each.value
  retention_in_days = 14

  tags = { Name = "${local.prefix}-${each.key}-logs" }
}
