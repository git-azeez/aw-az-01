locals {
  cfg            = jsondecode(file(var.config_file))
  prefix         = local.cfg.resource_prefix
  region         = local.cfg.region
  endpoint       = local.cfg.aws_endpoint_url
  account_id     = data.aws_caller_identity.current.account_id
  common_tags    = { ClearLedgerDeployment = local.prefix }
  azs            = ["${local.region}a", "${local.region}b"]
  vpc_cidr       = "10.42.0.0/16"
  public_cidrs   = ["10.42.0.0/24", "10.42.1.0/24"]
  private_cidrs  = ["10.42.10.0/24", "10.42.11.0/24"]
  runtime_aws_ep = "http://aws:4566"
}

provider "aws" {
  region     = local.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = false
  s3_use_path_style           = true
  http_proxy                  = var.aws_proxy != "" ? var.aws_proxy : null
  https_proxy                 = var.aws_proxy != "" ? var.aws_proxy : null
  no_proxy                    = var.aws_proxy != "" ? "aws,localhost,127.0.0.1" : null

  endpoints {
    ec2                  = local.endpoint
    elbv2                = local.endpoint
    elasticloadbalancing = local.endpoint
    ecs                  = local.endpoint
    rds                  = local.endpoint
    dynamodb             = local.endpoint
    elasticache          = local.endpoint
    s3                   = local.endpoint
    sqs                  = local.endpoint
    lambda               = local.endpoint
    scheduler            = local.endpoint
    cognitoidp           = local.endpoint
    iam                  = local.endpoint
    kms                  = local.endpoint
    cloudwatchlogs       = local.endpoint
    sts                  = local.endpoint
    s3control            = "http://s3control.clearledger.test:4566"
  }

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
