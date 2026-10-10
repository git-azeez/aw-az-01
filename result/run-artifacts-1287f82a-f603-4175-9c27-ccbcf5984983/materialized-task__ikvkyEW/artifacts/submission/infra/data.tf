# ---------------------------------------------------------------- RDS ----
resource "aws_db_subnet_group" "main" {
  name        = "${local.p}-db-subnets"
  description = "ClearLedger PostgreSQL private subnets"
  subnet_ids  = aws_subnet.private[*].id

  tags = { Name = "${local.p}-db-subnets" }
}

resource "aws_db_instance" "main" {
  identifier             = "${local.p}-postgres"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.this["database"].arn
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  apply_immediately      = true

  tags = { Name = "${local.p}-postgres" }

  lifecycle {
    # Never let cosmetic emulator differences force a replacement of the
    # system of record.
    ignore_changes = [engine_version, allocated_storage, port, availability_zone]
  }
}

# ----------------------------------------------------------- DynamoDB ----
resource "aws_dynamodb_table" "projections" {
  name         = "${local.p}-projections"
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

  tags = { Name = "${local.p}-projections" }
}

# ------------------------------------------------------------- Valkey ----
resource "aws_elasticache_subnet_group" "main" {
  name        = "${local.p}-cache-subnets"
  description = "ClearLedger Valkey private subnets"
  subnet_ids  = aws_subnet.private[*].id

  tags = { Name = "${local.p}-cache-subnets" }
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id       = "${local.p}-valkey"
  description                = "ClearLedger projection cache"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.valkey.id]
  automatic_failover_enabled = false
  apply_immediately          = true

  tags = { Name = "${local.p}-valkey" }

  lifecycle {
    # The emulator may serve the cache on a different proxy port than the
    # requested one; never replace the cache because of that.
    ignore_changes = [port, engine_version, parameter_group_name]
  }
}

# ----------------------------------------------------------------- S3 ----
resource "aws_s3_bucket" "audit" {
  bucket        = "${local.p}-audit-archive"
  force_destroy = true

  tags = { Name = "${local.p}-audit-archive" }
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
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- SQS ----
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.p}-events-dlq"
  kms_master_key_id         = aws_kms_key.this["messaging"].arn
  message_retention_seconds = 1209600

  tags = { Name = "${local.p}-events-dlq" }
}

resource "aws_sqs_queue" "main" {
  name                       = "${local.p}-events"
  kms_master_key_id          = aws_kms_key.this["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 4
  })

  tags = { Name = "${local.p}-events" }
}
