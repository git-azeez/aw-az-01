locals {
  database_url = "postgres://${urlencode(local.c.db_username)}:${urlencode(local.c.db_password)}@${aws_db_instance.db.address}:${aws_db_instance.db.port}/${local.c.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.cache.primary_endpoint_address, aws_elasticache_replication_group.cache.configuration_endpoint_address)
  valkey_url   = "redis://${local.valkey_host}:6379"
  common_env = {
    AWS_REGION        = local.region, AWS_DEFAULT_REGION = local.region,
    AWS_ACCESS_KEY_ID = "test", AWS_SECRET_ACCESS_KEY = "test", AWS_ENDPOINT_URL = local.endpoint
  }
  worker_env = {
    projector = { PROJECTION_TABLE = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url }
    relay     = { DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.events.url, OUTBOX_BATCH_SIZE = "50" }
    archiver  = { DATABASE_URL = local.database_url, AUDIT_BUCKET = aws_s3_bucket.audit.id, AUDIT_PREFIX = "ledger-audit/" }
  }
}
resource "aws_lambda_function" "workers" {
  for_each      = toset(["projector", "relay", "archiver"])
  function_name = "${local.p}-${each.key}"
  package_type  = "Image"
  image_uri     = local.c["${each.key}_image"]
  role          = aws_iam_role.roles[each.key].arn
  timeout       = 3
  memory_size   = 256
  image_config {
    command     = []
    entry_point = []
  }
  environment { variables = sensitive(merge(local.common_env, local.worker_env[each.key], { CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.logs[each.key].name })) }
  depends_on = [aws_iam_role_policy.canonical]
}
resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.workers["projector"].arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
}
resource "aws_scheduler_schedule" "workers" {
  for_each            = { relay = "rate(1 minute)", archiver = "rate(5 minutes)" }
  name                = "${local.p}-${each.key}"
  state               = "ENABLED"
  schedule_expression = each.value
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.workers[each.key].arn
    role_arn = aws_iam_role.roles["scheduler"].arn
    input    = "{}"
  }
}
resource "aws_lb" "api" {
  name               = "${local.p}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}
resource "aws_lb_target_group" "api" {
  name                 = "${local.p}-api"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 5
  health_check {
    path              = "/health/ready"
    protocol          = "HTTP"
    matcher           = "200"
    interval          = 5
    timeout           = 2
    healthy_threshold = 2
  }
}
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
resource "aws_ecs_cluster" "api" {
  name = "${local.p}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_ecs_task_definition" "api" {
  lifecycle { create_before_destroy = true }
  family                   = "${local.p}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.roles["ecs_execution"].arn
  task_role_arn            = aws_iam_role.roles["ecs_task"].arn
  container_definitions = sensitive(jsonencode([{
    name         = "api", image = local.c.api_image, essential = true,
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }],
    environment = [for k, v in merge(local.common_env, {
      PORT                 = "8080", DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.events.url,
      PROJECTION_TABLE     = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url, CACHE_TTL_SECONDS = "90",
      AUTH_ISSUER          = "${local.endpoint}/${aws_cognito_user_pool.auth.id}",
      AUTH_JWKS_URL        = "${local.endpoint}/${aws_cognito_user_pool.auth.id}/.well-known/jwks.json",
      AUTH_AUDIENCES       = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.clients[k].id]),
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.logs["api"].name
    }) : { name = k, value = v }],
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.logs["api"].name, awslogs-region = local.region, awslogs-stream-prefix = "api" } }
  }]))
}
resource "aws_ecs_service" "api" {
  name            = "${local.p}-api"
  cluster         = aws_ecs_cluster.api.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2
  launch_type     = "FARGATE"
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
  depends_on = [aws_lb_listener.api, aws_iam_role_policy.canonical]
}
