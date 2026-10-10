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

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "cache_ttl_seconds" {
  type    = string
  default = "90"
}

variable "outbox_batch_size" {
  type    = string
  default = "50"
}

variable "audit_prefix" {
  type    = string
  default = "ledger-audit/"
}

locals {
  p          = var.resource_prefix
  account_id = data.aws_caller_identity.current.account_id
  azs        = ["${var.region}a", "${var.region}b"]

  # Host that fronts the emulated control plane (ALB listener sockets bind there).
  endpoint_host = regex("^[a-z]+://([^:/]+)", var.aws_endpoint_url)[0]

  # Deterministic queue identifiers: keep dependants (task definition, Lambda
  # environment, IAM policies, event source mapping) stable even when a queue
  # has to be recreated after an out-of-band deletion.
  queue_name    = "${local.p}-events"
  dlq_name      = "${local.p}-events-dlq"
  queue_url_det = "${var.aws_endpoint_url}/${local.account_id}/${local.queue_name}"
  queue_arn_det = "arn:aws:sqs:${var.region}:${local.account_id}:${local.queue_name}"
  dlq_arn_det   = "arn:aws:sqs:${var.region}:${local.account_id}:${local.dlq_name}"

  log_groups = {
    api       = "/clearledger/${local.p}/api"
    projector = "/clearledger/${local.p}/projector"
    relay     = "/clearledger/${local.p}/outbox-relay"
    archiver  = "/clearledger/${local.p}/audit-archiver"
  }

  common_lambda_env = {
    AWS_REGION            = var.region
    AWS_DEFAULT_REGION    = var.region
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
    AWS_ENDPOINT_URL      = var.aws_endpoint_url
  }

  valkey_host  = coalesce(aws_elasticache_replication_group.cache.primary_endpoint_address, aws_elasticache_replication_group.cache.configuration_endpoint_address)
  database_url = "postgres://${urlencode(var.db_username)}:${urlencode(var.db_password)}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_url   = "redis://${local.valkey_host}:${aws_elasticache_replication_group.cache.port}"
}

data "aws_caller_identity" "current" {}
