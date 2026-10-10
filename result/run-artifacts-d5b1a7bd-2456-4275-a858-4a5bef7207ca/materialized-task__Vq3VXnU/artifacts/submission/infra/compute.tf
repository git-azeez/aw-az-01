############################
# Application Load Balancer
############################

resource "aws_lb" "api" {
  name               = "${local.p}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 60

  tags = { Name = "${local.p}-alb" }
}

resource "aws_lb_target_group" "api" {
  name                 = "${local.p}-api-tg"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 10

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

############################
# ECS Fargate API service
############################

resource "aws_ecs_cluster" "main" {
  name = "${local.p}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.p}-cluster" }
}

locals {
  auth_issuer   = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}"
  auth_jwks_url = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  auth_audiences = join(",", [
    aws_cognito_user_pool_client.this["read"].id,
    aws_cognito_user_pool_client.this["write"].id,
    aws_cognito_user_pool_client.this["admin"].id,
  ])

  api_env = {
    PORT                  = "8080"
    AWS_REGION            = var.region
    AWS_DEFAULT_REGION    = var.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = var.aws_endpoint_url
    DATABASE_URL          = local.database_url
    SQS_QUEUE_URL         = local.queue_url_det
    PROJECTION_TABLE      = aws_dynamodb_table.projections.name
    VALKEY_URL            = local.valkey_url
    CACHE_TTL_SECONDS     = var.cache_ttl_seconds
    AUTH_ISSUER           = local.auth_issuer
    AUTH_AUDIENCES        = local.auth_audiences
    AUTH_JWKS_URL         = local.auth_jwks_url
    CLOUDWATCH_LOG_GROUP  = aws_cloudwatch_log_group.this["api"].name
  }
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
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
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

  tags = { Name = "${local.p}-api", ImageId = var.api_image_id }

  lifecycle {
    # The control plane applies tags at registration but does not echo them
    # back from DescribeTaskDefinition; avoid a perpetual no-op diff.
    ignore_changes = [tags, tags_all]
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

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.ecs_execution, aws_iam_role_policy.ecs_task, aws_sqs_queue.main]
}

############################
# Lambda workers
############################

resource "aws_lambda_function" "projector" {
  function_name = "${local.p}-projector"
  description   = "ClearLedger projector (SQS -> DynamoDB/Valkey)"
  package_type  = "Image"
  image_uri     = var.projector_image
  role          = aws_iam_role.projector.arn
  timeout       = 3
  memory_size   = 512

  environment {
    variables = merge(local.common_lambda_env, {
      PROJECTION_TABLE     = aws_dynamodb_table.projections.name
      VALKEY_URL           = local.valkey_url
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["projector"].name
  }

  tags = { Name = "${local.p}-projector", ImageId = var.projector_image_id }

  depends_on = [aws_iam_role_policy.projector]

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.p}-outbox-relay"
  description   = "ClearLedger outbox relay (PostgreSQL outbox -> SQS)"
  package_type  = "Image"
  image_uri     = var.relay_image
  role          = aws_iam_role.relay.arn
  timeout       = 60
  memory_size   = 512

  environment {
    variables = merge(local.common_lambda_env, {
      DATABASE_URL         = local.database_url
      SQS_QUEUE_URL        = local.queue_url_det
      OUTBOX_BATCH_SIZE    = var.outbox_batch_size
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["relay"].name
  }

  tags = { Name = "${local.p}-outbox-relay", ImageId = var.relay_image_id }

  depends_on = [aws_iam_role_policy.relay, aws_sqs_queue.main]

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.p}-audit-archiver"
  description   = "ClearLedger audit archiver (PostgreSQL outbox -> S3 NDJSON)"
  package_type  = "Image"
  image_uri     = var.archiver_image
  role          = aws_iam_role.archiver.arn
  timeout       = 120
  memory_size   = 512

  environment {
    variables = merge(local.common_lambda_env, {
      DATABASE_URL         = local.database_url
      AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX         = var.audit_prefix
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this["archiver"].name
  }

  tags = { Name = "${local.p}-audit-archiver", ImageId = var.archiver_image_id }

  depends_on = [aws_iam_role_policy.archiver]

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = local.queue_arn_det
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [aws_sqs_queue.main, aws_iam_role_policy.projector]

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

############################
# EventBridge Scheduler
############################

resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.p}-outbox-relay"
  description         = "Drain the ClearLedger transactional outbox every minute"
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

    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 60
    }
  }
}

resource "aws_scheduler_schedule" "archive" {
  name                = "${local.p}-audit-archiver"
  description         = "Archive published ClearLedger events to S3 every five minutes"
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

    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 300
    }
  }
}
