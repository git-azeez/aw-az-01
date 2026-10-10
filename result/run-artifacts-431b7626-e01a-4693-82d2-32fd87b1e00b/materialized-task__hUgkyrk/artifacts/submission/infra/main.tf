terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.51.0" }
  }
  backend "local" { path = "terraform.tfstate" }
}

variable "resource_prefix" { type = string }
variable "region" { type = string }
variable "aws_endpoint_url" { type = string }
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "db_password" {
  type      = string
  sensitive = true
}
variable "api_image" { type = string }
variable "projector_image" { type = string }
variable "relay_image" { type = string }
variable "archiver_image" { type = string }
variable "api_image_id" { type = string }
variable "projector_image_id" { type = string }
variable "relay_image_id" { type = string }
variable "archiver_image_id" { type = string }

provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  endpoints {
    ec2            = var.aws_endpoint_url
    elbv2          = var.aws_endpoint_url
    ecs            = var.aws_endpoint_url
    rds            = var.aws_endpoint_url
    sqs            = var.aws_endpoint_url
    lambda         = var.aws_endpoint_url
    dynamodb       = var.aws_endpoint_url
    elasticache    = var.aws_endpoint_url
    s3             = var.aws_endpoint_url
    scheduler      = var.aws_endpoint_url
    cognitoidp     = var.aws_endpoint_url
    iam            = var.aws_endpoint_url
    kms            = var.aws_endpoint_url
    cloudwatchlogs = var.aws_endpoint_url
    sts            = var.aws_endpoint_url
  }
  default_tags { tags = { ClearLedgerDeployment = var.resource_prefix } }
}

locals {
  prefix = var.resource_prefix
  azs    = ["${var.region}a", "${var.region}b"]
  common_env = {
    AWS_REGION        = var.region, AWS_DEFAULT_REGION = var.region,
    AWS_ACCESS_KEY_ID = "test", AWS_SECRET_ACCESS_KEY = "test", AWS_ENDPOINT_URL = var.aws_endpoint_url
  }
  database_url   = "postgres://${urlencode(var.db_username)}:${urlencode(var.db_password)}@${aws_db_instance.database.address}:${aws_db_instance.database.port}/${var.db_name}"
  cache_endpoint = coalesce(aws_elasticache_replication_group.cache.primary_endpoint_address, aws_elasticache_replication_group.cache.configuration_endpoint_address)
  valkey_url     = "redis://${local.cache_endpoint}:6379"
  issuer         = "${var.aws_endpoint_url}/${aws_cognito_user_pool.auth.id}"
  log_names      = { api = "api", projector = "projector", relay = "outbox-relay", archiver = "audit-archiver" }
}

resource "aws_vpc" "network" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.prefix}-vpc" }
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.network.id
  availability_zone       = local.azs[count.index]
  cidr_block              = "10.42.${count.index}.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.prefix}-public-${count.index}" }
}
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.network.id
  availability_zone       = local.azs[count.index]
  cidr_block              = "10.42.${count.index + 10}.0/24"
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.prefix}-private-${count.index}" }
}
resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.network.id
  tags   = { Name = "${local.prefix}-igw" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.network.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gateway.id
  }
  tags = { Name = "${local.prefix}-public" }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.network.id
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
  vpc_id = aws_vpc.network.id
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
    cidr_blocks = [aws_vpc.network.cidr_block]
  }
}
resource "aws_security_group" "ecs" {
  name   = "${local.prefix}-ecs"
  vpc_id = aws_vpc.network.id
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
resource "aws_security_group" "rds" {
  name   = "${local.prefix}-rds"
  vpc_id = aws_vpc.network.id
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.network.cidr_block]
  }
  egress = []
}
resource "aws_security_group" "valkey" {
  name   = "${local.prefix}-valkey"
  vpc_id = aws_vpc.network.id
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.network.cidr_block]
  }
  egress = []
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
resource "aws_cloudwatch_log_group" "logs" {
  for_each          = local.log_names
  name              = "/clearledger/${local.prefix}/${each.value}"
  retention_in_days = 14
}
resource "aws_db_subnet_group" "database" {
  name       = "${local.prefix}-database"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "database" {
  identifier              = "${local.prefix}-database"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.database.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.keys["database"].arn
  publicly_accessible     = false
  skip_final_snapshot     = true
  apply_immediately       = true
  backup_retention_period = 7
}
resource "aws_dynamodb_table" "projection" {
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
resource "aws_elasticache_subnet_group" "cache" {
  name       = "${local.prefix}-cache"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "cache" {
  replication_group_id       = "${local.prefix}-cache"
  description                = "${local.prefix} projection cache"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.cache.name
  security_group_ids         = [aws_security_group.valkey.id]
  automatic_failover_enabled = false
  apply_immediately          = true
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
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-events-dlq"
  kms_master_key_id         = aws_kms_key.keys["messaging"].arn
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "events" {
  name                       = "${local.prefix}-events"
  kms_master_key_id          = aws_kms_key.keys["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 4 })
}
resource "aws_cognito_user_pool" "auth" { name = "${local.prefix}-auth" }
resource "aws_cognito_resource_server" "auth" {
  user_pool_id = aws_cognito_user_pool.auth.id
  identifier   = "clearledger"
  name         = "${local.prefix}-scopes"
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
  user_pool_id                         = aws_cognito_user_pool.auth.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/${each.key}"]
  depends_on                           = [aws_cognito_resource_server.auth]
}
resource "aws_iam_role" "roles" {
  for_each           = { ecs_execution = "ecs-tasks", ecs_task = "ecs-tasks", projector = "lambda", relay = "lambda", archiver = "lambda", scheduler = "scheduler" }
  name               = "${local.prefix}-${replace(each.key, "_", "-")}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "${each.value}.amazonaws.com" } }] })
}
locals {
  worker_env = {
    projector = { PROJECTION_TABLE = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url }
    relay     = { DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.events.url, OUTBOX_BATCH_SIZE = "50" }
    archiver  = { DATABASE_URL = local.database_url, AUDIT_BUCKET = aws_s3_bucket.audit.id, AUDIT_PREFIX = "ledger-audit/" }
  }
  worker_images = { projector = var.projector_image, relay = var.relay_image, archiver = var.archiver_image }
}
resource "aws_lambda_function" "workers" {
  for_each      = local.worker_images
  function_name = "${local.prefix}-${local.log_names[each.key]}"
  package_type  = "Image"
  image_uri     = each.value
  role          = aws_iam_role.roles[each.key].arn
  timeout       = 30
  memory_size   = 256
  environment { variables = merge(local.common_env, local.worker_env[each.key], { CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.logs[each.key].name }) }
  depends_on = [aws_cloudwatch_log_group.logs]
}
resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.workers["projector"].arn
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
  depends_on = [aws_iam_role_policy.canonical]
}
resource "aws_lb" "api" {
  name               = "${local.prefix}-api"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}
resource "aws_lb_target_group" "api" {
  name        = "${local.prefix}-api"
  vpc_id      = aws_vpc.network.id
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  health_check {
    path              = "/health/ready"
    protocol          = "HTTP"
    matcher           = "200"
    interval          = 10
    healthy_threshold = 2
  }
}
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
resource "aws_ecs_cluster" "api" {
  name = "${local.prefix}-api"
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
  container_definitions = jsonencode([{ name = "api", image = var.api_image, essential = true,
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }],
    environment = [for k, v in merge(local.common_env, {
      PORT              = "8080", DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.events.url,
      PROJECTION_TABLE  = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url,
      CACHE_TTL_SECONDS = "90", AUTH_ISSUER = local.issuer,
      AUTH_AUDIENCES    = join(",", [for scope in ["read", "write", "admin"] : aws_cognito_user_pool_client.clients[scope].id]),
      AUTH_JWKS_URL     = "${local.issuer}/.well-known/jwks.json", CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.logs["api"].name
    }) : { name = k, value = v }],
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.logs["api"].name, awslogs-region = var.region, awslogs-stream-prefix = "api" } }
  }])
}
resource "aws_ecs_service" "api" {
  name            = "${local.prefix}-api"
  cluster         = aws_ecs_cluster.api.id
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
  depends_on = [aws_lb_listener.api, aws_iam_role_policy.canonical]
}
