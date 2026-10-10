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
  type      = string
  sensitive = true
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

# S3 Control endpoint. The AWS provider prefixes the account id to the S3 Control
# host (e.g. 000000000000.<host>), so deploy.sh points this at a local forwarder
# reachable through a *.localhost name.
variable "s3control_endpoint_url" {
  type    = string
  default = ""
}

# Host used to reach the ALB listener from the operator workstation.
variable "service_host" {
  type    = string
  default = "aws"
}

# Endpoint as seen from inside workload containers (API / Lambda).
variable "container_aws_endpoint_url" {
  type    = string
  default = "http://aws:4566"
}

locals {
  p          = var.resource_prefix
  account_id = data.aws_caller_identity.current.account_id
  azs        = ["${var.region}a", "${var.region}b"]

  log_groups = {
    api       = "/clearledger/${local.p}/api"
    projector = "/clearledger/${local.p}/projector"
    relay     = "/clearledger/${local.p}/outbox-relay"
    archiver  = "/clearledger/${local.p}/audit-archiver"
  }

  database_url = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_host = coalesce(
    aws_elasticache_replication_group.valkey.primary_endpoint_address,
    aws_elasticache_replication_group.valkey.configuration_endpoint_address,
  )
  valkey_port = coalesce(aws_elasticache_replication_group.valkey.port, 6379)
  valkey_url  = "redis://${local.valkey_host}:${local.valkey_port}"

  issuer_url     = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}"
  jwks_url       = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  token_endpoint = "${var.aws_endpoint_url}/cognito-idp/oauth2/token"
}

data "aws_caller_identity" "current" {}
