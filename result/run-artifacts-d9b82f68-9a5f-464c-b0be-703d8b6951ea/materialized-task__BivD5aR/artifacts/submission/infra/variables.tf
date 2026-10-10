variable "config_file" {
  description = "Path to the deployment inputs (resource_prefix, region, images, DB credentials ...)."
  type        = string
  default     = "/workspace/config/config.json"
}

variable "aws_proxy" {
  description = "Optional local relay (scripts/aws_proxy.py) that serves the S3 Control virtual host, which does not resolve in this environment."
  type        = string
  default     = ""
}
