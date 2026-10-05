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

locals {
  prefix            = var.resource_prefix
  aws_endpoint_host = split(":", replace(replace(var.aws_endpoint_url, "https://", ""), "http://", ""))[0]
  common_tags = {
    ClearLedgerDeployment = var.resource_prefix
    ManagedBy             = "terraform"
  }
}
