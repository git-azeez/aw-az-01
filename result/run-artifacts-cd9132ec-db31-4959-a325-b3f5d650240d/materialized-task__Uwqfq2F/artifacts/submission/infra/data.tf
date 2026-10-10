# ---------------------------------------------------------------------------
# RDS PostgreSQL (system of record)
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name        = "${local.prefix}-db-subnets"
  description = "ClearLedger PostgreSQL private subnets"
  subnet_ids  = aws_subnet.private[*].id

  tags = { Name = "${local.prefix}-db-subnets" }
}

resource "aws_db_instance" "main" {
  identifier     = "${local.prefix}-postgres"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.this["database"].arn

  db_name  = local.db_name
  username = local.db_username
  password = local.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period  = 1
  skip_final_snapshot      = true
  deletion_protection      = false
  apply_immediately        = true
  delete_automated_backups = true

  tags = { Name = "${local.prefix}-postgres" }

  lifecycle {
    # The instance holds committed ledger data; never let cosmetic/emulator
    # drift on these attributes force a replacement.
    ignore_changes = [engine_version, availability_zone, snapshot_identifier, kms_key_id, storage_type, allocated_storage]
  }
}

# ---------------------------------------------------------------------------
# DynamoDB projection store
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "projections" {
  name         = local.names.table
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

  tags = { Name = local.names.table }
}

# ---------------------------------------------------------------------------
# ElastiCache for Valkey
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name        = "${local.prefix}-cache-subnets"
  description = "ClearLedger Valkey private subnets"
  subnet_ids  = aws_subnet.private[*].id

  tags = { Name = "${local.prefix}-cache-subnets" }
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "${local.prefix}-valkey"
  description          = "ClearLedger settlement projection cache"

  engine             = "valkey"
  engine_version     = "8.0"
  node_type          = "cache.t4g.micro"
  num_cache_clusters = 1
  port               = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.valkey.id]

  automatic_failover_enabled = false
  multi_az_enabled           = false
  apply_immediately          = true

  tags = { Name = "${local.prefix}-valkey" }

  lifecycle {
    # The local control plane may relocate the endpoint port; never replace
    # the cache because of it.
    ignore_changes = [port, engine_version, parameter_group_name, security_group_ids]
  }
}

# ---------------------------------------------------------------------------
# S3 audit archive
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "audit" {
  bucket        = local.names.bucket
  force_destroy = true

  tags = { Name = local.names.bucket }
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
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# SQS main queue + DLQ
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = local.names.dlq
  kms_master_key_id         = aws_kms_key.this["messaging"].arn
  message_retention_seconds = 1209600

  tags = { Name = local.names.dlq }
}

resource "aws_sqs_queue" "main" {
  name                       = local.names.queue
  kms_master_key_id          = aws_kms_key.this["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 4
  })

  tags = { Name = local.names.queue }
}
