locals {
  db_host = aws_db_instance.main.address
  db_port = aws_db_instance.main.port
  database_url = format(
    "postgres://%s:%s@%s:%s/%s",
    local.cfg.db_username, local.cfg.db_password, local.db_host, local.db_port, local.cfg.db_name,
  )
  valkey_host = coalesce(
    aws_elasticache_replication_group.valkey.primary_endpoint_address,
    aws_elasticache_replication_group.valkey.configuration_endpoint_address,
  )
  valkey_port = aws_elasticache_replication_group.valkey.port
  valkey_url  = "redis://${local.valkey_host}:${local.valkey_port}"

  pool_id    = aws_cognito_user_pool.main.id
  auth_base  = "${local.endpoint}/${local.pool_id}"
  client_ids = [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.this[k].id]

  aws_env = {
    AWS_REGION            = local.region
    AWS_DEFAULT_REGION    = local.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.endpoint
  }

  api_env = merge(local.aws_env, {
    PORT                 = "8080"
    DATABASE_URL         = local.database_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CACHE_TTL_SECONDS    = "90"
    AUTH_ISSUER          = local.auth_base
    AUTH_AUDIENCES       = join(",", local.client_ids)
    AUTH_JWKS_URL        = "${local.auth_base}/.well-known/jwks.json"
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["api"].name
  })
}

# ------------------------------------------------------------------- ECS
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

  tags = merge(local.tags, { Name = "${local.prefix}-api" })

  depends_on = [aws_iam_role_policy.this]

  lifecycle {
    create_before_destroy = true
    # The local control plane does not echo task definition tags back.
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
  health_check_grace_period_seconds  = 0

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

  depends_on = [aws_lb_listener.http]
}

# ---------------------------------------------------------------- Lambda
locals {
  lambda_defs = {
    projector = {
      name    = "${local.prefix}-projector"
      image   = local.cfg.projector_image
      timeout = 3
      env = {
        AWS_ENDPOINT_URL     = local.endpoint
        PROJECTION_TABLE     = aws_dynamodb_table.projections.name
        VALKEY_URL           = local.valkey_url
        CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["projector"].name
      }
    }
    relay = {
      name    = "${local.prefix}-outbox-relay"
      image   = local.cfg.relay_image
      timeout = 60
      env = {
        AWS_ENDPOINT_URL     = local.endpoint
        DATABASE_URL         = local.database_url
        SQS_QUEUE_URL        = aws_sqs_queue.main.url
        OUTBOX_BATCH_SIZE    = "50"
        CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["relay"].name
      }
    }
    archiver = {
      name    = "${local.prefix}-audit-archiver"
      image   = local.cfg.archiver_image
      timeout = 60
      env = {
        AWS_ENDPOINT_URL     = local.endpoint
        DATABASE_URL         = local.database_url
        AUDIT_BUCKET         = aws_s3_bucket.audit.bucket
        AUDIT_PREFIX         = "ledger-audit/"
        CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["archiver"].name
      }
    }
  }
}

resource "aws_lambda_function" "this" {
  for_each      = local.lambda_defs
  function_name = each.value.name
  package_type  = "Image"
  image_uri     = each.value.image
  role          = aws_iam_role.this[each.key].arn
  timeout       = each.value.timeout
  memory_size   = 512

  image_config {
    command     = []
    entry_point = []
  }

  environment {
    variables = each.value.env
  }

  tags = merge(local.tags, { Name = each.value.name })

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.this["projector"].arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [aws_sqs_queue_policy.main]

  lifecycle {
    # The local control plane does not persist event source mapping tags.
    ignore_changes = [tags, tags_all]
  }
}

# ------------------------------------------------------------- Scheduler
resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.prefix}-outbox-relay"
  state               = "ENABLED"
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this["relay"].arn
    role_arn = aws_iam_role.this["scheduler"].arn
    input    = "{}"
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
    arn      = aws_lambda_function.this["archiver"].arn
    role_arn = aws_iam_role.this["scheduler"].arn
    input    = "{}"
  }
}
