resource "aws_cloudwatch_log_group" "api" {
  name              = "/clearledger/${local.prefix}/api"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "projector" {
  name              = "/clearledger/${local.prefix}/projector"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "relay" {
  name              = "/clearledger/${local.prefix}/outbox-relay"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "archiver" {
  name              = "/clearledger/${local.prefix}/audit-archiver"
  retention_in_days = 14
  tags              = local.tags
}
