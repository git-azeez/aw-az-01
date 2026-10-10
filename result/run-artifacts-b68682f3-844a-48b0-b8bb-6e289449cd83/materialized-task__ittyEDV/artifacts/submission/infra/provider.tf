locals {
  cfg      = jsondecode(file(var.config_path))
  prefix   = local.cfg.resource_prefix
  region   = local.cfg.region
  endpoint = local.cfg.aws_endpoint_url

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
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  dynamic "endpoints" {
    for_each = [local.endpoint]
    content {
      ec2            = endpoints.value
      elbv2          = endpoints.value
      ecs            = endpoints.value
      rds            = endpoints.value
      dynamodb       = endpoints.value
      elasticache    = endpoints.value
      s3             = endpoints.value
      sqs            = endpoints.value
      lambda         = endpoints.value
      scheduler      = endpoints.value
      cognitoidp     = endpoints.value
      iam            = endpoints.value
      kms            = endpoints.value
      cloudwatchlogs = endpoints.value
      sts            = endpoints.value
    }
  }

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}
