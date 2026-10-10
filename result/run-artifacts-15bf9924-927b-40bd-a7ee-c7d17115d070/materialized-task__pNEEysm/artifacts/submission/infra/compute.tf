# ---------------- Lambda workers ----------------

resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  package_type  = "Image"
  image_uri     = local.cfg.projector_image
  role          = aws_iam_role.this["projector"].arn
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
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.projector.name
    })
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-projector", ImageId = local.cfg.projector_image_id })
  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.projector]
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  package_type  = "Image"
  image_uri     = local.cfg.relay_image
  role          = aws_iam_role.this["relay"].arn
  timeout       = 30
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
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.relay.name
    })
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-outbox-relay", ImageId = local.cfg.relay_image_id })
  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.relay]
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  package_type  = "Image"
  image_uri     = local.cfg.archiver_image
  role          = aws_iam_role.this["archiver"].arn
  timeout       = 60
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
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.archiver.name
    })
  }

  tags       = merge(local.tags, { Name = "${local.prefix}-audit-archiver", ImageId = local.cfg.archiver_image_id })
  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.archiver]
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.projector.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
}

# ---------------- EventBridge Scheduler ----------------

resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.prefix}-outbox-relay"
  state               = "ENABLED"
  schedule_expression = "rate(1 minute)"

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
  state               = "ENABLED"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.this["scheduler"].arn
  }
}

# ---------------- ALB ----------------

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
    path                = "/health/ready"
    protocol            = "HTTP"
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

  tags = local.tags
}

# ---------------- ECS ----------------

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
      image     = local.cfg.api_image
      essential = true
      portMappings = [{
        containerPort = 8080
        hostPort      = 8080
        protocol      = "tcp"
      }]
      environment = [for k, v in merge(local.base_env, {
        PORT                 = "8080"
        DATABASE_URL         = local.database_url
        SQS_QUEUE_URL        = aws_sqs_queue.main.url
        PROJECTION_TABLE     = aws_dynamodb_table.projections.name
        VALKEY_URL           = local.valkey_url
        CACHE_TTL_SECONDS    = "90"
        AUTH_ISSUER          = "${local.endpoint}/${aws_cognito_user_pool.main.id}"
        AUTH_AUDIENCES       = join(",", [for c in ["read", "write", "admin"] : aws_cognito_user_pool_client.this[c].id])
        AUTH_JWKS_URL        = "${local.endpoint}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
        CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.api.name
      }) : { name = k, value = v }]
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
    create_before_destroy = true
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

  tags       = merge(local.tags, { Name = "${local.prefix}-api" })
  depends_on = [aws_lb_listener.http, aws_iam_role_policy.this]
}
