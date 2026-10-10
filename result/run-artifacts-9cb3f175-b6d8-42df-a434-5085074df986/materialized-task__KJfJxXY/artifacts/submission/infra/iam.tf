locals {
  roles = {
    ecs_execution = { service = "ecs-tasks.amazonaws.com", name = "ecs-execution" }
    ecs_task      = { service = "ecs-tasks.amazonaws.com", name = "ecs-task" }
    projector     = { service = "lambda.amazonaws.com", name = "projector" }
    relay         = { service = "lambda.amazonaws.com", name = "relay" }
    archiver      = { service = "lambda.amazonaws.com", name = "archiver" }
    scheduler     = { service = "scheduler.amazonaws.com", name = "scheduler" }
  }

  key_arn = { for k in local.kms_usages : k => aws_kms_key.this[k].arn }
  lg_arn  = { for k, v in aws_cloudwatch_log_group.this : k => v.arn }

  q_arn     = aws_sqs_queue.main.arn
  dlq_arn   = aws_sqs_queue.dlq.arn
  tbl_arn   = aws_dynamodb_table.projections.arn
  gsi_arn   = "${aws_dynamodb_table.projections.arn}/index/AccountIndex"
  bkt_arn   = aws_s3_bucket.audit.arn
  bkt_all   = "${aws_s3_bucket.audit.arn}/*"
  bkt_audit = "${aws_s3_bucket.audit.arn}/ledger-audit/*"

  fn_arn = {
    projector = aws_lambda_function.projector.arn
    relay     = aws_lambda_function.relay.arn
    archiver  = aws_lambda_function.archiver.arn
  }

  log_actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
  kms_use     = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  kms_deny    = ["kms:Decrypt", "kms:GenerateDataKey"]

  # A log group's ARN plus its stream sub-resources.
  lg_res = { for k, v in local.lg_arn : k => [v, "${v}:*"] }

  all_keys    = [for k in local.kms_usages : local.key_arn[k]]
  key_res     = { for k in local.kms_usages : k => [local.key_arn[k]] }
  deny_keys_x = { for k in local.kms_usages : k => [for o in local.kms_usages : local.key_arn[o] if o != k] }

  # ---- guardrails shared by every role: nobody may disable / delete the keys
  deny_key_lifecycle = {
    Sid      = "DenyKeyLifecycle"
    Effect   = "Deny"
    Action   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    Resource = local.all_keys
  }

  s3_deny_actions  = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  ddb_deny_actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
  ddb_res          = [local.tbl_arn, local.gsi_arn]
  s3_res           = [local.bkt_arn, local.bkt_all]
  sqs_res_both     = [local.q_arn, local.dlq_arn]
  sqs_all_actions  = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]

  # ---- per-role statements
  policies = {
    ecs_execution = [
      {
        Sid      = "OwnLogGroupWrite"
        Effect   = "Allow"
        Action   = concat(local.log_actions, ["logs:DescribeLogStreams"])
        Resource = local.lg_res.api
      },
      local.deny_key_lifecycle,
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.sqs_res_both },
      { Sid = "DenyDynamo", Effect = "Deny", Action = local.ddb_deny_actions, Resource = local.ddb_res },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_deny_actions, Resource = local.s3_res },
      { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny, Resource = local.all_keys },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_actions, Resource = concat(local.lg_res.projector, local.lg_res.relay, local.lg_res.archiver) },
    ]

    ecs_task = [
      {
        Sid      = "PublishOnly"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "ReadProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"]
        Resource = local.ddb_res
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.key_arn.messaging, local.key_arn.projection]
      },
      {
        Sid      = "OwnLogGroupWrite"
        Effect   = "Allow"
        Action   = concat(local.log_actions, ["logs:DescribeLogStreams"])
        Resource = local.lg_res.api
      },
      local.deny_key_lifecycle,
      { Sid = "DenyConsumeMain", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.q_arn] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_actions, Resource = [local.dlq_arn] },
      { Sid = "DenyDynamoMutation", Effect = "Deny", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.tbl_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_deny_actions, Resource = local.s3_res },
      { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny, Resource = [local.key_arn.database, local.key_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_actions, Resource = concat(local.lg_res.projector, local.lg_res.relay, local.lg_res.archiver) },
    ]

    projector = [
      {
        Sid      = "ConsumeMain"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "ForwardToDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [local.dlq_arn]
      },
      {
        Sid      = "UpsertProjections"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = local.ddb_res
      },
      {
        Sid      = "UseMessagingAndProjectionKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.key_arn.messaging, local.key_arn.projection]
      },
      {
        Sid      = "OwnLogGroupWrite"
        Effect   = "Allow"
        Action   = concat(local.log_actions, ["logs:DescribeLogStreams"])
        Resource = local.lg_res.projector
      },
      local.deny_key_lifecycle,
      { Sid = "DenyMainSend", Effect = "Deny", Action = ["sqs:SendMessage"], Resource = [local.q_arn] },
      { Sid = "DenyDlqConsume", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.dlq_arn] },
      { Sid = "DenyDynamoDelete", Effect = "Deny", Action = ["dynamodb:DeleteItem", "dynamodb:DeleteTable"], Resource = [local.tbl_arn] },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_deny_actions, Resource = local.s3_res },
      { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny, Resource = [local.key_arn.database, local.key_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_actions, Resource = concat(local.lg_res.api, local.lg_res.relay, local.lg_res.archiver) },
    ]

    relay = [
      {
        Sid      = "PublishOnly"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [local.q_arn]
      },
      {
        Sid      = "UseMessagingAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.key_arn.messaging, local.key_arn.database]
      },
      {
        Sid      = "OwnLogGroupWrite"
        Effect   = "Allow"
        Action   = concat(local.log_actions, ["logs:DescribeLogStreams"])
        Resource = local.lg_res.relay
      },
      local.deny_key_lifecycle,
      { Sid = "DenyConsumeMain", Effect = "Deny", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = [local.q_arn] },
      { Sid = "DenyDlq", Effect = "Deny", Action = local.sqs_all_actions, Resource = [local.dlq_arn] },
      { Sid = "DenyDynamo", Effect = "Deny", Action = local.ddb_deny_actions, Resource = local.ddb_res },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_deny_actions, Resource = local.s3_res },
      { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny, Resource = [local.key_arn.projection, local.key_arn.audit] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_actions, Resource = concat(local.lg_res.api, local.lg_res.projector, local.lg_res.archiver) },
    ]

    archiver = [
      {
        Sid      = "AuditObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = [local.bkt_audit]
      },
      {
        Sid      = "AuditBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [local.bkt_arn]
      },
      {
        Sid      = "UseAuditAndDatabaseKeys"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [local.key_arn.audit, local.key_arn.database]
      },
      {
        Sid      = "OwnLogGroupWrite"
        Effect   = "Allow"
        Action   = concat(local.log_actions, ["logs:DescribeLogStreams"])
        Resource = local.lg_res.archiver
      },
      local.deny_key_lifecycle,
      { Sid = "DenyS3Delete", Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.s3_res },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.sqs_res_both },
      { Sid = "DenyDynamo", Effect = "Deny", Action = local.ddb_deny_actions, Resource = local.ddb_res },
      { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny, Resource = [local.key_arn.messaging, local.key_arn.projection] },
      { Sid = "DenyForeignLogs", Effect = "Deny", Action = local.log_actions, Resource = concat(local.lg_res.api, local.lg_res.projector, local.lg_res.relay) },
    ]

    scheduler = [
      {
        Sid      = "InvokeWorkers"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.fn_arn.relay, local.fn_arn.archiver]
      },
      local.deny_key_lifecycle,
      { Sid = "DenyProjectorInvoke", Effect = "Deny", Action = ["lambda:InvokeFunction"], Resource = [local.fn_arn.projector] },
      { Sid = "DenySqs", Effect = "Deny", Action = local.sqs_all_actions, Resource = local.sqs_res_both },
      { Sid = "DenyDynamo", Effect = "Deny", Action = local.ddb_deny_actions, Resource = local.ddb_res },
      { Sid = "DenyS3", Effect = "Deny", Action = local.s3_deny_actions, Resource = local.s3_res },
      { Sid = "DenyKmsUse", Effect = "Deny", Action = local.kms_deny, Resource = local.all_keys },
      { Sid = "DenyLogs", Effect = "Deny", Action = local.log_actions, Resource = concat(local.lg_res.api, local.lg_res.projector, local.lg_res.relay, local.lg_res.archiver) },
    ]
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name = "${local.prefix}-${each.value.name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = each.value.service }
    }]
  })

  tags = merge(local.tags, { ClearLedgerRole = each.key, Name = "${local.prefix}-${each.value.name}" })
}

resource "aws_iam_role_policy" "this" {
  for_each = local.roles

  name = "${local.prefix}-${each.value.name}-policy"
  role = aws_iam_role.this[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policies[each.key]
  })
}
