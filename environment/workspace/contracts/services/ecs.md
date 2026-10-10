# ECS Fargate Service (`services/ecs.md`)

- Provision an ECS cluster (`aws_ecs_cluster`) with Container Insights enabled (`setting { name = "containerInsights", value = "enabled" }`).
- Provision an ECS task definition (`aws_ecs_task_definition`) with:
  - `requires_compatibilities = ["FARGATE"]`
  - `network_mode = "awsvpc"`
  - `execution_role_arn` set to the `ecs_execution` IAM role
  - `task_role_arn` set to the `ecs_task` IAM role
  - `lifecycle { create_before_destroy = true }` so task definition revisions roll out without interrupting the ECS service
  - Container definition named `api` running `api_image` from `config.json`, exposing TCP container port `8080`, configuring `logConfiguration` with `logDriver = "awslogs"` (`awslogs-group = logs.api_log_group`, `awslogs-region = <region>`), and defining all required environment variables from `runtime.md` (including `CACHE_TTL_SECONDS = "90"`).
- Provision an ECS service (`aws_ecs_service`) with:
  - `launch_type = "FARGATE"`
  - `desired_count = 2` (at least 2 running tasks distributed across `us-east-1a` and `us-east-1b`)
  - `network_configuration` attached strictly to the two private subnets (`network.private_subnet_ids`), the `ecs` security group, and `assign_public_ip = false`
  - `load_balancer` block registering container `api` on port `8080` with the ALB target group


