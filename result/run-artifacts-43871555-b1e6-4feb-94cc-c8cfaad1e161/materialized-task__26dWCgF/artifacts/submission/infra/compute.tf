# ---------------------------------------------------------------------------
# Lambda workers (container images)
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  role          = aws_iam_role.projector.arn
  package_type  = "Image"
  image_uri     = local.config.projector_image
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      AWS_REGION            = local.region
      AWS_DEFAULT_REGION    = local.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.runtime_endpoint
      PROJECTION_TABLE      = aws_dynamodb_table.projections.name
      VALKEY_URL            = local.valkey_url
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.projector.name
    }
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-projector" })
  depends_on = [aws_iam_role_policy.projector, aws_cloudwatch_log_group.projector]

  lifecycle {
    # The control plane reports an empty image_config block back.
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  role          = aws_iam_role.relay.arn
  package_type  = "Image"
  image_uri     = local.config.relay_image
  timeout       = 60
  memory_size   = 256

  environment {
    variables = {
      AWS_REGION            = local.region
      AWS_DEFAULT_REGION    = local.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.runtime_endpoint
      DATABASE_URL          = local.database_url
      SQS_QUEUE_URL         = aws_sqs_queue.main.url
      OUTBOX_BATCH_SIZE     = "50"
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.relay.name
    }
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-outbox-relay" })
  depends_on = [aws_iam_role_policy.relay, aws_cloudwatch_log_group.relay]

  lifecycle {
    # The control plane reports an empty image_config block back.
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  role          = aws_iam_role.archiver.arn
  package_type  = "Image"
  image_uri     = local.config.archiver_image
  timeout       = 60
  memory_size   = 256

  environment {
    variables = {
      AWS_REGION            = local.region
      AWS_DEFAULT_REGION    = local.region
      AWS_ACCESS_KEY_ID     = "test"
      AWS_SECRET_ACCESS_KEY = "test"
      AWS_ENDPOINT_URL      = local.runtime_endpoint
      DATABASE_URL          = local.database_url
      AUDIT_BUCKET          = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX          = "ledger-audit/"
      CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.archiver.name
    }
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-audit-archiver" })
  depends_on = [aws_iam_role_policy.archiver, aws_cloudwatch_log_group.archiver]

  lifecycle {
    # The control plane reports an empty image_config block back.
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
  tags                               = local.tags

  lifecycle {
    ignore_changes = [tags_all]
  }
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler
# ---------------------------------------------------------------------------
resource "aws_lambda_permission" "scheduler_relay" {
  statement_id  = "AllowSchedulerInvokeRelay"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.relay.function_name
  principal     = "scheduler.amazonaws.com"
}

resource "aws_lambda_permission" "scheduler_archiver" {
  statement_id  = "AllowSchedulerInvokeArchiver"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.archiver.function_name
  principal     = "scheduler.amazonaws.com"
}

resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.prefix}-outbox-relay"
  state               = "ENABLED"
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.relay.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "archive" {
  name                = "${local.prefix}-audit-archiver"
  state               = "ENABLED"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.scheduler.arn
  }
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
  name        = "${local.prefix}-api"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 15

  health_check {
    path                = "/health/ready"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
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

  tags = local.tags
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
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = local.config.api_image
      essential = true
      portMappings = [
        { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
      ]
      environment = [
        { name = "PORT", value = "8080" },
        { name = "AWS_REGION", value = local.region },
        { name = "AWS_DEFAULT_REGION", value = local.region },
        { name = "AWS_ACCESS_KEY_ID", value = "test" },
        { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
        { name = "AWS_ENDPOINT_URL", value = local.runtime_endpoint },
        { name = "DATABASE_URL", value = local.database_url },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.main.url },
        { name = "PROJECTION_TABLE", value = aws_dynamodb_table.projections.name },
        { name = "VALKEY_URL", value = local.valkey_url },
        { name = "CACHE_TTL_SECONDS", value = "90" },
        { name = "AUTH_ISSUER", value = local.issuer_url },
        { name = "AUTH_AUDIENCES", value = local.auth_audiences },
        { name = "AUTH_JWKS_URL", value = local.jwks_url },
        { name = "CLOUDWATCH_LOG_GROUP", value = aws_cloudwatch_log_group.api.name },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])

  tags = merge(local.tags, { Name = "${local.prefix}-api" })

  lifecycle {
    # Task definition tags are not echoed back by the control plane.
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecs_service" "api" {
  name            = "${local.prefix}-api"
  cluster         = aws_ecs_cluster.main.id
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

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.ecs_execution, aws_iam_role_policy.ecs_task, aws_db_instance.main]
  tags       = merge(local.tags, { Name = "${local.prefix}-api" })
}
