terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.51.0" }
  }
  backend "local" { path = "terraform.tfstate" }
}

variable "config" { type = map(string) }
locals {
  c        = var.config
  p        = local.c.resource_prefix
  region   = local.c.region
  endpoint = local.c.aws_endpoint_url
  account  = "000000000000"
  roles    = toset(["ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler"])
  key_roles = {
    database   = ["relay", "archiver"]
    messaging  = ["ecs_task", "projector", "relay"]
    projection = ["ecs_task", "projector"]
    audit      = ["archiver"]
  }
  role_arns   = { for r in local.roles : r => "arn:aws:iam::${local.account}:role/${local.p}-${r}" }
  worker_arns = { for r in ["projector", "relay", "archiver"] : r => "arn:aws:lambda:${local.region}:${local.account}:function:${local.p}-${r}" }
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
  availability_zone       = "${local.region}${["a", "b"][count.index]}"
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.p}-public-${count.index}" }
}
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.${count.index + 10}.0/24"
  availability_zone       = "${local.region}${["a", "b"][count.index]}"
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
resource "aws_security_group" "store" {
  for_each = { rds = 5432, valkey = 6379 }
  name     = "${local.p}-${each.key}"
  vpc_id   = aws_vpc.main.id
  ingress {
    from_port   = each.value
    to_port     = each.value
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress = []
}
resource "aws_kms_key" "key" {
  for_each                = local.key_roles
  description             = "${local.p}-${each.key}"
  enable_key_rotation     = true
  is_enabled              = true
  deletion_window_in_days = 10
  tags                    = { ClearLedgerKeyUsage = each.key, Name = "${local.p}-${each.key}" }
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "RootAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${local.account}:root" }, Action = "kms:*", Resource = "*" },
    { Sid = "WorkloadUsage", Effect = "Allow", Principal = { AWS = [for r in each.value : local.role_arns[r]] }, Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = "*" },
    { Sid = "ProtectKeys", Effect = "Deny", Principal = { AWS = values(local.role_arns) }, Action = ["kms:DisableKey", "kms:ScheduleKeyDeletion"], Resource = "*" },
    { Sid = "IsolateKeys", Effect = "Deny", Principal = { AWS = [for r in local.roles : local.role_arns[r] if !contains(each.value, r)] }, Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "*" }
  ] })
  depends_on = [aws_iam_role.role]
}
resource "aws_kms_alias" "key" {
  for_each      = local.key_roles
  name          = "alias/${local.p}-${each.key}"
  target_key_id = aws_kms_key.key[each.key].key_id
}
resource "aws_cloudwatch_log_group" "log" {
  for_each          = { api = "api", projector = "projector", relay = "outbox-relay", archiver = "audit-archiver" }
  name              = "/clearledger/${local.p}/${each.value}"
  retention_in_days = 14
}
resource "aws_db_subnet_group" "main" {
  name       = "${local.p}-database"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "main" {
  identifier              = "${local.p}-database"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = local.c.db_name
  username                = local.c.db_username
  password                = local.c.db_password
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.key["database"].arn
  publicly_accessible     = false
  skip_final_snapshot     = true
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.store["rds"].id]
  apply_immediately       = true
  backup_retention_period = 7
}
resource "aws_dynamodb_table" "main" {
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
    kms_key_arn = aws_kms_key.key["projection"].arn
  }
}
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.p}-cache"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${local.p}-cache"
  description                = "${local.p} projection cache"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.store["valkey"].id]
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
      kms_master_key_id = aws_kms_key.key["audit"].arn
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
  name                      = "${local.p}-dlq"
  kms_master_key_id         = aws_kms_key.key["messaging"].arn
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "main" {
  name                       = "${local.p}-events"
  kms_master_key_id          = aws_kms_key.key["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 4 })
}
resource "aws_cognito_user_pool" "main" { name = "${local.p}-auth" }
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
resource "aws_cognito_user_pool_client" "client" {
  for_each                             = toset(["read", "write", "admin"])
  name                                 = "${local.p}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/${each.key}"]
  depends_on                           = [aws_cognito_resource_server.main]
}
