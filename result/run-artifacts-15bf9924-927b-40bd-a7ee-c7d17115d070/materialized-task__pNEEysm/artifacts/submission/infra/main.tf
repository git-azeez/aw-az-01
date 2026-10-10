variable "config_file" {
  description = "Path to the deployment inputs"
  type        = string
  default     = "/workspace/config/config.json"
}

locals {
  cfg      = jsondecode(file(var.config_file))
  prefix   = local.cfg.resource_prefix
  region   = local.cfg.region
  endpoint = local.cfg.aws_endpoint_url

  tags = {
    ClearLedgerDeployment = local.prefix
  }

  # The local control plane fronts the ALB listener on <endpoint-host>:80.
  endpoint_host = regex("^https?://([^:/]+)", local.cfg.aws_endpoint_url)[0]

  azs = ["${local.region}a", "${local.region}b"]

  api_log_group_name       = "/clearledger/${local.prefix}/api"
  projector_log_group_name = "/clearledger/${local.prefix}/projector"
  relay_log_group_name     = "/clearledger/${local.prefix}/outbox-relay"
  archiver_log_group_name  = "/clearledger/${local.prefix}/audit-archiver"

  database_url = "postgres://${local.cfg.db_username}:${local.cfg.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${local.cfg.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.valkey.primary_endpoint_address, aws_elasticache_replication_group.valkey.configuration_endpoint_address)
  valkey_url   = "redis://${local.valkey_host}:6379"

  # Credentials/region injected explicitly: the workers talk to the local control plane.
  base_env = {
    AWS_REGION            = local.region
    AWS_DEFAULT_REGION    = local.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = local.endpoint
  }
}

provider "aws" {
  region                      = local.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    ec2            = local.endpoint
    elbv2          = local.endpoint
    ecs            = local.endpoint
    rds            = local.endpoint
    elasticache    = local.endpoint
    dynamodb       = local.endpoint
    s3             = local.endpoint
    sqs            = local.endpoint
    lambda         = local.endpoint
    scheduler      = local.endpoint
    cognitoidp     = local.endpoint
    iam            = local.endpoint
    kms            = local.endpoint
    cloudwatchlogs = local.endpoint
    sts            = local.endpoint
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
