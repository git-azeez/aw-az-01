locals {
  database_url = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.valkey.primary_endpoint_address, aws_elasticache_replication_group.valkey.configuration_endpoint_address)
  valkey_port  = aws_elasticache_replication_group.valkey.port
  valkey_url   = "redis://${local.valkey_host}:${local.valkey_port}"

  base_env = {
    AWS_REGION            = var.region
    AWS_DEFAULT_REGION    = var.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.container_aws_endpoint
  }

  api_env = merge(local.base_env, {
    PORT                 = "8080"
    DATABASE_URL         = local.database_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    PROJECTION_TABLE     = aws_dynamodb_table.projection.name
    VALKEY_URL           = local.valkey_url
    CACHE_TTL_SECONDS    = "90"
    AUTH_ISSUER          = local.auth_issuer
    AUTH_AUDIENCES       = local.auth_audiences
    AUTH_JWKS_URL        = local.auth_jwks
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["api"].name
  })

  projector_env = merge(local.base_env, {
    PROJECTION_TABLE     = aws_dynamodb_table.projection.name
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
    AUDIT_BATCH_SIZE     = "100"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
  })
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "api" {
  name               = "${local.p}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = merge(local.tags, { Name = "${local.p}-alb" })
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
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 5
  tags                 = merge(local.tags, { Name = "${local.p}-api-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = merge(local.tags, { Name = "${local.p}-http" })
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

  tags = merge(local.tags, { Name = "${local.p}-cluster" })
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

  tags = merge(local.tags, { Name = "${local.p}-api", ImageId = var.api_image_id })

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecs_service" "api" {
  name            = "${local.p}-api"
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

  wait_for_steady_state = false

  depends_on = [aws_lb_listener.http]
  tags       = merge(local.tags, { Name = "${local.p}-api" })
}

# ---------------------------------------------------------------------------
# Lambda workers
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "projector" {
  function_name = "${local.p}-projector"
  package_type  = "Image"
  image_uri     = var.projector_image
  role          = aws_iam_role.projector.arn
  timeout       = 30
  memory_size   = 256

  environment {
    variables = local.projector_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["projector"].name
  }

  tags = merge(local.tags, { Name = "${local.p}-projector", ImageId = var.projector_image_id })

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.p}-outbox-relay"
  package_type  = "Image"
  image_uri     = var.relay_image
  role          = aws_iam_role.relay.arn
  timeout       = 60
  memory_size   = 256

  environment {
    variables = local.relay_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["relay"].name
  }

  tags = merge(local.tags, { Name = "${local.p}-outbox-relay", ImageId = var.relay_image_id })

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.p}-audit-archiver"
  package_type  = "Image"
  image_uri     = var.archiver_image
  role          = aws_iam_role.archiver.arn
  timeout       = 60
  memory_size   = 256

  environment {
    variables = local.archiver_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["archiver"].name
  }

  tags = merge(local.tags, { Name = "${local.p}-audit-archiver", ImageId = var.archiver_image_id })

  lifecycle {
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

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
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
    input    = jsonencode({ source = "scheduler", job = "outbox-relay" })
  }
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
    input    = jsonencode({ source = "scheduler", job = "audit-archiver" })
  }
}
