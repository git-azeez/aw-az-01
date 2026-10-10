resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"

  tags = local.tags
}

resource "aws_cognito_resource_server" "main" {
  identifier   = "clearledger"
  name         = "${local.prefix}-clearledger"
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
    scope_description = "Administrative projection rebuilds"
  }
}

resource "aws_cognito_user_pool_client" "read" {
  name         = "${local.prefix}-read"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/read"]

  depends_on = [aws_cognito_resource_server.main]
}

resource "aws_cognito_user_pool_client" "write" {
  name         = "${local.prefix}-write"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/write"]

  depends_on = [aws_cognito_resource_server.main]
}

resource "aws_cognito_user_pool_client" "admin" {
  name         = "${local.prefix}-admin"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/admin"]

  depends_on = [aws_cognito_resource_server.main]
}
