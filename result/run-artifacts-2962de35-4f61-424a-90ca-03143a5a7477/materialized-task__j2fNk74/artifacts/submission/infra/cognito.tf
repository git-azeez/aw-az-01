resource "aws_cognito_user_pool" "main" {
  name = "${local.p}-users"
  tags = { Name = "${local.p}-users" }
}

resource "aws_cognito_resource_server" "clearledger" {
  user_pool_id = aws_cognito_user_pool.main.id
  identifier   = "clearledger"
  name         = "${local.p}-clearledger"

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
  cognito_clients = {
    read  = "clearledger/read"
    write = "clearledger/write"
    admin = "clearledger/admin"
  }
}

resource "aws_cognito_user_pool_client" "read" {
  name                                 = "${local.p}-read"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/read"]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  depends_on                           = [aws_cognito_resource_server.clearledger]
}

resource "aws_cognito_user_pool_client" "write" {
  name                                 = "${local.p}-write"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/write"]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  depends_on                           = [aws_cognito_resource_server.clearledger]
}

resource "aws_cognito_user_pool_client" "admin" {
  name                                 = "${local.p}-admin"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/admin"]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  depends_on                           = [aws_cognito_resource_server.clearledger]
}
