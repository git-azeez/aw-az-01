resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = { Name = "${local.prefix}-users" }
}

resource "aws_cognito_resource_server" "clearledger" {
  user_pool_id = aws_cognito_user_pool.main.id
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger-api"

  scope {
    scope_name        = "read"
    scope_description = "Read settlement projections and ledgers"
  }

  scope {
    scope_name        = "write"
    scope_description = "Initiate settlements and append ledger entries"
  }

  scope {
    scope_name        = "admin"
    scope_description = "Rebuild settlement projections"
  }
}

locals {
  oauth_clients = ["read", "write", "admin"]
}

resource "aws_cognito_user_pool_client" "this" {
  for_each = toset(local.oauth_clients)

  name         = "${local.prefix}-${each.key}"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.clearledger.identifier}/${each.key}"]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  access_token_validity = 60
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
  id_token_validity      = 60
  refresh_token_validity = 1
}

locals {
  issuer_url     = "${local.endpoint}/${aws_cognito_user_pool.main.id}"
  jwks_url       = "${local.endpoint}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  token_endpoint = "${local.endpoint}/cognito-idp/oauth2/token"
}
