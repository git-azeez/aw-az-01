# Authoritative policy sets: any inline policy or managed-policy attachment
# added to a ClearLedger workload role outside Terraform is removed on apply.

locals {
  workload_roles = {
    ecs_execution = { role = aws_iam_role.ecs_execution.name, policy = aws_iam_role_policy.ecs_execution.name }
    ecs_task      = { role = aws_iam_role.ecs_task.name, policy = aws_iam_role_policy.ecs_task.name }
    projector     = { role = aws_iam_role.projector.name, policy = aws_iam_role_policy.projector.name }
    relay         = { role = aws_iam_role.relay.name, policy = aws_iam_role_policy.relay.name }
    archiver      = { role = aws_iam_role.archiver.name, policy = aws_iam_role_policy.archiver.name }
    scheduler     = { role = aws_iam_role.scheduler.name, policy = aws_iam_role_policy.scheduler.name }
  }
}

resource "aws_iam_role_policies_exclusive" "this" {
  for_each = local.workload_roles

  role_name    = each.value.role
  policy_names = [each.value.policy]
}

resource "aws_iam_role_policy_attachments_exclusive" "this" {
  for_each = local.workload_roles

  role_name   = each.value.role
  policy_arns = []
}
