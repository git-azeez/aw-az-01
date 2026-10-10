variable "config_path" {
  description = "Path to the deployment inputs (resource_prefix, region, db credentials, images)."
  type        = string
  default     = "/workspace/config/config.json"
}
