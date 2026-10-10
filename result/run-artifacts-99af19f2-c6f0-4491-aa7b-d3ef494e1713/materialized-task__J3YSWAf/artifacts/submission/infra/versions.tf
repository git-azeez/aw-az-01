terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region     = local.config.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = false
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    acm            = local.config.aws_endpoint_url
    apigateway     = local.config.aws_endpoint_url
    cloudwatch     = local.config.aws_endpoint_url
    cloudwatchlogs = local.config.aws_endpoint_url
    cognitoidp     = local.config.aws_endpoint_url
    dynamodb       = local.config.aws_endpoint_url
    ec2            = local.config.aws_endpoint_url
    ecs            = local.config.aws_endpoint_url
    elasticache    = local.config.aws_endpoint_url
    elbv2          = local.config.aws_endpoint_url
    events         = local.config.aws_endpoint_url
    iam            = local.config.aws_endpoint_url
    kms            = local.config.aws_endpoint_url
    lambda         = local.config.aws_endpoint_url
    rds            = local.config.aws_endpoint_url
    s3             = local.config.aws_endpoint_url
    s3control      = var.s3control_endpoint
    scheduler      = local.config.aws_endpoint_url
    sqs            = local.config.aws_endpoint_url
    sts            = local.config.aws_endpoint_url
  }
}
