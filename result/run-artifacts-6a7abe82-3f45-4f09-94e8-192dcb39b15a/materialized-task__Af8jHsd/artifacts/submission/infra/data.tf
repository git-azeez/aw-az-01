# ---------------------------------------------------------------------------
# RDS PostgreSQL
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db-subnets"
  subnet_ids = aws_subnet.private[*].id
  tags       = merge(local.tags, { Name = "${local.prefix}-db-subnets" })
}

resource "aws_db_instance" "main" {
  identifier             = "${local.prefix}-postgres"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = local.cfg.db_name
  username               = local.cfg.db_username
  password               = local.cfg.db_password
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.this["database"].arn
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  tags = merge(local.tags, { Name = "${local.prefix}-postgres" })

  lifecycle {
    # Never replace the system of record because of cosmetic/emulated drift.
    ignore_changes = [kms_key_id, storage_encrypted, engine_version, db_name, username, allocated_storage, availability_zone]
  }
}

# ---------------------------------------------------------------------------
# DynamoDB projection store
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
  name       = "${local.prefix}-cache-subnets"
  subnet_ids = aws_subnet.private[*].id
  tags       = merge(local.tags, { Name = "${local.prefix}-cache-subnets" })
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id       = "${local.prefix}-valkey"
  description                = "ClearLedger projection cache"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.valkey.id]
  transit_encryption_enabled = false
  at_rest_encryption_enabled = false
  automatic_failover_enabled = false
  apply_immediately          = true

  tags = merge(local.tags, { Name = "${local.prefix}-valkey" })

  lifecycle {
    # Security group membership is not echoed back by the local control plane.
    ignore_changes = [security_group_ids]
  }
}

# ---------------------------------------------------------------------------
# S3 audit archive
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "audit" {
  bucket        = "${local.prefix}-ledger-audit"
  force_destroy = true
  tags          = merge(local.tags, { Name = "${local.prefix}-ledger-audit" })
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

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ArchiverWriteAuditObjects"
        Effect    = "Allow"
        Principal = { AWS = [local.role_arns.archiver] }
        Action    = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource  = ["${aws_s3_bucket.audit.arn}/ledger-audit/*"]
      },
      {
        Sid       = "ArchiverBucketMetadata"
        Effect    = "Allow"
        Principal = { AWS = [local.role_arns.archiver] }
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = [aws_s3_bucket.audit.arn]
      },
      {
        Sid       = "DenyWorkloadDeletes"
        Effect    = "Deny"
        Principal = { AWS = [for r in local.role_keys : local.role_arns[r]] }
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
      {
        Sid       = "DenyNonArchiverWrites"
        Effect    = "Deny"
        Principal = { AWS = [for r in local.role_keys : local.role_arns[r] if r != "archiver"] }
        Action    = ["s3:PutObject"]
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.audit, aws_iam_role.role]
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

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPublishers"
        Effect    = "Allow"
        Principal = { AWS = [local.role_arns.ecs_task, local.role_arns.relay] }
        Action    = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid       = "AllowProjectorConsume"
        Effect    = "Allow"
        Principal = { AWS = [local.role_arns.projector] }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid       = "DenyNonPublisherSend"
        Effect    = "Deny"
        Principal = { AWS = [local.role_arns.ecs_execution, local.role_arns.projector, local.role_arns.archiver, local.role_arns.scheduler] }
        Action    = ["sqs:SendMessage"]
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid       = "DenyNonConsumerReceive"
        Effect    = "Deny"
        Principal = { AWS = [local.role_arns.ecs_execution, local.role_arns.ecs_task, local.role_arns.relay, local.role_arns.archiver, local.role_arns.scheduler] }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource  = aws_sqs_queue.main.arn
      },
    ]
  })
  depends_on = [aws_iam_role.role]
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowProjectorDeadLetter"
        Effect    = "Allow"
        Principal = { AWS = [local.role_arns.projector] }
        Action    = ["sqs:SendMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid       = "DenyWorkloadConsume"
        Effect    = "Deny"
        Principal = { AWS = [for r in local.role_keys : local.role_arns[r]] }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid       = "DenyNonProjectorSend"
        Effect    = "Deny"
        Principal = { AWS = [for r in local.role_keys : local.role_arns[r] if r != "projector"] }
        Action    = ["sqs:SendMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
    ]
  })
  depends_on = [aws_iam_role.role]
}
