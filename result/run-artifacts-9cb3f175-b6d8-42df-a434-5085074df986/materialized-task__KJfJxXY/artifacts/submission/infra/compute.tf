locals {
  db_endpoint  = aws_db_instance.main.address
  db_port      = aws_db_instance.main.port
  database_url = "postgres://${local.db_username}:${local.db_password}@${local.db_endpoint}:${local.db_port}/${local.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.valkey.primary_endpoint_address, aws_elasticache_replication_group.valkey.configuration_endpoint_address)
  valkey_port  = aws_elasticache_replication_group.valkey.port
  valkey_url   = "redis://${local.valkey_host}:${local.valkey_port}"
  issuer_url   = "${local.endpoint_url}/${aws_cognito_user_pool.main.id}"
  jwks_url     = "${local.endpoint_url}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  token_url    = "${local.endpoint_url}/cognito-idp/oauth2/token"
  audiences    = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.this[k].id])
  audit_prefix = "ledger-audit/"
  base_aws_env = {
    AWS_REGION            = local.region
    AWS_DEFAULT_REGION    = local.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.endpoint_url
  }
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

  container_definitions = jsonencode([{
    name      = "api"
    image     = local.images.api
    essential = true
    portMappings = [{
      containerPort = 8080
      hostPort      = 8080
      protocol      = "tcp"
    }]
    environment = [for k, v in merge(local.base_aws_env, {
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
    }) : { name = k, value = v }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this["api"].name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])

  tags = merge(local.tags, { Name = "${local.prefix}-api" })

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecs_service" "api" {
  name            = "${local.prefix}-api"
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

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.this]

  tags = merge(local.tags, { Name = "${local.prefix}-api" })
}

# ---------------------------------------------------------------- Lambda workers
resource "aws_lambda_function" "projector" {
  function_name = "${local.prefix}-projector"
  package_type  = "Image"
  image_uri     = local.images.projector
  role          = aws_iam_role.this["projector"].arn
  timeout       = 30
  memory_size   = 512

  environment {
    variables = merge(local.base_aws_env, {
      PROJECTION_TABLE     = aws_dynamodb_table.projections.name
      VALKEY_URL           = local.valkey_url
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
    })
  }

  tags = merge(local.tags, { Name = "${local.prefix}-projector", ImageId = local.image_ids.projector })

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "relay" {
  function_name = "${local.prefix}-outbox-relay"
  package_type  = "Image"
  image_uri     = local.images.relay
  role          = aws_iam_role.this["relay"].arn
  timeout       = 60
  memory_size   = 512

  environment {
    variables = merge(local.base_aws_env, {
      DATABASE_URL         = local.database_url
      SQS_QUEUE_URL        = aws_sqs_queue.main.url
      OUTBOX_BATCH_SIZE    = "50"
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
    })
  }

  tags = merge(local.tags, { Name = "${local.prefix}-outbox-relay", ImageId = local.image_ids.relay })

  lifecycle {
    ignore_changes = [image_config]
  }
}

resource "aws_lambda_function" "archiver" {
  function_name = "${local.prefix}-audit-archiver"
  package_type  = "Image"
  image_uri     = local.images.archiver
  role          = aws_iam_role.this["archiver"].arn
  timeout       = 120
  memory_size   = 512

  environment {
    variables = merge(local.base_aws_env, {
      DATABASE_URL         = local.database_url
      AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
      AUDIT_PREFIX         = local.audit_prefix
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
    })
  }

  tags = merge(local.tags, { Name = "${local.prefix}-audit-archiver", ImageId = local.image_ids.archiver })

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
  tags                               = merge(local.tags, { Name = "${local.prefix}-projector-esm" })

  lifecycle {
    ignore_changes = [tags, tags_all]
  }

  depends_on = [aws_iam_role_policy.this]
}

# ---------------------------------------------------------------- EventBridge Scheduler
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

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_scheduler_schedule" "archive" {
  name                = "${local.prefix}-audit-archive"
  state               = "ENABLED"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.archiver.arn
    role_arn = aws_iam_role.this["scheduler"].arn
  }

  depends_on = [aws_iam_role_policy.this]
}
