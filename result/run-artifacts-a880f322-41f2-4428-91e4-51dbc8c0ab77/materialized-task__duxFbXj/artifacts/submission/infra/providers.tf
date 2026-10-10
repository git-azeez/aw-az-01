terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

variable "config_path" {
  description = "Path to the ClearLedger deployment configuration (config.json)."
  type        = string
  default     = "/workspace/config/config.json"
}

locals {
  cfg      = jsondecode(file(var.config_path))
  prefix   = local.cfg.resource_prefix
  region   = local.cfg.region
  endpoint = local.cfg.aws_endpoint_url

  azs = ["${local.region}a", "${local.region}b"]

  tags = {
    ClearLedgerDeployment = local.prefix
  }
}

provider "aws" {
  region     = local.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    acm            = local.endpoint
    cloudwatch     = local.endpoint
    cloudwatchlogs = local.endpoint
    cognitoidp     = local.endpoint
    dynamodb       = local.endpoint
    ec2            = local.endpoint
    ecs            = local.endpoint
    elasticache    = local.endpoint
    elb            = local.endpoint
    elbv2          = local.endpoint
    events         = local.endpoint
    iam            = local.endpoint
    kms            = local.endpoint
    lambda         = local.endpoint
    rds            = local.endpoint
    s3             = local.endpoint
    scheduler      = local.endpoint
    sqs            = local.endpoint
    sts            = local.endpoint
  }

  default_tags {
    tags = {
      ClearLedgerDeployment = local.prefix
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
