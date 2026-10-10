terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.51.0" }
  }
  backend "local" { path = "terraform.tfstate" }
}
variable "config" {
  type      = map(string)
  sensitive = true
}
locals {
  c        = nonsensitive(var.config)
  p        = local.c.resource_prefix
  region   = local.c.region
  endpoint = local.c.aws_endpoint_url
  account  = "000000000000"
  roles    = toset(["ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler"])
  usages = {
    database   = ["relay", "archiver"]
    messaging  = ["ecs_task", "projector", "relay"]
    projection = ["ecs_task", "projector"]
    audit      = ["archiver"]
  }
  log_names   = { api = "api", projector = "projector", relay = "outbox-relay", archiver = "audit-archiver" }
  role_logs   = { ecs_execution = "api", ecs_task = "api", projector = "projector", relay = "relay", archiver = "archiver" }
  queue_arn   = "arn:aws:sqs:${local.region}:${local.account}:${local.p}-events"
  dlq_arn     = "arn:aws:sqs:${local.region}:${local.account}:${local.p}-dlq"
  table_arn   = "arn:aws:dynamodb:${local.region}:${local.account}:table/${local.p}-projections"
  bucket_arn  = "arn:aws:s3:::${local.p}-audit"
  worker_arns = { for k in ["projector", "relay", "archiver"] : k => "arn:aws:lambda:${local.region}:${local.account}:function:${local.p}-${k}" }
}
provider "aws" {
  region                      = local.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  default_tags { tags = { ClearLedgerDeployment = local.p } }
  endpoints {
    ec2            = local.endpoint
    elbv2          = local.endpoint
    ecs            = local.endpoint
    rds            = local.endpoint
    dynamodb       = local.endpoint
    elasticache    = local.endpoint
    s3             = local.endpoint
    sqs            = local.endpoint
    lambda         = local.endpoint
    scheduler      = local.endpoint
    cognitoidp     = local.endpoint
    iam            = local.endpoint
    kms            = local.endpoint
    cloudwatchlogs = local.endpoint
    sts            = local.endpoint
  }
}
resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.p}-vpc" }
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.${count.index}.0/24"
  availability_zone       = "${local.region}${count.index == 0 ? "a" : "b"}"
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.p}-public-${count.index}" }
}
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.${count.index + 10}.0/24"
  availability_zone       = "${local.region}${count.index == 0 ? "a" : "b"}"
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.p}-private-${count.index}" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.p}-igw" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.p}-public" }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route  = []
  tags   = { Name = "${local.p}-private" }
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
  name   = "${local.p}-alb"
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
  name   = "${local.p}-ecs"
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
resource "aws_security_group" "rds" {
  name   = "${local.p}-rds"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress = []
}
resource "aws_security_group" "valkey" {
  name   = "${local.p}-valkey"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress = []
}
resource "aws_iam_role" "workload" {
  for_each           = local.roles
  name               = "${local.p}-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = contains(["ecs_execution", "ecs_task"], each.key) ? "ecs-tasks.amazonaws.com" : (each.key == "scheduler" ? "scheduler.amazonaws.com" : "lambda.amazonaws.com") } }] })
  tags               = { ClearLedgerRole = each.key }
}
resource "aws_kms_key" "store" {
  for_each                = local.usages
  description             = "${local.p}-${each.key}"
  enable_key_rotation     = true
  is_enabled              = true
  deletion_window_in_days = 10
  tags                    = { ClearLedgerKeyUsage = each.key }
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "RootAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${local.account}:root" }, Action = "kms:*", Resource = "*" },
    { Sid = "AuthorizedUsage", Effect = "Allow", Principal = { AWS = [for r in each.value : aws_iam_role.workload[r].arn] }, Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = "*" },
    { Sid = "WorkloadDestructionGuard", Effect = "Deny", Principal = { AWS = [for r in local.roles : aws_iam_role.workload[r].arn] }, Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = "*" },
    { Sid = "UnauthorizedUsageGuard", Effect = "Deny", Principal = { AWS = [for r in local.roles : aws_iam_role.workload[r].arn if !contains(each.value, r)] }, Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "*" }
  ] })
}
resource "aws_kms_alias" "store" {
  for_each      = local.usages
  name          = "alias/${local.p}-${each.key}"
  target_key_id = aws_kms_key.store[each.key].key_id
}
resource "aws_cloudwatch_log_group" "workload" {
  for_each          = local.log_names
  name              = "/clearledger/${local.p}/${each.value}"
  retention_in_days = 14
}
resource "aws_db_subnet_group" "main" {
  name       = "${local.p}-database"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "main" {
  identifier             = "${local.p}-database"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = local.c.db_name
  username               = local.c.db_username
  password               = var.config.db_password
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.store["database"].arn
  publicly_accessible    = false
  skip_final_snapshot    = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  apply_immediately      = true
  lifecycle { prevent_destroy = false }
}
resource "aws_dynamodb_table" "projection" {
  name         = "${local.p}-projections"
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
    kms_key_arn = aws_kms_key.store["projection"].arn
  }
}
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.p}-cache"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${local.p}-cache"
  description                = "${local.p} private cache"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.valkey.id]
  transit_encryption_enabled = false
  at_rest_encryption_enabled = false
  apply_immediately          = true
}
resource "aws_s3_bucket" "audit" {
  bucket        = "${local.p}-audit"
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
      kms_master_key_id = aws_kms_key.store["audit"].arn
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
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = aws_iam_role.workload["archiver"].arn }, Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"], Resource = "${local.bucket_arn}/ledger-audit/*" },
    { Effect = "Allow", Principal = { AWS = aws_iam_role.workload["archiver"].arn }, Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = local.bucket_arn },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : aws_iam_role.workload[r].arn] }, Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = [local.bucket_arn, "${local.bucket_arn}/*"] },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : aws_iam_role.workload[r].arn if r != "archiver"] }, Action = "s3:PutObject", Resource = [local.bucket_arn, "${local.bucket_arn}/*"] }
  ] })
}
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.p}-dlq"
  kms_master_key_id         = aws_kms_key.store["messaging"].arn
  message_retention_seconds = 1209600
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = aws_iam_role.workload["projector"].arn }, Action = "sqs:SendMessage", Resource = local.dlq_arn },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : aws_iam_role.workload[r].arn] }, Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = local.dlq_arn },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : aws_iam_role.workload[r].arn if r != "projector"] }, Action = "sqs:SendMessage", Resource = local.dlq_arn }
  ] })
}
resource "aws_sqs_queue" "main" {
  name                       = "${local.p}-events"
  kms_master_key_id          = aws_kms_key.store["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 4 })
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = [aws_iam_role.workload["ecs_task"].arn, aws_iam_role.workload["relay"].arn] }, Action = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = local.queue_arn },
    { Effect = "Allow", Principal = { AWS = aws_iam_role.workload["projector"].arn }, Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = local.queue_arn },
    { Effect = "Deny", Principal = { AWS = [for r in ["ecs_execution", "projector", "archiver", "scheduler"] : aws_iam_role.workload[r].arn] }, Action = "sqs:SendMessage", Resource = local.queue_arn },
    { Effect = "Deny", Principal = { AWS = [for r in local.roles : aws_iam_role.workload[r].arn if r != "projector"] }, Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = local.queue_arn }
  ] })
}
resource "aws_cognito_user_pool" "main" {
  name = "${local.p}-auth"
}
resource "aws_cognito_resource_server" "main" {
  identifier   = "clearledger"
  name         = "${local.p}-scopes"
  user_pool_id = aws_cognito_user_pool.main.id
  dynamic "scope" {
    for_each = toset(["read", "write", "admin"])
    content {
      scope_name        = scope.value
      scope_description = "ClearLedger ${scope.value}"
    }
  }
}
resource "aws_cognito_user_pool_client" "scope" {
  for_each                             = toset(["read", "write", "admin"])
  name                                 = "${local.p}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.main.identifier}/${each.key}"]
}
locals {
  database_url = "postgres://${local.c.db_username}:${urlencode(var.config.db_password)}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${local.c.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.main.primary_endpoint_address, aws_elasticache_replication_group.main.configuration_endpoint_address)
  valkey_url   = "redis://${local.valkey_host}:6379"
  common_env   = { AWS_REGION = local.region, AWS_DEFAULT_REGION = local.region, AWS_ACCESS_KEY_ID = "test", AWS_SECRET_ACCESS_KEY = "test", AWS_ENDPOINT_URL = local.endpoint }
  worker_env = {
    projector = { PROJECTION_TABLE = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url }
    relay     = { DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.main.url, OUTBOX_BATCH_SIZE = "50" }
    archiver  = { DATABASE_URL = local.database_url, AUDIT_BUCKET = aws_s3_bucket.audit.id, AUDIT_PREFIX = "ledger-audit/" }
  }
}
resource "aws_lambda_function" "worker" {
  for_each      = toset(["projector", "relay", "archiver"])
  function_name = "${local.p}-${each.key}"
  role          = aws_iam_role.workload[each.key].arn
  package_type  = "Image"
  image_uri     = local.c["${each.key}_image"]
  timeout       = 3
  memory_size   = 256
  image_config {
    command     = []
    entry_point = []
  }
  environment { variables = merge(local.common_env, local.worker_env[each.key], { CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.workload[each.key].name }) }
  depends_on = [aws_iam_role_policy.canonical]
}
resource "aws_lambda_event_source_mapping" "projector" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.worker["projector"].arn
  enabled                            = true
  batch_size                         = 5
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
}
resource "aws_scheduler_schedule" "worker" {
  for_each            = { relay = "rate(1 minute)", archiver = "rate(5 minutes)" }
  name                = "${local.p}-${each.key}"
  state               = "ENABLED"
  schedule_expression = each.value
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.worker[each.key].arn
    role_arn = aws_iam_role.workload["scheduler"].arn
    input    = "{}"
  }
}
resource "aws_lb" "api" {
  name               = "${local.p}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}
resource "aws_lb_target_group" "api" {
  name                 = "${local.p}-api"
  vpc_id               = aws_vpc.main.id
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  deregistration_delay = 5
  health_check {
    path              = "/health/ready"
    protocol          = "HTTP"
    matcher           = "200"
    interval          = 5
    timeout           = 2
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
  name = "${local.p}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.p}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.workload["ecs_execution"].arn
  task_role_arn            = aws_iam_role.workload["ecs_task"].arn
  container_definitions = jsonencode([{ name = "api", image = local.c.api_image, essential = true,
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }],
    environment = [for k, v in merge(local.common_env, {
      PORT                 = "8080", DATABASE_URL = local.database_url, SQS_QUEUE_URL = aws_sqs_queue.main.url,
      PROJECTION_TABLE     = aws_dynamodb_table.projection.name, VALKEY_URL = local.valkey_url,
      CACHE_TTL_SECONDS    = "90", AUTH_ISSUER = "${local.endpoint}/${aws_cognito_user_pool.main.id}",
      AUTH_JWKS_URL        = "${local.endpoint}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json",
      AUTH_AUDIENCES       = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.scope[k].id]),
      CLOUDWATCH_LOG_GROUP = aws_cloudwatch_log_group.workload["api"].name
    }) : { name = k, value = v }],
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.workload["api"].name, awslogs-region = local.region, awslogs-stream-prefix = "api" } }
  }])
  lifecycle { create_before_destroy = true }
}
resource "aws_ecs_service" "api" {
  name                               = "${local.p}-api"
  cluster                            = aws_ecs_cluster.api.id
  task_definition                    = aws_ecs_task_definition.api.arn
  launch_type                        = "FARGATE"
  desired_count                      = 2
  availability_zone_rebalancing      = "ENABLED"
  deployment_minimum_healthy_percent = 100
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
  depends_on = [aws_lb_listener.api, aws_iam_role_policy.canonical]
}
