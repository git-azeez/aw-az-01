locals {
  database_url = "postgres://${var.db_username}:${urlencode(var.db_password)}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.valkey.primary_endpoint_address, aws_elasticache_replication_group.valkey.configuration_endpoint_address)
  valkey_port  = aws_elasticache_replication_group.valkey.port
  valkey_url   = "redis://${local.valkey_host}:${local.valkey_port}"

  endpoint_host = regex("^[a-z]+://([^:/]+)", var.aws_endpoint_url)[0]
  service_url   = "http://${local.endpoint_host}:80"

  issuer_url = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}"
  jwks_url   = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  audiences  = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.this[k].id])

  base_env = {
    AWS_REGION            = var.region
    AWS_DEFAULT_REGION    = var.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = var.aws_endpoint_url
  }

  api_env = merge(local.base_env, {
    PORT                 = "8080"
    DATABASE_URL         = local.database_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CACHE_TTL_SECONDS    = "90"
    AUTH_ISSUER          = local.issuer_url
    AUTH_AUDIENCES       = local.audiences
    AUTH_JWKS_URL        = local.jwks_url
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["api"].name
  })

  projector_env = merge(local.base_env, {
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
  })

  relay_env = merge(local.base_env, {
    DATABASE_URL         = local.database_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    OUTBOX_BATCH_SIZE    = "50"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
  })

  archiver_env = merge(local.base_env, {
    DATABASE_URL         = local.database_url
    AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
    AUDIT_PREFIX         = "ledger-audit/"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
  })
}

# ---------------------------------------------------------------- ALB ----
resource "aws_lb" "api" {
  name               = "${local.p}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  tags = { Name = "${local.p}-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${local.p}-api-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 5

  health_check {
    enabled             = true
    path                = "/health/ready"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.p}-api-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = { Name = "${local.p}-http" }
}

# ---------------------------------------------------------------- ECS ----
resource "aws_ecs_cluster" "main" {
  name = "${local.p}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.p}-cluster" }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.p}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.this["ecs_execution"].arn
  task_role_arn            = aws_iam_role.this["ecs_task"].arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = var.api_image
    essential = true
    portMappings = [{
      containerPort = 8080
      hostPort      = 8080
      protocol      = "tcp"
    }]
    environment = [for k in sort(keys(local.api_env)) : { name = k, value = local.api_env[k] }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this["api"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
  }])

  tags = { Name = "${local.p}-api", ImageId = var.api_image_id }

  lifecycle {
    # The emulator does not persist task-definition tags.
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecs_service" "api" {
  name                              = "${local.p}-api"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.api.arn
  launch_type                       = "FARGATE"
  desired_count                     = 2
  wait_for_steady_state             = false

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

  tags = { Name = "${local.p}-api" }

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.this]
}

# ------------------------------------------------------------- Lambda ----
resource "aws_lambda_function" "projector" {
  function_name = local.fn_names["projector"]
  package_type  = "Image"
  image_uri     = var.projector_image
  role          = aws_iam_role.this["projector"].arn
  timeout       = 3
  memory_size   = 512

  environment {
    variables = local.projector_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["projector"].name
  }

  tags = { Name = local.fn_names["projector"], ImageId = var.projector_image_id }

  lifecycle {
    ignore_changes = [image_config]
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_lambda_function" "relay" {
  function_name = local.fn_names["relay"]
  package_type  = "Image"
  image_uri     = var.relay_image
  role          = aws_iam_role.this["relay"].arn
  timeout       = 60
  memory_size   = 512

  environment {
    variables = local.relay_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["relay"].name
  }

  tags = { Name = local.fn_names["relay"], ImageId = var.relay_image_id }

  lifecycle {
    ignore_changes = [image_config]
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_lambda_function" "archiver" {
  function_name = local.fn_names["archiver"]
  package_type  = "Image"
  image_uri     = var.archiver_image
  role          = aws_iam_role.this["archiver"].arn
  timeout       = 120
  memory_size   = 512

  environment {
    variables = local.archiver_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["archiver"].name
  }

  tags = { Name = local.fn_names["archiver"], ImageId = var.archiver_image_id }

  lifecycle {
    ignore_changes = [image_config]
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  tags = { Name = "${local.p}-projector-esm" }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

# ---------------------------------------------------------- Scheduler ----
resource "aws_scheduler_schedule" "outbox" {
  name        = "${local.p}-outbox-relay"
  group_name  = "default"
  description = "Relay committed outbox rows to SQS every minute"
  state       = "ENABLED"

  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.this["scheduler"].arn
    input    = jsonencode({ source = "scheduler", job = "outbox-relay" })
  }
}

resource "aws_scheduler_schedule" "archive" {
  name        = "${local.p}-audit-archiver"
  group_name  = "default"
  description = "Archive published settlement events to S3 every five minutes"
  state       = "ENABLED"

  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.this["scheduler"].arn
    input    = jsonencode({ source = "scheduler", job = "audit-archiver" })
  }
}

# ------------------------------------------------------------ Cognito ----
resource "aws_cognito_user_pool" "main" {
  name = "${local.p}-users"

  tags = { Name = "${local.p}-users" }
}

resource "aws_cognito_resource_server" "clearledger" {
  user_pool_id = aws_cognito_user_pool.main.id
  identifier   = "clearledger"
  name         = "${local.p}-clearledger-api"

  scope {
    scope_name        = "read"
    scope_description = "Read settlement projections and ledgers"
  }
  scope {
    scope_name        = "write"
    scope_description = "Initiate settlements and append ledger entries"
  }
  scope {
    scope_name        = "admin"
    scope_description = "Rebuild settlement projections"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  for_each = toset(["read", "write", "admin"])

  name                                 = "${local.p}-${each.key}-client"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/${each.key}"]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  depends_on = [aws_cognito_resource_server.clearledger]
}
