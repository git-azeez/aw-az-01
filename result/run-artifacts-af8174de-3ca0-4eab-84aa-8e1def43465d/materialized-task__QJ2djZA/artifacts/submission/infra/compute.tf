# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "api" {
  name               = "${local.p}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  tags               = local.tags
}

resource "aws_lb_target_group" "api" {
  name                 = "${local.p}-api-tg"
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

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = local.tags
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

  tags = local.tags
}

locals {
  api_environment = [
    { name = "PORT", value = "8080" },
    { name = "AWS_REGION", value = var.region },
    { name = "AWS_DEFAULT_REGION", value = var.region },
    { name = "AWS_ACCESS_KEY_ID", value = "test" },
    { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
    { name = "AWS_ENDPOINT_URL", value = local.container_aws_endpoint },
    { name = "DATABASE_URL", value = local.database_url },
    { name = "SQS_QUEUE_URL", value = aws_sqs_queue.main.url },
    { name = "PROJECTION_TABLE", value = aws_dynamodb_table.projections.name },
    { name = "VALKEY_URL", value = local.valkey_url },
    { name = "CACHE_TTL_SECONDS", value = "90" },
    { name = "AUTH_ISSUER", value = local.issuer_url },
    { name = "AUTH_AUDIENCES", value = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.client[k].id]) },
    { name = "AUTH_JWKS_URL", value = local.jwks_url },
    { name = "CLOUDWATCH_LOG_GROUP", value = aws_cloudwatch_log_group.lg["api"].name },
  ]
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.p}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name        = "api"
      image       = var.api_image
      essential   = true
      environment = local.api_environment
      portMappings = [
        { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.lg["api"].name
          awslogs-region        = var.region
          awslogs-stream-prefix = "api"
        }
      }
    }
  ])

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ecs_service" "api" {
  name                               = "${local.p}-api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  launch_type                        = "FARGATE"
  desired_count                      = 2
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  wait_for_steady_state              = false
  force_new_deployment               = false

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

  tags       = local.tags
  depends_on = [aws_lb_listener.http, aws_iam_role_policy.ecs_task, aws_iam_role_policy.ecs_execution]
}

# ---------------------------------------------------------------------------
# Lambda workers
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "projector" {
  function_name = "${local.p}-projector"
  package_type  = "Image"
  image_uri     = var.projector_image
  role          = aws_iam_role.projector.arn
  timeout       = 3
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = {
      AWS_REGION            = var.region
      AWS_DEFAULT_REGION    = var.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.container_aws_endpoint
      PROJECTION_TABLE      = aws_dynamodb_table.projections.name
      VALKEY_URL            = local.valkey_url
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.lg["projector"].name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lg["projector"].name
  }

  tags       = local.tags
  depends_on = [aws_iam_role_policy.projector]
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.p}-outbox-relay"
  package_type  = "Image"
  image_uri     = var.relay_image
  role          = aws_iam_role.relay.arn
  timeout       = 60
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = {
      AWS_REGION            = var.region
      AWS_DEFAULT_REGION    = var.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.container_aws_endpoint
      DATABASE_URL          = local.database_url
      SQS_QUEUE_URL         = aws_sqs_queue.main.url
      OUTBOX_BATCH_SIZE     = "50"
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.lg["relay"].name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lg["relay"].name
  }

  tags       = local.tags
  depends_on = [aws_iam_role_policy.relay]
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.p}-audit-archiver"
  package_type  = "Image"
  image_uri     = var.archiver_image
  role          = aws_iam_role.archiver.arn
  timeout       = 120
  memory_size   = 256

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = {
      AWS_REGION            = var.region
      AWS_DEFAULT_REGION    = var.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.container_aws_endpoint
      DATABASE_URL          = local.database_url
      AUDIT_BUCKET          = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX          = "ledger-audit/"
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.lg["archiver"].name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lg["archiver"].name
  }

  tags       = local.tags
  depends_on = [aws_iam_role_policy.archiver]
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
  depends_on                         = [aws_sqs_queue_policy.main, aws_iam_role_policy.projector]
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.p}-outbox-relay"
  group_name          = "default"
  state               = "ENABLED"
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "clearledger.scheduler", task = "outbox-relay" })
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

resource "aws_scheduler_schedule" "archive" {
  name                = "${local.p}-audit-archiver"
  group_name          = "default"
  state               = "ENABLED"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "clearledger.scheduler", task = "audit-archiver" })
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
