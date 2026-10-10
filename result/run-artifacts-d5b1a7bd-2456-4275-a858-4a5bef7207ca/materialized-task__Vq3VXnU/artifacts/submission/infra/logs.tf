resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups

  name              = each.value
  retention_in_days = 14

  tags = { Name = "${local.p}-${each.key}-logs", Workload = each.key }
}
