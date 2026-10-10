# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${local.prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  tags               = { Name = "${local.prefix}-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${local.prefix}-api"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    path     = "/health/ready"
    protocol = "HTTP"
    matcher  = "200"
  }

  tags = { Name = "${local.prefix}-api" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = { Name = "${local.prefix}-http" }
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

  tags = { Name = "${local.prefix}-cluster" }
}

locals {
  common_worker_env = {
    AWS_REGION            = local.region
    AWS_DEFAULT_REGION    = local.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.runtime_aws_ep
  }

  api_env = merge(local.common_worker_env, {
    PORT                 = "8080"
    DATABASE_URL         = local.db_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CACHE_TTL_SECONDS    = "90"
    AUTH_ISSUER          = local.issuer_url
    AUTH_AUDIENCES       = local.auth_audiences
    AUTH_JWKS_URL        = local.jwks_url
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["api"].name
  })

  projector_env = merge(local.common_worker_env, {
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
  })

  relay_env = merge(local.common_worker_env, {
    DATABASE_URL         = local.db_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    OUTBOX_BATCH_SIZE    = "50"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
  })

  archiver_env = merge(local.common_worker_env, {
    DATABASE_URL         = local.db_url
    AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
    AUDIT_PREFIX         = "ledger-audit/"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
  })
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
      environment = [for k, v in local.api_env : { name = k, value = v }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this["api"].name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])

  tags = { Name = "${local.prefix}-api" }

  lifecycle {
    # tags are applied on creation; the control plane does not echo them back on read
    ignore_changes = [tags, tags_all]
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_ecs_service" "api" {
  name            = "${local.prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  # Keep capacity during rolling replacement while the API is serving traffic.
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

  tags = { Name = "${local.prefix}-api" }

  depends_on = [aws_lb_listener.http]
}

# ---------------------------------------------------------------------------
# Lambda workers
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  package_type  = "Image"
  image_uri     = local.cfg.projector_image
  role          = aws_iam_role.this["projector"].arn
  timeout       = 3
  memory_size   = 256

  environment {
    variables = local.projector_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["projector"].name
  }

  tags = { Name = "${local.prefix}-projector", ImageId = local.cfg.projector_image_id }

  lifecycle {
    # the control plane reports an empty image_config block that is never configured
    ignore_changes = [image_config]
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  package_type  = "Image"
  image_uri     = local.cfg.relay_image
  role          = aws_iam_role.this["relay"].arn
  timeout       = 30
  memory_size   = 256

  environment {
    variables = local.relay_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["relay"].name
  }

  tags = { Name = "${local.prefix}-outbox-relay", ImageId = local.cfg.relay_image_id }

  lifecycle {
    ignore_changes = [image_config]
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  package_type  = "Image"
  image_uri     = local.cfg.archiver_image
  role          = aws_iam_role.this["archiver"].arn
  timeout       = 60
  memory_size   = 256

  environment {
    variables = local.archiver_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["archiver"].name
  }

  tags = { Name = "${local.prefix}-audit-archiver", ImageId = local.cfg.archiver_image_id }

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

  lifecycle {
    ignore_changes = [tags_all]
  }
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler
# ---------------------------------------------------------------------------
resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.prefix}-outbox-relay"
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.this["scheduler"].arn
  }
}

resource "aws_scheduler_schedule" "archive" {
  name                = "${local.prefix}-audit-archiver"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.this["scheduler"].arn
  }
}
