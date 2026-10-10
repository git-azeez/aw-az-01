locals {
  db_url = format(
    "postgres://%s:%s@%s:%d/%s",
    urlencode(local.cfg.db_username),
    urlencode(local.cfg.db_password),
    aws_db_instance.main.address,
    aws_db_instance.main.port,
    local.cfg.db_name,
  )

  valkey_host = coalesce(aws_elasticache_replication_group.main.primary_endpoint_address, aws_elasticache_replication_group.main.configuration_endpoint_address)
  valkey_port = aws_elasticache_replication_group.main.port
  valkey_url  = "redis://${local.valkey_host}:${local.valkey_port}"

  issuer_url = "${local.endpoint}/${aws_cognito_user_pool.main.id}"
  jwks_url   = "${local.endpoint}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"

  worker_base_env = {
    AWS_REGION            = local.region
    AWS_DEFAULT_REGION    = local.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.endpoint
  }
}

# ---------------------------------------------------------------------------
# Lambda workers
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  role          = aws_iam_role.this["projector"].arn
  package_type  = "Image"
  image_uri     = local.cfg.projector_image
  timeout       = 3
  memory_size   = 256
  architectures = ["x86_64"]

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = merge(local.worker_base_env, {
      PROJECTION_TABLE     = aws_dynamodb_table.projections.name
      VALKEY_URL           = local.valkey_url
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["projector"].name
  }

  tags = merge(local.tags, { Name = "${local.prefix}-projector", ClearLedgerWorkload = "projector" })
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  role          = aws_iam_role.this["relay"].arn
  package_type  = "Image"
  image_uri     = local.cfg.relay_image
  timeout       = 60
  memory_size   = 256
  architectures = ["x86_64"]

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = merge(local.worker_base_env, {
      DATABASE_URL         = local.db_url
      SQS_QUEUE_URL        = aws_sqs_queue.main.url
      OUTBOX_BATCH_SIZE    = "50"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["relay"].name
  }

  tags = merge(local.tags, { Name = "${local.prefix}-outbox-relay", ClearLedgerWorkload = "relay" })
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  role          = aws_iam_role.this["archiver"].arn
  package_type  = "Image"
  image_uri     = local.cfg.archiver_image
  timeout       = 60
  memory_size   = 256
  architectures = ["x86_64"]

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = merge(local.worker_base_env, {
      DATABASE_URL         = local.db_url
      AUDIT_BUCKET         = aws_s3_bucket.audit.id
      AUDIT_PREFIX         = "ledger-audit/"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["archiver"].name
  }

  tags = merge(local.tags, { Name = "${local.prefix}-audit-archiver", ClearLedgerWorkload = "archiver" })
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  tags = local.tags

  lifecycle {
    # The local control plane does not persist event source mapping tags.
    ignore_changes = [tags, tags_all]
  }
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.prefix}-outbox-relay"
  description         = "ClearLedger outbox relay tick"
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.this["scheduler"].arn
    input    = jsonencode({ source = "clearledger.scheduler", job = "outbox-relay" })
  }
}

resource "aws_scheduler_schedule" "archive" {
  name                = "${local.prefix}-audit-archiver"
  description         = "ClearLedger audit archive batch"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.this["scheduler"].arn
    input    = jsonencode({ source = "clearledger.scheduler", job = "audit-archiver" })
  }
}

# ---------------------------------------------------------------------------
# Cognito OAuth2 (client credentials, non-hierarchical scopes)
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"

  tags = merge(local.tags, { Name = "${local.prefix}-users" })
}

resource "aws_cognito_resource_server" "main" {
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger"
  user_pool_id = aws_cognito_user_pool.main.id

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

locals {
  client_scopes = {
    read  = "clearledger/read"
    write = "clearledger/write"
    admin = "clearledger/admin"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  for_each = local.client_scopes

  name                                 = "${local.prefix}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [each.value]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  depends_on = [aws_cognito_resource_server.main]
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${local.prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 60

  tags = merge(local.tags, { Name = "${local.prefix}-alb" })
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
  execution_role_arn       = aws_iam_role.this["ecs_execution"].arn
  task_role_arn            = aws_iam_role.this["ecs_task"].arn

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
      environment = [
        for k, v in {
          PORT                  = "8080"
          AWS_REGION            = local.region
          AWS_DEFAULT_REGION    = local.region
          AWS_ACCESS_KEY_ID     = "test"
          AWS_SECRET_ACCESS_KEY = "test"
          AWS_ENDPOINT_URL      = local.endpoint
          DATABASE_URL          = local.db_url
          SQS_QUEUE_URL         = aws_sqs_queue.main.url
          PROJECTION_TABLE      = aws_dynamodb_table.projections.name
          VALKEY_URL            = local.valkey_url
          CACHE_TTL_SECONDS     = "90"
          AUTH_ISSUER           = local.issuer_url
          AUTH_AUDIENCES        = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.this[k].id])
          AUTH_JWKS_URL         = local.jwks_url
          CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.this["api"].name
        } : { name = k, value = v }
      ]
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
    # The local control plane does not persist task definition tags.
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecs_service" "api" {
  name            = "${local.prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  launch_type     = "FARGATE"
  desired_count   = 2

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

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.this]
}
