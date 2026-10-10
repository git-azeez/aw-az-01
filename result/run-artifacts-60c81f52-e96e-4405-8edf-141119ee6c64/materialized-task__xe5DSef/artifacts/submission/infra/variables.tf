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

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

locals {
  p       = var.resource_prefix
  azs     = ["${var.region}a", "${var.region}b"]
  account = data.aws_caller_identity.current.account_id
  tags    = { ClearLedgerDeployment = var.resource_prefix }

  # Host of the AWS control plane; the emulator publishes ALB listeners on it.
  endpoint_host = regex("^[a-zA-Z]+://([^:/]+)", var.aws_endpoint_url)[0]

  # Endpoint reachable from inside the workload containers.
  container_aws_endpoint = var.aws_endpoint_url
}

data "aws_caller_identity" "current" {}
