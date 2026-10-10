resource "aws_cognito_user_pool" "main" {
  name = "${local.p}-users"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = { Name = "${local.p}-users" }
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
    scope_description = "Rebuild settlement projections"
  }
}

locals {
  cognito_clients = ["read", "write", "admin"]
}

resource "aws_cognito_user_pool_client" "this" {
  for_each = toset(local.cognito_clients)

  name                                 = "${local.p}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/${each.key}"]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  depends_on = [aws_cognito_resource_server.clearledger]
}
