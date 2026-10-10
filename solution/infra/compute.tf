resource "aws_lb" "api" {
  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-alb"
  })
}

resource "aws_lb_target_group" "api" {
  name                 = "${local.prefix}-api-tg"
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

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-api-tg"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-http-listener"
  })
}

resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-cluster"
  })
}

locals {
  cognito_issuer = "${trimsuffix(var.aws_endpoint_url, "/")}/${aws_cognito_user_pool.main.id}"
  cognito_jwks   = "${trimsuffix(var.aws_endpoint_url, "/")}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  cognito_token  = "${trimsuffix(var.aws_endpoint_url, "/")}/cognito-idp/oauth2/token"
  audiences = join(",", [
    aws_cognito_user_pool_client.read.id,
    aws_cognito_user_pool_client.write.id,
    aws_cognito_user_pool_client.admin.id,
  ])
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.prefix}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  lifecycle {
    create_before_destroy = true
  }

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
        { name = "PORT", value = "8080" },
        { name = "AWS_REGION", value = var.region },
        { name = "AWS_DEFAULT_REGION", value = var.region },
        { name = "AWS_ACCESS_KEY_ID", value = "test" },
        { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
        { name = "AWS_ENDPOINT_URL", value = var.aws_endpoint_url },
        { name = "AWS_EC2_METADATA_DISABLED", value = "true" },
        { name = "NO_PROXY", value = "localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal" },
        { name = "no_proxy", value = "localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal" },
        { name = "DATABASE_URL", value = local.database_url },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.events.url },
        { name = "PROJECTION_TABLE", value = aws_dynamodb_table.projections.name },
        { name = "VALKEY_URL", value = local.valkey_url },
        { name = "CACHE_TTL_SECONDS", value = "90" },
        { name = "AUTH_ISSUER", value = local.cognito_issuer },
        { name = "AUTH_JWKS_URL", value = local.cognito_jwks },
        { name = "AUTH_AUDIENCES", value = local.audiences },
        { name = "CLOUDWATCH_LOG_GROUP", value = aws_cloudwatch_log_group.api.name }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "api"
        }
      }
    }
  ])

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-api-taskdef"
  })
}

resource "aws_ecs_service" "api" {
  name            = "${local.prefix}-api-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-api-service"
  })

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.ecs_execution,
    aws_iam_role_policy.ecs_task,
    aws_db_instance.main,
    aws_dynamodb_table.projections,
    aws_sqs_queue.events,
    aws_elasticache_replication_group.valkey,
  ]
}
