terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.51.0"
    }
  }
}

variable "config_file" {
  description = "Path to the deployment inputs (config.json)."
  type        = string
  default     = "/workspace/config/config.json"
}

locals {
  cfg = jsondecode(file(var.config_file))

  prefix       = local.cfg.resource_prefix
  region       = local.cfg.region
  endpoint_url = local.cfg.aws_endpoint_url

  db_name     = local.cfg.db_name
  db_username = local.cfg.db_username
  db_password = local.cfg.db_password

  images = {
    api       = local.cfg.api_image
    projector = local.cfg.projector_image
    relay     = local.cfg.relay_image
    archiver  = local.cfg.archiver_image
  }
  image_ids = {
    api       = local.cfg.api_image_id
    projector = local.cfg.projector_image_id
    relay     = local.cfg.relay_image_id
    archiver  = local.cfg.archiver_image_id
  }

  tags = {
    ClearLedgerDeployment = local.prefix
  }

  azs = ["${local.region}a", "${local.region}b"]
}

provider "aws" {
  region     = local.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    ec2         = local.endpoint_url
    iam         = local.endpoint_url
    sts         = local.endpoint_url
    kms         = local.endpoint_url
    logs        = local.endpoint_url
    s3          = local.endpoint_url
    sqs         = local.endpoint_url
    dynamodb    = local.endpoint_url
    elasticache = local.endpoint_url
    rds         = local.endpoint_url
    lambda      = local.endpoint_url
    ecs         = local.endpoint_url
    elbv2       = local.endpoint_url
    cognitoidp  = local.endpoint_url
    scheduler   = local.endpoint_url
  }

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
