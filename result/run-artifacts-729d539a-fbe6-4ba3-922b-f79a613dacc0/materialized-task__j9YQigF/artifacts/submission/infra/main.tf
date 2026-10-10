terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.51.0" }
  }
  backend "local" { path = "terraform.tfstate" }
}
locals {
  config   = jsondecode(file("/workspace/config/config.json"))
  prefix   = local.config.resource_prefix
  region   = local.config.region
  endpoint = local.config.aws_endpoint_url
  tags     = { ClearLedgerDeployment = local.prefix }
  azs      = ["${local.region}a", "${local.region}b"]
}
provider "aws" {
  region                      = local.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  default_tags { tags = local.tags }
  endpoints {
    ec2            = local.endpoint
    elbv2          = local.endpoint
    ecs            = local.endpoint
    rds            = local.endpoint
    sqs            = local.endpoint
    lambda         = local.endpoint
    scheduler      = local.endpoint
    dynamodb       = local.endpoint
    elasticache    = local.endpoint
    s3             = local.endpoint
    cognitoidp     = local.endpoint
    iam            = local.endpoint
    kms            = local.endpoint
    cloudwatchlogs = local.endpoint
    sts            = local.endpoint
  }
}
data "aws_caller_identity" "current" {}
resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.prefix}-vpc" }
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.${count.index}.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.prefix}-public-${count.index}" }
}
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.${count.index + 10}.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.prefix}-private-${count.index}" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-igw" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.prefix}-public" }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-private" }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
resource "aws_security_group" "alb" {
  name   = "${local.prefix}-alb"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}
resource "aws_security_group" "ecs" {
  name   = "${local.prefix}-ecs"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "data" {
  for_each = { rds = 5432, valkey = 6379 }
  name     = "${local.prefix}-${each.key}"
  vpc_id   = aws_vpc.main.id
  ingress {
    from_port   = each.value
    to_port     = each.value
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}
resource "aws_kms_key" "keys" {
  for_each                = toset(["database", "messaging", "projection", "audit"])
  description             = "${local.prefix}-${each.key}"
  enable_key_rotation     = true
  deletion_window_in_days = 10
}
resource "aws_kms_alias" "keys" {
  for_each      = aws_kms_key.keys
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = each.value.key_id
}
resource "aws_cloudwatch_log_group" "workloads" {
  for_each          = { api = "api", projector = "projector", relay = "outbox-relay", archiver = "audit-archiver" }
  name              = "/clearledger/${local.prefix}/${each.value}"
  retention_in_days = 14
}
resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-database"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "main" {
  identifier              = "${local.prefix}-database"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = local.config.db_name
  username                = local.config.db_username
  password                = local.config.db_password
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.keys["database"].arn
  publicly_accessible     = false
  skip_final_snapshot     = true
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.data["rds"].id]
  apply_immediately       = true
  backup_retention_period = 7
}
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-events-dlq"
  kms_master_key_id         = aws_kms_key.keys["messaging"].arn
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "main" {
  name                       = "${local.prefix}-events"
  kms_master_key_id          = aws_kms_key.keys["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 4 })
}
resource "aws_dynamodb_table" "main" {
  name         = "${local.prefix}-projections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"
  dynamic "attribute" {
    for_each = toset(["PK", "SK", "GSI1PK", "GSI1SK"])
    content {
      name = attribute.value
      type = "S"
    }
  }
  global_secondary_index {
    name            = "AccountIndex"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }
  point_in_time_recovery { enabled = true }
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.keys["projection"].arn
  }
}
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.prefix}-cache"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${local.prefix}-cache"
  description          = "ClearLedger projection cache"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.data["valkey"].id]
  apply_immediately    = true
}
resource "aws_s3_bucket" "audit" {
  bucket        = "${local.prefix}-audit"
  force_destroy = true
}
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.keys["audit"].arn
    }
  }
}
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_cognito_user_pool" "main" { name = "${local.prefix}-auth" }
resource "aws_cognito_resource_server" "main" {
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger"
  user_pool_id = aws_cognito_user_pool.main.id
  dynamic "scope" {
    for_each = toset(["read", "write", "admin"])
    content {
      scope_name        = scope.value
      scope_description = "ClearLedger ${scope.value}"
    }
  }
}
resource "aws_cognito_user_pool_client" "clients" {
  for_each                             = toset(["read", "write", "admin"])
  name                                 = "${local.prefix}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.main.identifier}/${each.key}"]
}
resource "aws_lb" "main" {
  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}
resource "aws_lb_target_group" "main" {
  name        = "${local.prefix}-api"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check {
    path                = "/health/ready"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}
locals {
  database_url = sensitive("postgres://${urlencode(local.config.db_username)}:${urlencode(local.config.db_password)}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${local.config.db_name}")
  cache_host   = coalesce(aws_elasticache_replication_group.main.primary_endpoint_address, aws_elasticache_replication_group.main.configuration_endpoint_address)
  valkey_url   = "redis://${local.cache_host}:6379"
  issuer       = "${local.endpoint}/${aws_cognito_user_pool.main.id}"
  common_env   = { AWS_REGION = local.region, AWS_DEFAULT_REGION = local.region, AWS_ACCESS_KEY_ID = "test", AWS_SECRET_ACCESS_KEY = "test", AWS_ENDPOINT_URL = local.endpoint }
  api_env = merge(local.common_env, {
    PORT                 = "8080", DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.main.url,
    PROJECTION_TABLE     = aws_dynamodb_table.main.name, VALKEY_URL = local.valkey_url, CACHE_TTL_SECONDS = "90",
    AUTH_ISSUER          = local.issuer, AUTH_JWKS_URL = "${local.issuer}/.well-known/jwks.json",
    AUTH_AUDIENCES       = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.clients[k].id]),
    CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.workloads["api"].name
  })
  worker_env = {
    projector = { PROJECTION_TABLE = aws_dynamodb_table.main.name, VALKEY_URL = local.valkey_url }
    relay     = { DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.main.url, OUTBOX_BATCH_SIZE = "50" }
    archiver  = { DATABASE_URL = local.database_url, AUDIT_BUCKET = aws_s3_bucket.audit.id, AUDIT_PREFIX = "ledger-audit/" }
  }
}
resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.roles["ecs_execution"].arn
  task_role_arn            = aws_iam_role.roles["ecs_task"].arn
  container_definitions = jsonencode([{ name = "api", image = local.config.api_image, essential = true,
    portMappings     = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }],
    environment      = [for k, v in local.api_env : { name = k, value = v }],
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.workloads["api"].name, awslogs-region = local.region, awslogs-stream-prefix = "api" } }
  }])
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
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "api"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener.main, aws_iam_role_policy.canonical]
}
resource "aws_lambda_function" "workers" {
  for_each      = toset(["projector", "relay", "archiver"])
  function_name = "${local.prefix}-${each.key}"
  package_type  = "Image"
  image_uri     = local.config["${each.key}_image"]
  role          = aws_iam_role.roles[each.key].arn
  timeout       = 3
  memory_size   = 256
  environment { variables = merge(local.common_env, local.worker_env[each.key], { CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.workloads[each.key].name }) }
}
resource "aws_lambda_event_source_mapping" "projector" {
  function_name                      = aws_lambda_function.workers["projector"].arn
  event_source_arn                   = aws_sqs_queue.main.arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
  depends_on                         = [aws_iam_role_policy.canonical]
}
resource "aws_scheduler_schedule" "workers" {
  for_each            = { relay = "rate(1 minute)", archiver = "rate(5 minutes)" }
  name                = "${local.prefix}-${each.key}"
  state               = "ENABLED"
  schedule_expression = each.value
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.workers[each.key].arn
    role_arn = aws_iam_role.roles["scheduler"].arn
    input    = "{}"
  }
}
