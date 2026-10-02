# RDS PostgreSQL (`services/rds.md`)

- Provision a DB subnet group (`aws_db_subnet_group`) spanning the private subnets.
- Provision a single PostgreSQL 16 RDS instance (`aws_db_instance`) with:
  - `engine = "postgres"`
  - `engine_version = "16.3"` (or `16.*`)
  - `instance_class = "db.t4g.micro"`
  - `db_name`, `username`, and `password` from `/workspace/config/config.json`
  - `storage_encrypted = true`
  - `kms_key_id` set to the customer-managed `database` KMS key ARN (`kms.database_arn`)
  - `publicly_accessible = false`
  - `skip_final_snapshot = true`
  - `vpc_security_group_ids` containing the `rds` security group
- Re-running `deploy.sh` must never replace the RDS instance or lose committed data.
