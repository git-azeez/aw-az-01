# ---------------------------------------------------------------------------
# RDS PostgreSQL
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db"
  subnet_ids = aws_subnet.private[*].id
  tags       = merge(local.tags, { Name = "${local.prefix}-db" })
}

resource "aws_db_instance" "main" {
  identifier             = "${local.prefix}-db"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = local.config.db_name
  username               = local.config.db_username
  password               = local.config.db_password
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.this["database"].arn
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  tags                   = merge(local.tags, { Name = "${local.prefix}-db" })

  lifecycle {
    # Never replace the database (and lose committed data) because of
    # non-functional attribute drift.
    ignore_changes = [engine_version, password, kms_key_id, db_name, username]
  }
}

# ---------------------------------------------------------------------------
# DynamoDB projection table
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "projections" {
  name         = "${local.prefix}-projections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "AccountIndex"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.this["projection"].arn
  }

  tags = merge(local.tags, { Name = "${local.prefix}-projections" })
}

# ---------------------------------------------------------------------------
# ElastiCache for Valkey
# ---------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.prefix}-valkey"
  subnet_ids = aws_subnet.private[*].id
  tags       = merge(local.tags, { Name = "${local.prefix}-valkey" })
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "${local.prefix}-valkey"
  description          = "ClearLedger projection cache (${local.prefix})"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.valkey.id]
  apply_immediately    = true
  tags                 = merge(local.tags, { Name = "${local.prefix}-valkey" })

  lifecycle {
    # Security group membership is not echoed back by the control plane.
    ignore_changes = [security_group_ids]
  }
}

locals {
  valkey_endpoint = coalesce(
    try(aws_elasticache_replication_group.valkey.primary_endpoint_address, null),
    try(aws_elasticache_replication_group.valkey.configuration_endpoint_address, null),
    try(aws_elasticache_replication_group.valkey.reader_endpoint_address, null),
  )
  valkey_port = aws_elasticache_replication_group.valkey.port
}

# ---------------------------------------------------------------------------
# S3 audit archive
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "audit" {
  bucket        = "${local.prefix}-audit"
  force_destroy = true
  tags          = merge(local.tags, { Name = "${local.prefix}-audit" })
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this["audit"].arn
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

# ---------------------------------------------------------------------------
# SQS main queue + DLQ
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-events-dlq"
  kms_master_key_id         = aws_kms_key.this["messaging"].arn
  message_retention_seconds = 1209600
  tags                      = merge(local.tags, { Name = "${local.prefix}-events-dlq" })
}

resource "aws_sqs_queue" "main" {
  name                       = "${local.prefix}-events"
  kms_master_key_id          = aws_kms_key.this["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 4
  })
  tags = merge(local.tags, { Name = "${local.prefix}-events" })
}
