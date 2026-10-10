# ---------------------------------------------------------------------------
# CloudWatch Log Groups
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "lg" {
  for_each          = local.log_group_names
  name              = each.value
  retention_in_days = 14
  tags              = merge(local.tags, { ClearLedgerWorkload = each.key })
}

# ---------------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.p}-settlement-events-dlq"
  kms_master_key_id         = aws_kms_key.key["messaging"].arn
  message_retention_seconds = 1209600
  tags                      = local.tags
}

resource "aws_sqs_queue" "main" {
  name                       = "${local.p}-settlement-events"
  kms_master_key_id          = aws_kms_key.key["messaging"].arn
  visibility_timeout_seconds = 3
  receive_wait_time_seconds  = 2
  message_retention_seconds  = 172800
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 4
  })
  tags = local.tags
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.p}-settlement-events-policy"
    Statement = [
      {
        Sid       = "AllowPublishers"
        Effect    = "Allow"
        Principal = { AWS = [aws_iam_role.ecs_task.arn, aws_iam_role.relay.arn] }
        Action    = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid       = "AllowProjectorConsumer"
        Effect    = "Allow"
        Principal = { AWS = [aws_iam_role.projector.arn] }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid    = "DenyNonPublisherSend"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn, aws_iam_role.projector.arn,
          aws_iam_role.archiver.arn, aws_iam_role.scheduler.arn,
        ] }
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.main.arn
      },
      {
        Sid    = "DenyNonConsumerReceive"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn, aws_iam_role.ecs_task.arn, aws_iam_role.relay.arn,
          aws_iam_role.archiver.arn, aws_iam_role.scheduler.arn,
        ] }
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = aws_sqs_queue.main.arn
      },
    ]
  })
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.p}-settlement-events-dlq-policy"
    Statement = [
      {
        Sid       = "AllowProjectorDeadLetter"
        Effect    = "Allow"
        Principal = { AWS = [aws_iam_role.projector.arn] }
        Action    = ["sqs:SendMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid       = "DenyWorkloadConsume"
        Effect    = "Deny"
        Principal = { AWS = values(local.role_arns) }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource  = aws_sqs_queue.dlq.arn
      },
      {
        Sid    = "DenyNonProjectorSend"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn, aws_iam_role.ecs_task.arn, aws_iam_role.relay.arn,
          aws_iam_role.archiver.arn, aws_iam_role.scheduler.arn,
        ] }
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# DynamoDB projection store
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "projections" {
  name         = "${local.p}-settlement-projections"
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
    kms_key_arn = aws_kms_key.key["projection"].arn
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# S3 audit archive
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "audit" {
  bucket        = "${local.p}-ledger-audit-${local.account_id}"
  force_destroy = true
  tags          = local.tags
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
      kms_master_key_id = aws_kms_key.key["audit"].arn
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
    Id      = "${local.p}-ledger-audit-policy"
    Statement = [
      {
        Sid       = "AllowArchiverObjectAppend"
        Effect    = "Allow"
        Principal = { AWS = [aws_iam_role.archiver.arn] }
        Action    = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource  = "${aws_s3_bucket.audit.arn}/ledger-audit/*"
      },
      {
        Sid       = "AllowArchiverBucketMetadata"
        Effect    = "Allow"
        Principal = { AWS = [aws_iam_role.archiver.arn] }
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = aws_s3_bucket.audit.arn
      },
      {
        Sid       = "DenyWorkloadDeletes"
        Effect    = "Deny"
        Principal = { AWS = values(local.role_arns) }
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
      {
        Sid    = "DenyNonArchiverWrites"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn, aws_iam_role.ecs_task.arn, aws_iam_role.projector.arn,
          aws_iam_role.relay.arn, aws_iam_role.scheduler.arn,
        ] }
        Action   = ["s3:PutObject"]
        Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.audit]
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${local.p}-db-subnets"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

resource "aws_db_instance" "main" {
  identifier              = "${local.p}-postgres"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.key["database"].arn
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
  backup_retention_period = 1
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  tags                    = local.tags
}

# ---------------------------------------------------------------------------
# ElastiCache for Valkey
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.p}-cache-subnets"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

resource "aws_elasticache_replication_group" "cache" {
  replication_group_id       = "${local.p}-valkey"
  description                = "ClearLedger settlement projection cache"
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
  tags                       = local.tags
}

# ---------------------------------------------------------------------------
# Cognito
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "main" {
  name = "${local.p}-users"
  tags = local.tags
}

resource "aws_cognito_resource_server" "api" {
  user_pool_id = aws_cognito_user_pool.main.id
  identifier   = "clearledger"
  name         = "${local.p}-clearledger-api"

  scope {
    scope_name        = "read"
    scope_description = "Read settlement projections and ledgers"
  }
  scope {
    scope_name        = "write"
    scope_description = "Initiate settlements and append ledger entries"
  }
  scope {
    scope_name        = "admin"
    scope_description = "Administrative projection rebuilds"
  }
}

locals {
  cognito_clients = {
    read  = "clearledger/read"
    write = "clearledger/write"
    admin = "clearledger/admin"
  }
}

resource "aws_cognito_user_pool_client" "client" {
  for_each                             = local.cognito_clients
  name                                 = "${local.p}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [each.value]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  depends_on                           = [aws_cognito_resource_server.api]
}
