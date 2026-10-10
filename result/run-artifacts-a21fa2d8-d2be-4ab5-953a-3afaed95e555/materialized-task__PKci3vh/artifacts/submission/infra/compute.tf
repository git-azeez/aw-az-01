resource "aws_cognito_user_pool" "auth" {
  name = "${local.prefix}-auth"
}
resource "aws_cognito_resource_server" "auth" {
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger"
  user_pool_id = aws_cognito_user_pool.auth.id
  dynamic "scope" {
    for_each = toset(["read", "write", "admin"])
    content {
      scope_name        = scope.value
      scope_description = "ClearLedger ${scope.value}"
    }
  }
}
resource "aws_cognito_user_pool_client" "client" {
  for_each                             = toset(["read", "write", "admin"])
  name                                 = "${local.prefix}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.auth.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.auth.identifier}/${each.key}"]
}
locals {
  database_url = "postgres://${urlencode(local.config.db_username)}:${urlencode(local.config.db_password)}@${aws_db_instance.db.address}:${aws_db_instance.db.port}/${local.config.db_name}"
  cache_host   = coalesce(aws_elasticache_replication_group.cache.primary_endpoint_address, aws_elasticache_replication_group.cache.configuration_endpoint_address)
  valkey_url   = "redis://${local.cache_host}:6379"
  common_env = {
    AWS_REGION        = local.region, AWS_DEFAULT_REGION = local.region,
    AWS_ACCESS_KEY_ID = "test", AWS_SECRET_ACCESS_KEY = "test", AWS_ENDPOINT_URL = local.endpoint
  }
  worker_env = {
    projector = { PROJECTION_TABLE = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url }
    relay     = { DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.events.url, OUTBOX_BATCH_SIZE = "50" }
    archiver  = { DATABASE_URL = local.database_url, AUDIT_BUCKET = aws_s3_bucket.audit.id, AUDIT_PREFIX = "ledger-audit/" }
  }
  api_env = merge(local.common_env, {
    PORT                 = "8080", DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.events.url,
    PROJECTION_TABLE     = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url, CACHE_TTL_SECONDS = "90",
    AUTH_ISSUER          = "${local.endpoint}/${aws_cognito_user_pool.auth.id}",
    AUTH_JWKS_URL        = "${local.endpoint}/${aws_cognito_user_pool.auth.id}/.well-known/jwks.json",
    AUTH_AUDIENCES       = join(",", [for scope in ["read", "write", "admin"] : aws_cognito_user_pool_client.client[scope].id]),
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.log["api"].name
  })
}
resource "aws_lambda_function" "worker" {
  for_each         = toset(["projector", "relay", "archiver"])
  function_name    = "${local.prefix}-${each.key}"
  role             = aws_iam_role.role[each.key].arn
  package_type     = "Image"
  image_uri        = local.config["${each.key}_image"]
  source_code_hash = local.config["${each.key}_image_id"]
  timeout          = 3
  memory_size      = 256
  image_config {
    command     = []
    entry_point = []
  }
  environment {
    variables = sensitive(merge(local.common_env, local.worker_env[each.key], { CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.log[each.key].name }))
  }
}
resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.worker["projector"].arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
  depends_on                         = [aws_iam_role_policy.policy]
}
resource "aws_scheduler_schedule" "worker" {
  for_each            = { relay = "rate(1 minute)", archiver = "rate(5 minutes)" }
  name                = "${local.prefix}-${each.key}"
  state               = "ENABLED"
  schedule_expression = each.value
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.worker[each.key].arn
    role_arn = aws_iam_role.role["scheduler"].arn
    input    = "{}"
  }
}
resource "aws_ecs_cluster" "api" {
  name = "${local.prefix}-api"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.role["ecs_execution"].arn
  task_role_arn            = aws_iam_role.role["ecs_task"].arn
  container_definitions = sensitive(jsonencode([{
    name         = "api", image = local.config.api_image, essential = true,
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }],
    environment  = [for k, v in local.api_env : { name = k, value = v }],
    logConfiguration = { logDriver = "awslogs", options = {
      awslogs-group  = aws_cloudwatch_log_group.log["api"].name,
      awslogs-region = local.region, awslogs-stream-prefix = "api"
    } }
  }]))
  lifecycle { create_before_destroy = true }
}
resource "aws_ecs_service" "api" {
  name                               = "${local.prefix}-api"
  cluster                            = aws_ecs_cluster.api.id
  task_definition                    = aws_ecs_task_definition.api.arn
  launch_type                        = "FARGATE"
  desired_count                      = 2
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener.http, aws_iam_role_policy.policy]
}
