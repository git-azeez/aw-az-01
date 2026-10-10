locals {
  database_url = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.valkey.primary_endpoint_address, aws_elasticache_replication_group.valkey.configuration_endpoint_address)
  valkey_port  = aws_elasticache_replication_group.valkey.port
  valkey_url   = "redis://${local.valkey_host}:${local.valkey_port}"

  # Host name under which the emulator exposes ALB listener sockets.
  service_host = regex("^https?://([^:/]+)", var.aws_endpoint_url)[0]

  aws_runtime_env = {
    AWS_REGION            = var.region
    AWS_DEFAULT_REGION    = var.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = var.aws_endpoint_url
  }

  api_env = merge(local.aws_runtime_env, {
    PORT                 = "8080"
    DATABASE_URL         = local.database_url
    SQS_QUEUE_URL        = aws_sqs_queue.main.url
    PROJECTION_TABLE     = aws_dynamodb_table.projections.name
    VALKEY_URL           = local.valkey_url
    CACHE_TTL_SECONDS    = "90"
    AUTH_ISSUER          = local.auth_issuer
    AUTH_AUDIENCES       = local.auth_audiences
    AUTH_JWKS_URL        = local.auth_jwks_url
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.this["api"].name
  })
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "api" {
  name               = "${local.prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  tags = {
    Name = "${local.prefix}-alb"
  }
}

resource "aws_lb_target_group" "api" {
  name        = "${local.prefix}-api-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 5

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

  tags = {
    Name = "${local.prefix}-api-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = {
    Name = "${local.prefix}-http"
  }
}

# The emulator serves every load balancer listening on a port from one socket;
# a host-header rule makes "http://aws:80" resolve to this ALB unambiguously.
resource "aws_lb_listener_rule" "service_host" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    host_header {
      values = [local.service_host]
    }
  }

  tags = {
    Name = "${local.prefix}-service-host"
  }
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

  tags = {
    Name = "${local.prefix}-cluster"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.prefix}-api"
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
      environment = [
        for k in sort(keys(local.api_env)) : { name = k, value = local.api_env[k] }
      ]
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

  tags = {
    Name = "${local.prefix}-api"
  }

  lifecycle {
    # The emulator stores the tags but DescribeTaskDefinition(include=TAGS)
    # does not echo them back.
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecs_service" "api" {
  name            = "${local.prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  launch_type     = "FARGATE"
  desired_count   = 2

  deployment_minimum_healthy_percent = 50
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

  wait_for_steady_state = false

  tags = {
    Name = "${local.prefix}-api"
  }

  depends_on = [aws_lb_listener.http]
}
