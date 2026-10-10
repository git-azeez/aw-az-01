terraform {
  required_version = ">= 1.6.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}

variable "resource_prefix" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_endpoint_url" {
  type    = string
  default = "http://aws:4566"
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type = string
}

variable "api_image" {
  type = string
}

variable "projector_image" {
  type = string
}

variable "relay_image" {
  type = string
}

variable "archiver_image" {
  type = string
}

variable "api_image_id" {
  type    = string
  default = ""
}

variable "projector_image_id" {
  type    = string
  default = ""
}

variable "relay_image_id" {
  type    = string
  default = ""
}

variable "archiver_image_id" {
  type    = string
  default = ""
}

provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    acm                      = var.aws_endpoint_url
    cloudwatch               = var.aws_endpoint_url
    cloudwatchlogs           = var.aws_endpoint_url
    cognitoidp               = var.aws_endpoint_url
    dynamodb                 = var.aws_endpoint_url
    ec2                      = var.aws_endpoint_url
    ecs                      = var.aws_endpoint_url
    elasticache              = var.aws_endpoint_url
    elbv2                    = var.aws_endpoint_url
    events                   = var.aws_endpoint_url
    iam                      = var.aws_endpoint_url
    kms                      = var.aws_endpoint_url
    lambda                   = var.aws_endpoint_url
    rds                      = var.aws_endpoint_url
    s3                       = var.aws_endpoint_url
    scheduler                = var.aws_endpoint_url
    secretsmanager           = var.aws_endpoint_url
    sns                      = var.aws_endpoint_url
    sqs                      = var.aws_endpoint_url
    ssm                      = var.aws_endpoint_url
    sts                      = var.aws_endpoint_url
    resourcegroupstaggingapi = var.aws_endpoint_url
  }

}

data "aws_caller_identity" "current" {}

locals {
  p          = var.resource_prefix
  account_id = data.aws_caller_identity.current.account_id
  azs        = ["${var.region}a", "${var.region}b"]
  tags       = { ClearLedgerDeployment = var.resource_prefix }

  # Endpoint reachable from inside containers (ECS tasks and Lambda functions).
  container_aws_endpoint = var.aws_endpoint_url

  log_group_names = {
    api       = "/clearledger/${var.resource_prefix}/api"
    projector = "/clearledger/${var.resource_prefix}/projector"
    relay     = "/clearledger/${var.resource_prefix}/outbox-relay"
    archiver  = "/clearledger/${var.resource_prefix}/audit-archiver"
  }

  database_url = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.cache.primary_endpoint_address, aws_elasticache_replication_group.cache.configuration_endpoint_address, "aws")
  valkey_port  = aws_elasticache_replication_group.cache.port
  valkey_url   = "redis://${local.valkey_host}:${local.valkey_port}"

  issuer_url     = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}"
  jwks_url       = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  token_endpoint = "${var.aws_endpoint_url}/cognito-idp/oauth2/token"

  # The emulated ALB listener is published on the control-plane host.
  endpoint_host = regex("^[a-zA-Z]+://([^:/]+)", var.aws_endpoint_url)[0]
  service_url   = "http://${local.endpoint_host}:${aws_lb_listener.http.port}"
}
