resource "aws_s3_bucket" "audit" {
  bucket        = "${local.prefix}-audit-archive"
  force_destroy = true

  tags = local.tags
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
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id

  depends_on = [aws_s3_bucket_public_access_block.audit]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ArchiverWriteAuditObjects"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.archiver.arn }
        Action    = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource  = "${aws_s3_bucket.audit.arn}/ledger-audit/*"
      },
      {
        Sid       = "ArchiverListBucket"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.archiver.arn }
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = aws_s3_bucket.audit.arn
      },
      {
        Sid       = "DenyWorkloadDeletes"
        Effect    = "Deny"
        Principal = { AWS = local.all_role_arns }
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
      {
        Sid    = "DenyNonArchiverWrites"
        Effect = "Deny"
        Principal = { AWS = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn,
          aws_iam_role.projector.arn,
          aws_iam_role.relay.arn,
          aws_iam_role.scheduler.arn,
        ] }
        Action   = ["s3:PutObject"]
        Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
    ]
  })
}
