resource "aws_cloudwatch_log_group" "api" {
  name              = local.api_log_group
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "projector" {
  name              = local.projector_log_group
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "relay" {
  name              = local.relay_log_group
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "archiver" {
  name              = local.archiver_log_group
  retention_in_days = 14
  tags              = local.tags
}
