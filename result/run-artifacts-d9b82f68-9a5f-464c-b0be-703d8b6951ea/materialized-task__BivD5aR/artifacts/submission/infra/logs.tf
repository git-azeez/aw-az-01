locals {
  log_groups = {
    api       = "/clearledger/${local.prefix}/api"
    projector = "/clearledger/${local.prefix}/projector"
    relay     = "/clearledger/${local.prefix}/outbox-relay"
    archiver  = "/clearledger/${local.prefix}/audit-archiver"
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.log_groups
  name              = each.value
  retention_in_days = 14
  tags              = { Name = "${local.prefix}-${each.key}-logs" }
}
