locals {
  db_url     = "postgres://${local.config.db_username}:${local.config.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${local.config.db_name}"
  # primary_endpoint_address is empty for non-clustered groups on some control planes.
  valkey_host = coalesce(
    aws_elasticache_replication_group.valkey.primary_endpoint_address,
    aws_elasticache_replication_group.valkey.configuration_endpoint_address,
    aws_elasticache_replication_group.valkey.reader_endpoint_address,
  )
  valkey_url = "redis://${local.valkey_host}:${aws_elasticache_replication_group.valkey.port}"

  auth_issuer    = "${local.endpoint}/${aws_cognito_user_pool.main.id}"
  auth_jwks      = "${local.endpoint}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  auth_audiences = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.this[k].id])

  base_env = {
    AWS_REGION            = local.region
    AWS_DEFAULT_REGION    = local.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.endpoint
  }

  api_env = merge(local.base_env, {
    PORT                 = "8080"
    DATABASE_URL         = local.db_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CACHE_TTL_SECONDS    = "90"
    AUTH_ISSUER          = local.auth_issuer
    AUTH_AUDIENCES       = local.auth_audiences
    AUTH_JWKS_URL        = local.auth_jwks
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["api"].name
  })

  projector_env = merge(local.base_env, {
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
  })

  relay_env = merge(local.base_env, {
    DATABASE_URL         = local.db_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    OUTBOX_BATCH_SIZE    = "50"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
  })

  archiver_env = merge(local.base_env, {
    DATABASE_URL         = local.db_url
    AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
    AUDIT_PREFIX         = "ledger-audit/"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
  })
}

# ---------------------------------------------------------------- ALB
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

  health_check {
    enabled             = true
    path                = "/health/ready"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
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

  tags = merge(local.tags, { Name = "${local.prefix}-http" })
}

# ---------------------------------------------------------------- ECS
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
  execution_role_arn       = aws_iam_role.this["ecs_execution"].arn
  task_role_arn            = aws_iam_role.this["ecs_task"].arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = local.config.api_image
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
          "awslogs-group"         = aws_cloudwatch_log_group.this["api"].name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])

  tags = merge(local.tags, { Name = "${local.prefix}-api" })

  lifecycle {
    # The control plane does not echo task definition tags back.
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

# ---------------------------------------------------------------- Lambda workers
resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  package_type  = "Image"
  image_uri     = local.config.projector_image
  role          = aws_iam_role.this["projector"].arn
  timeout       = 30
  memory_size   = 256
  tags          = merge(local.tags, { Name = "${local.prefix}-projector" })

  environment {
    variables = {
      for k in ["AWS_ENDPOINT_URL", "PROJECTION_TABLE", "VALKEY_URL", "CLOUDWATCH_LOG_GROUP"] : k => local.projector_env[k]
    }
  }

  lifecycle {
    # The control plane reports an empty image_config for plain image functions.
    ignore_changes = [image_config]
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  package_type  = "Image"
  image_uri     = local.config.relay_image
  role          = aws_iam_role.this["relay"].arn
  timeout       = 60
  memory_size   = 256
  tags          = merge(local.tags, { Name = "${local.prefix}-outbox-relay" })

  environment {
    variables = {
      for k in ["AWS_ENDPOINT_URL", "DATABASE_URL", "SQS_QUEUE_URL", "OUTBOX_BATCH_SIZE", "CLOUDWATCH_LOG_GROUP"] : k => local.relay_env[k]
    }
  }

  lifecycle {
    # The control plane reports an empty image_config for plain image functions.
    ignore_changes = [image_config]
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  package_type  = "Image"
  image_uri     = local.config.archiver_image
  role          = aws_iam_role.this["archiver"].arn
  timeout       = 60
  memory_size   = 256
  tags          = merge(local.tags, { Name = "${local.prefix}-audit-archiver" })

  environment {
    variables = {
      for k in ["AWS_ENDPOINT_URL", "DATABASE_URL", "AUDIT_BUCKET", "AUDIT_PREFIX", "CLOUDWATCH_LOG_GROUP"] : k => local.archiver_env[k]
    }
  }

  lifecycle {
    # The control plane reports an empty image_config for plain image functions.
    ignore_changes = [image_config]
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.this]
}

# ---------------------------------------------------------------- EventBridge Scheduler
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

  depends_on = [aws_iam_role_policy.this]
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

  depends_on = [aws_iam_role_policy.this]
}
