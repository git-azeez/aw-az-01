data "aws_caller_identity" "current" {}

locals {
  config = jsondecode(file(var.config_path))

  prefix     = local.config.resource_prefix
  region     = local.config.region
  endpoint   = local.config.aws_endpoint_url
  account_id = data.aws_caller_identity.current.account_id

  tags = {
    ClearLedgerDeployment = local.prefix
  }

  azs = ["us-east-1a", "us-east-1b"]

  vpc_cidr             = "10.42.0.0/16"
  public_subnet_cidrs  = ["10.42.0.0/24", "10.42.1.0/24"]
  private_subnet_cidrs = ["10.42.10.0/24", "10.42.11.0/24"]

  # Runtime constants from contracts/runtime.md
  cache_ttl_seconds = "90"
  outbox_batch_size = "50"
  audit_prefix      = "ledger-audit/"

  service_url = "http://${regex("^https?://([^:/]+)", local.endpoint)[0]}:80"

  database_url = sensitive("postgres://${local.config.db_username}:${local.config.db_password}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${local.config.db_name}")
  valkey_host  = coalesce(aws_elasticache_replication_group.valkey.primary_endpoint_address, aws_elasticache_replication_group.valkey.configuration_endpoint_address)
  valkey_url   = "redis://${local.valkey_host}:${aws_elasticache_replication_group.valkey.port}"

  issuer_url     = "${local.endpoint}/${aws_cognito_user_pool.main.id}"
  jwks_url       = "${local.endpoint}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  token_endpoint = "${local.endpoint}/cognito-idp/oauth2/token"
  auth_audiences = join(",", [
    aws_cognito_user_pool_client.read.id,
    aws_cognito_user_pool_client.write.id,
    aws_cognito_user_pool_client.admin.id,
  ])
}
