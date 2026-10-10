resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = local.tags
}

resource "aws_db_instance" "main" {
  identifier     = "${local.prefix}-db"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.t4g.micro"

  allocated_storage = 20

  db_name  = local.config.db_name
  username = local.config.db_username
  password = local.config.db_password

  storage_encrypted      = true
  kms_key_id             = aws_kms_key.database.arn
  publicly_accessible    = false
  skip_final_snapshot    = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  apply_immediately      = true

  tags = local.tags
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.prefix}-cache-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = local.tags
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "${local.prefix}-valkey"
  description          = "ClearLedger settlement projection cache"

  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  port                 = 6379
  parameter_group_name = "default.valkey8"

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.valkey.id]

  transit_encryption_enabled = false
  at_rest_encryption_enabled = false
  automatic_failover_enabled = false
  apply_immediately          = true

  tags = local.tags
}
