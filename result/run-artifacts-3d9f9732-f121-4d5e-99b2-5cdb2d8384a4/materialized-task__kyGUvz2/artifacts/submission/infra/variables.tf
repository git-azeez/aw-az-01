# All values come from /workspace/config/config.json (passed with -var-file by deploy.sh/destroy.sh).

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

# Digests are accepted for traceability (declared so the shared var-file is consumed without warnings).
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

locals {
  prefix = var.resource_prefix
  azs    = ["${var.region}a", "${var.region}b"]

  tags = {
    ClearLedgerDeployment = var.resource_prefix
  }

  vpc_cidr      = "10.42.0.0/16"
  public_cidrs  = ["10.42.0.0/24", "10.42.1.0/24"]
  private_cidrs = ["10.42.10.0/24", "10.42.11.0/24"]

  # Runtime wiring shared by the workloads.
  database_url = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  valkey_host  = coalesce(aws_elasticache_replication_group.main.primary_endpoint_address, aws_elasticache_replication_group.main.configuration_endpoint_address, aws_elasticache_replication_group.main.reader_endpoint_address)
  valkey_url   = "redis://${local.valkey_host}:6379"
  audit_prefix = "ledger-audit/"
}
