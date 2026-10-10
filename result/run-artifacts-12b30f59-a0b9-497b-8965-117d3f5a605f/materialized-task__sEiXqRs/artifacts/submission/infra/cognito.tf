resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"

  tags = {
    Name = "${local.prefix}-users"
  }
}

resource "aws_cognito_resource_server" "clearledger" {
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger-api"
  user_pool_id = aws_cognito_user_pool.main.id

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
  cognito_clients = {
    read  = "clearledger/read"
    write = "clearledger/write"
    admin = "clearledger/admin"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  for_each = local.cognito_clients

  name                                 = "${local.prefix}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [each.value]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  depends_on = [aws_cognito_resource_server.clearledger]
}

locals {
  auth_issuer   = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}"
  auth_jwks_url = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  auth_audiences = join(",", [
    aws_cognito_user_pool_client.this["read"].id,
    aws_cognito_user_pool_client.this["write"].id,
    aws_cognito_user_pool_client.this["admin"].id,
  ])
  token_endpoint = "${var.aws_endpoint_url}/cognito-idp/oauth2/token"
}
