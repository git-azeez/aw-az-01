resource "aws_cognito_user_pool" "main" {
  name = "${local.p}-users"
  tags = merge(local.tags, { Name = "${local.p}-users" })
}

resource "aws_cognito_resource_server" "clearledger" {
  user_pool_id = aws_cognito_user_pool.main.id
  identifier   = "clearledger"
  name         = "${local.p}-clearledger-api"

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
    scope_description = "Administrative projection rebuilds"
  }
}

locals {
  client_scopes = {
    read  = "clearledger/read"
    write = "clearledger/write"
    admin = "clearledger/admin"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  for_each                             = local.client_scopes
  name                                 = "${local.p}-${each.key}-client"
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
  auth_issuer    = "${var.aws_endpoint_url}/${aws_cognito_user_pool.main.id}"
  auth_jwks      = "${local.auth_issuer}/.well-known/jwks.json"
  auth_token     = "${var.aws_endpoint_url}/cognito-idp/oauth2/token"
  auth_audiences = join(",", [for k in ["read", "write", "admin"] : aws_cognito_user_pool_client.this[k].id])
}
