# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "api" {
  name               = "${local.p}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  tags               = { Name = "${local.p}-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${local.p}-api-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health/ready"
    protocol            = "HTTP"
    matcher             = "200"
    port                = "traffic-port"
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

# ---------------------------------------------------------------------------
# ECS Fargate API service
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = "${local.p}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.p}-cluster" }
}

locals {
  common_worker_env = {
    AWS_REGION            = var.region
    AWS_DEFAULT_REGION    = var.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = var.container_aws_endpoint_url
  }

  api_env = merge(local.common_worker_env, {
    PORT                 = "8080"
    DATABASE_URL         = local.database_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CACHE_TTL_SECONDS    = "90"
    AUTH_ISSUER          = local.issuer_url
    AUTH_AUDIENCES       = join(",", [aws_cognito_user_pool_client.read.id, aws_cognito_user_pool_client.write.id, aws_cognito_user_pool_client.admin.id])
    AUTH_JWKS_URL        = local.jwks_url
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["api"].name
  })
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.p}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.this["ecs_execution"].arn
  task_role_arn            = aws_iam_role.this["ecs_task"].arn

  container_definitions = jsonencode([
    {
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
    }
  ])

  tags = { Name = "${local.p}-api" }
}

resource "aws_ecs_service" "api" {
  name            = "${local.p}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  launch_type     = "FARGATE"
  desired_count   = 2

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

  wait_for_steady_state = false

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.this]

  tags = { Name = "${local.p}-api" }
}

# ---------------------------------------------------------------------------
# Lambda workers
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "projector" {
  function_name = "${local.p}-projector"
  package_type  = "Image"
  image_uri     = var.projector_image
  role          = aws_iam_role.this["projector"].arn
  timeout       = 30
  memory_size   = 256

  environment {
    variables = merge(local.common_worker_env, {
      PROJECTION_TABLE     = aws_dynamodb_table.projections.name
      VALKEY_URL           = local.valkey_url
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["projector"].name
  }

  depends_on = [aws_iam_role_policy.this]
  tags       = { Name = "${local.p}-projector" }
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.p}-outbox-relay"
  package_type  = "Image"
  image_uri     = var.relay_image
  role          = aws_iam_role.this["relay"].arn
  timeout       = 60
  memory_size   = 256

  environment {
    variables = merge(local.common_worker_env, {
      DATABASE_URL         = local.database_url
      SQS_QUEUE_URL        = aws_sqs_queue.main.url
      OUTBOX_BATCH_SIZE    = "50"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["relay"].name
  }

  depends_on = [aws_iam_role_policy.this]
  tags       = { Name = "${local.p}-outbox-relay" }
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.p}-audit-archiver"
  package_type  = "Image"
  image_uri     = var.archiver_image
  role          = aws_iam_role.this["archiver"].arn
  timeout       = 60
  memory_size   = 256

  environment {
    variables = merge(local.common_worker_env, {
      DATABASE_URL         = local.database_url
      AUDIT_BUCKET         = aws_s3_bucket.audit.id
      AUDIT_PREFIX         = "ledger-audit/"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["archiver"].name
  }

  depends_on = [aws_iam_role_policy.this]
  tags       = { Name = "${local.p}-audit-archiver" }
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler
# ---------------------------------------------------------------------------
resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.p}-outbox-relay"
  state               = "ENABLED"
  schedule_expression = "rate(1 minute)"

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
  name                = "${local.p}-audit-archiver"
  state               = "ENABLED"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.this["scheduler"].arn
    input    = jsonencode({ source = "clearledger.scheduler", job = "audit-archiver" })
  }
}
