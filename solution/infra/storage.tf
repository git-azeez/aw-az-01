resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db-subnets"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-db-subnets"
  })
}

resource "aws_db_instance" "main" {
  identifier             = "${local.prefix}-postgres"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  kms_key_id             = aws_kms_key.database.arn
  storage_encrypted      = true
  publicly_accessible    = false
  skip_final_snapshot    = true

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-postgres"
  })
}

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
    kms_key_arn = aws_kms_key.projection.arn
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-projections"
  })
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.prefix}-valkey-subnets"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-valkey-subnets"
  })
}

resource "aws_elasticache_cluster" "valkey" {
  cluster_id           = "${local.prefix}-valkey"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.t4g.micro"
  num_cache_nodes      = 1
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.valkey.id]

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-valkey"
  })
}

resource "aws_s3_bucket" "audit" {
  bucket        = "${local.prefix}-audit-archive"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-audit-archive"
  })
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
      kms_master_key_id = aws_kms_key.audit.arn
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

locals {
  database_url = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_host  = try(aws_elasticache_cluster.valkey.cache_nodes[0].address, "aws")
  valkey_port  = try(aws_elasticache_cluster.valkey.cache_nodes[0].port, aws_elasticache_cluster.valkey.port)
  valkey_url   = "redis://${local.valkey_host}:${local.valkey_port}"
}
