terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "config_path" {
  description = "Path to the deployment inputs file"
  type        = string
  default     = "/workspace/config/config.json"
}

locals {
  cfg      = jsondecode(file(var.config_path))
  prefix   = local.cfg.resource_prefix
  region   = local.cfg.region
  endpoint = local.cfg.aws_endpoint_url
  azs      = ["${local.region}a", "${local.region}b"]
  tags     = { ClearLedgerDeployment = local.prefix }

  db_password = sensitive(local.cfg.db_password)
}

provider "aws" {
  region     = local.region
  access_key = "test"
  secret_key = "test"

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
    dynamodb       = local.endpoint
    elasticache    = local.endpoint
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
