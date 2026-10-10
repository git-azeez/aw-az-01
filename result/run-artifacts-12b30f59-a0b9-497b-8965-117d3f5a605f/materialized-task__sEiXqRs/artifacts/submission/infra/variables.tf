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

locals {
  prefix = var.resource_prefix

  common_tags = {
    ClearLedgerDeployment = var.resource_prefix
  }

  azs = ["${var.region}a", "${var.region}b"]

  account_id = data.aws_caller_identity.current.account_id

  log_group_names = {
    api       = "/clearledger/${var.resource_prefix}/api"
    projector = "/clearledger/${var.resource_prefix}/projector"
    relay     = "/clearledger/${var.resource_prefix}/outbox-relay"
    archiver  = "/clearledger/${var.resource_prefix}/audit-archiver"
  }
}

data "aws_caller_identity" "current" {}
