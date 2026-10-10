resource "aws_db_subnet_group" "db" {
  name       = "${local.prefix}-database"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "db" {
  identifier              = "${local.prefix}-database"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = local.config.db_name
  username                = local.config.db_username
  password                = sensitive(local.config.db_password)
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.key["database"].arn
  publicly_accessible     = false
  skip_final_snapshot     = true
  db_subnet_group_name    = aws_db_subnet_group.db.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
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
    kms_key_arn = aws_kms_key.key["projection"].arn
  }
}
resource "aws_elasticache_subnet_group" "cache" {
  name       = "${local.prefix}-cache"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "cache" {
  replication_group_id       = "${local.prefix}-cache"
  description                = "${local.prefix} projections cache"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.cache.name
  security_group_ids         = [aws_security_group.valkey.id]
  transit_encryption_enabled = false
  at_rest_encryption_enabled = false
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
  name                      = "${local.prefix}-events-dlq"
  kms_master_key_id         = aws_kms_key.key["messaging"].arn
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "events" {
  name                       = "${local.prefix}-events"
  kms_master_key_id          = aws_kms_key.key["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 4 })
}
