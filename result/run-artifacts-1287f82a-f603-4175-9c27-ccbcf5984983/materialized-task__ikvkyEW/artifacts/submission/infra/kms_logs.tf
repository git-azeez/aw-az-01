locals {
  kms_purposes = {
    database   = "RDS PostgreSQL storage encryption"
    messaging  = "SQS main queue and DLQ encryption"
    projection = "DynamoDB projection table encryption"
    audit      = "S3 audit archive encryption"
  }

  log_groups = {
    api       = "/clearledger/${var.resource_prefix}/api"
    projector = "/clearledger/${var.resource_prefix}/projector"
    relay     = "/clearledger/${var.resource_prefix}/outbox-relay"
    archiver  = "/clearledger/${var.resource_prefix}/audit-archiver"
  }

  # Per-workload log group ARNs (group itself + its streams).
  log_arns = {
    for k, name in local.log_groups : k => [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:${name}",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:${name}:*",
    ]
  }
}

resource "aws_kms_key" "this" {
  for_each = local.kms_purposes

  description             = "${var.resource_prefix} ClearLedger ${each.key} key: ${each.value}"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = { Name = "${var.resource_prefix}-${each.key}" }
}

resource "aws_kms_alias" "this" {
  for_each = local.kms_purposes

  name          = "alias/${var.resource_prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups

  name              = each.value
  retention_in_days = 14

  tags = { Name = "${var.resource_prefix}-${each.key}-logs" }
}
