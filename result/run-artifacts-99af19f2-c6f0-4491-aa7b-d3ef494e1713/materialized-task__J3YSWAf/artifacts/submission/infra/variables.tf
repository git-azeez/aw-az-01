variable "config_path" {
  description = "Path to the deployment inputs (resource_prefix, region, images, database credentials)."
  type        = string
  default     = "/workspace/config/config.json"
}

variable "s3control_endpoint" {
  description = <<-EOT
    Endpoint for the S3 Control API. The provider prepends the account id to this
    host name, so it must be a name whose wildcard sub-domains resolve; deploy.sh
    runs a loopback forwarder (scripts/tcp_forward.py) for it.
  EOT
  type        = string
  default     = "http://localhost:14566"
}
