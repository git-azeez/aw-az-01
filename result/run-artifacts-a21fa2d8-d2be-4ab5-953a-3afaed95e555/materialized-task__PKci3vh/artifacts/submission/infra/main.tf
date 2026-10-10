terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.51.0" }
  }
  backend "local" { path = "terraform.tfstate" }
}
locals {
  config   = jsondecode(file("${path.module}/../../config/config.json"))
  prefix   = local.config.resource_prefix
  region   = local.config.region
  endpoint = local.config.aws_endpoint_url
  tags     = { ClearLedgerDeployment = local.prefix }
}
provider "aws" {
  region                      = local.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  default_tags { tags = local.tags }
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
resource "aws_kms_key" "key" {
  for_each                = toset(["database", "messaging", "projection", "audit"])
  description             = "${local.prefix}-${each.key}"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  is_enabled              = true
  tags                    = { Name = "${local.prefix}-${each.key}", ClearLedgerKeyUsage = each.key }
}
resource "aws_kms_alias" "key" {
  for_each      = aws_kms_key.key
  name          = "alias/${local.prefix}-${each.key}"
  target_key_id = each.value.key_id
}
resource "aws_cloudwatch_log_group" "log" {
  for_each          = { api = "api", projector = "projector", relay = "outbox-relay", archiver = "audit-archiver" }
  name              = "/clearledger/${local.prefix}/${each.value}"
  retention_in_days = 14
}
