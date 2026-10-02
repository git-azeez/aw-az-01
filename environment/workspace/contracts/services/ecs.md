# ECS Fargate Service (`services/ecs.md`)

- Provision an ECS cluster (`aws_ecs_cluster`).
- Provision an ECS task definition (`aws_ecs_task_definition`) with:
  - `requires_compatibilities = ["FARGATE"]`
  - `network_mode = "awsvpc"`
  - `execution_role_arn` set to the `ecs_execution` IAM role
  - `task_role_arn` set to the `ecs_task` IAM role
  - Container definition named `api` running `api_image` from `config.json`, exposing container port `8080`, sending logs to `logs.api_log_group`, and defining all required environment variables from `runtime.md` (including `CACHE_TTL_SECONDS = "90"`).
- Provision an ECS service (`aws_ecs_service`) with:
  - `launch_type = "FARGATE"`
  - `desired_count = 2` (at least 2 running tasks distributed across `us-east-1a` and `us-east-1b`)
  - `network_configuration` attached to the two private subnets and the `ecs` security group
  - `load_balancer` block registering container `api` on port `8080` with the ALB target group
