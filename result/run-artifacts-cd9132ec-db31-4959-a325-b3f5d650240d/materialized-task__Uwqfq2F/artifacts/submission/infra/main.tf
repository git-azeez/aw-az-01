terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
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
  cfg = jsondecode(file(var.config_path))

  prefix       = local.cfg.resource_prefix
  region       = local.cfg.region
  endpoint     = local.cfg.aws_endpoint_url
  db_name      = local.cfg.db_name
  db_username  = local.cfg.db_username
  db_password  = local.cfg.db_password
  api_image    = local.cfg.api_image
  proj_image   = local.cfg.projector_image
  relay_image  = local.cfg.relay_image
  arch_image   = local.cfg.archiver_image
  account_id   = data.aws_caller_identity.current.account_id
  azs          = ["${local.cfg.region}a", "${local.cfg.region}b"]
  vpc_cidr     = "10.42.0.0/16"
  public_cidrs = ["10.42.0.0/24", "10.42.1.0/24"]
  priv_cidrs   = ["10.42.10.0/24", "10.42.11.0/24"]

  tags = {
    ClearLedgerDeployment = local.cfg.resource_prefix
    Project               = "clearledger"
  }
}

provider "aws" {
  region     = local.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    cloudwatchlogs = local.endpoint
    cognitoidp     = local.endpoint
    dynamodb       = local.endpoint
    ec2            = local.endpoint
    ecs            = local.endpoint
    elasticache    = local.endpoint
    elbv2          = local.endpoint
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
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}
