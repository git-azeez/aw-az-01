terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.51.0"
    }
  }
}

provider "aws" {
  region     = var.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    cloudwatchlogs = var.aws_endpoint_url
    cognitoidp     = var.aws_endpoint_url
    dynamodb       = var.aws_endpoint_url
    ec2            = var.aws_endpoint_url
    ecs            = var.aws_endpoint_url
    elasticache    = var.aws_endpoint_url
    elbv2          = var.aws_endpoint_url
    iam            = var.aws_endpoint_url
    kms            = var.aws_endpoint_url
    lambda         = var.aws_endpoint_url
    rds            = var.aws_endpoint_url
    s3             = var.aws_endpoint_url
    scheduler      = var.aws_endpoint_url
    sqs            = var.aws_endpoint_url
    sts            = var.aws_endpoint_url
  }
}
