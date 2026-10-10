terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "config_file" {
  description = "Path to the runtime configuration JSON"
  type        = string
  default     = "/workspace/config/config.json"
}

locals {
  config   = jsondecode(file(var.config_file))
  prefix   = local.config.resource_prefix
  region   = local.config.region
  endpoint = local.config.aws_endpoint_url

  tags = {
    ClearLedgerDeployment = local.prefix
  }

  azs = ["us-east-1a", "us-east-1b"]

  api_log_group       = "/clearledger/${local.prefix}/api"
  projector_log_group = "/clearledger/${local.prefix}/projector"
  relay_log_group     = "/clearledger/${local.prefix}/outbox-relay"
  archiver_log_group  = "/clearledger/${local.prefix}/audit-archiver"

  database_url = "postgres://${local.config.db_username}:${local.config.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${local.config.db_name}"
  valkey_url   = "redis://${local.valkey_endpoint}:${local.valkey_port}"

  # Endpoint as seen from inside containers / lambdas.
  runtime_endpoint = local.endpoint
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
    elb            = local.endpoint
    ecs            = local.endpoint
    rds            = local.endpoint
    elasticache    = local.endpoint
    s3             = local.endpoint
    sqs            = local.endpoint
    lambda         = local.endpoint
    scheduler      = local.endpoint
    cognitoidp     = local.endpoint
    iam            = local.endpoint
    kms            = local.endpoint
    cloudwatchlogs = local.endpoint
    dynamodb       = local.endpoint
    sts            = local.endpoint
    ecr            = local.endpoint
  }

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
