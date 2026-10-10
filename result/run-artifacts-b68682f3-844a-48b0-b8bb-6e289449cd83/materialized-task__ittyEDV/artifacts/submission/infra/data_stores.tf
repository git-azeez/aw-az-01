# ---------------------------------------------------------------- DynamoDB
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

# ---------------------------------------------------------------------- S3
resource "aws_s3_bucket" "audit" {
  bucket        = "${local.prefix}-audit"
  force_destroy = true

  tags = merge(local.tags, { Name = "${local.prefix}-audit" })
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
        Sid       = "ArchiverObjectAccess"
        Effect    = "Allow"
        Principal = { AWS = local.r_arn["archiver"] }
        Action    = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource  = "${aws_s3_bucket.audit.arn}/ledger-audit/*"
      },
      {
        Sid       = "ArchiverBucketAccess"
        Effect    = "Allow"
        Principal = { AWS = local.r_arn["archiver"] }
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = aws_s3_bucket.audit.arn
      },
      {
        Sid       = "DenyDeletesForAllWorkloads"
        Effect    = "Deny"
        Principal = { AWS = [for r in local.role_names : local.r_arn[r]] }
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
      {
        Sid    = "DenyWritesForNonArchivers"
        Effect = "Deny"
        Principal = {
          AWS = [for r in ["ecs_execution", "ecs_task", "projector", "relay", "scheduler"] : local.r_arn[r]]
        }
        Action   = ["s3:PutObject"]
        Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.audit]
}

# ------------------------------------------------------------------- RDS
resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = merge(local.tags, { Name = "${local.prefix}-db" })
}

resource "aws_db_instance" "main" {
  identifier             = "${local.prefix}-db"
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
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  apply_immediately      = true

  tags = merge(local.tags, { Name = "${local.prefix}-db" })

  lifecycle {
    ignore_changes = [password, engine_version]
  }
}

# ---------------------------------------------------------------- Valkey
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.prefix}-cache"
  subnet_ids = aws_subnet.private[*].id

  tags = merge(local.tags, { Name = "${local.prefix}-cache" })
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
    # The local control plane does not echo cache security groups back.
    ignore_changes = [security_group_ids]
  }
}
