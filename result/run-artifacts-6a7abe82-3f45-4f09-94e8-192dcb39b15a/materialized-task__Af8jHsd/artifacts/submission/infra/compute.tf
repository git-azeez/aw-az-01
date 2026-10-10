# ---------------------------------------------------------------------------
# CloudWatch Log Groups
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.log_group_names
  name              = each.value
  retention_in_days = 14
  tags              = merge(local.tags, { Name = each.value })
}

# ---------------------------------------------------------------------------
# Cognito
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"
  tags = merge(local.tags, { Name = "${local.prefix}-users" })
}

resource "aws_cognito_resource_server" "clearledger" {
  user_pool_id = aws_cognito_user_pool.main.id
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger"

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
    scope_description = "Administrative projection rebuilds"
  }
}

locals {
  client_scopes = {
    read  = "clearledger/read"
    write = "clearledger/write"
    admin = "clearledger/admin"
  }
}

resource "aws_cognito_user_pool_client" "client" {
  for_each                             = local.client_scopes
  name                                 = "${local.prefix}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [each.value]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  depends_on = [aws_cognito_resource_server.clearledger]
}

locals {
  issuer_url     = "${local.endpoint}/${aws_cognito_user_pool.main.id}"
  jwks_url       = "${local.endpoint}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  token_endpoint = "${local.endpoint}/cognito-idp/oauth2/token"
  audiences      = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.client[k].id])

  db_host      = aws_db_instance.main.address
  db_port      = aws_db_instance.main.port
  database_url = "postgres://${local.cfg.db_username}:${local.cfg.db_password}@${local.db_host}:${local.db_port}/${local.cfg.db_name}"

  valkey_host = coalesce(aws_elasticache_replication_group.valkey.primary_endpoint_address, aws_elasticache_replication_group.valkey.configuration_endpoint_address, "aws")
  valkey_port = coalesce(aws_elasticache_replication_group.valkey.port, 6379)
  valkey_url  = "redis://${local.valkey_host}:${local.valkey_port}"

  base_env = {
    AWS_REGION            = local.region
    AWS_DEFAULT_REGION    = local.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.endpoint
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
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${local.prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  tags               = merge(local.tags, { Name = "${local.prefix}-alb" })
}

resource "aws_lb_target_group" "api" {
  name                 = "${local.prefix}-api"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 5

  health_check {
    enabled             = true
    path                = "/health/ready"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 5
    timeout             = 2
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.tags, { Name = "${local.prefix}-api" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = merge(local.tags, { Name = "${local.prefix}-http" })
}

# ---------------------------------------------------------------------------
# ECS Fargate API service
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.tags, { Name = "${local.prefix}-cluster" })
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.role["ecs_execution"].arn
  task_role_arn            = aws_iam_role.role["ecs_task"].arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = local.cfg.api_image
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
          awslogs-region        = local.region
          awslogs-stream-prefix = "api"
        }
      }
    }
  ])

  tags = merge(local.tags, { Name = "${local.prefix}-api" })

  lifecycle {
    create_before_destroy = true
    # The control plane does not echo task definition tags on describe.
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecs_service" "api" {
  name                               = "${local.prefix}-api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = 2
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  wait_for_steady_state              = false

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

  tags = merge(local.tags, { Name = "${local.prefix}-api" })

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.role]
}

# ---------------------------------------------------------------------------
# Lambda workers
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "projector" {
  function_name = local.lambda_names.projector
  package_type  = "Image"
  image_uri     = local.cfg.projector_image
  role          = aws_iam_role.role["projector"].arn
  timeout       = 3
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = merge(local.base_env, {
      PROJECTION_TABLE     = aws_dynamodb_table.projections.name
      VALKEY_URL           = local.valkey_url
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
    })
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-projector" })
  depends_on = [aws_iam_role_policy.role, aws_cloudwatch_log_group.this]
}

resource "aws_lambda_function" "relay" {
  function_name = local.lambda_names.relay
  package_type  = "Image"
  image_uri     = local.cfg.relay_image
  role          = aws_iam_role.role["relay"].arn
  timeout       = 60
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = merge(local.base_env, {
      DATABASE_URL         = local.database_url
      SQS_QUEUE_URL        = aws_sqs_queue.main.url
      OUTBOX_BATCH_SIZE    = "50"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
    })
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-outbox-relay" })
  depends_on = [aws_iam_role_policy.role, aws_cloudwatch_log_group.this]
}

resource "aws_lambda_function" "archiver" {
  function_name = local.lambda_names.archiver
  package_type  = "Image"
  image_uri     = local.cfg.archiver_image
  role          = aws_iam_role.role["archiver"].arn
  timeout       = 120
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = merge(local.base_env, {
      DATABASE_URL         = local.database_url
      AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX         = "ledger-audit/"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
    })
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-audit-archiver" })
  depends_on = [aws_iam_role_policy.role, aws_cloudwatch_log_group.this]
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  tags = merge(local.tags, { Name = "${local.prefix}-projector-esm" })

  depends_on = [aws_sqs_queue_policy.main]

  lifecycle {
    # Event source mapping tags are not readable through ListTags locally.
    ignore_changes = [tags, tags_all]
  }
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler
# ---------------------------------------------------------------------------
resource "aws_scheduler_schedule" "relay" {
  name                = "${local.prefix}-outbox-relay"
  group_name          = "default"
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.role["scheduler"].arn
  }

  depends_on = [aws_iam_role_policy.role]
}

resource "aws_scheduler_schedule" "archiver" {
  name                = "${local.prefix}-audit-archiver"
  group_name          = "default"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.role["scheduler"].arn
  }

  depends_on = [aws_iam_role_policy.role]
}
