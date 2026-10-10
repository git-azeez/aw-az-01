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
    scope_description = "Read settlements and ledgers"
  }
  scope {
    scope_name        = "write"
    scope_description = "Initiate settlements and append entries"
  }
  scope {
    scope_name        = "admin"
    scope_description = "Administrative projection rebuilds"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  for_each = toset(["read", "write", "admin"])

  name                                 = "${local.prefix}-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["clearledger/${each.key}"]
  supported_identity_providers         = ["COGNITO"]

  depends_on = [aws_cognito_resource_server.main]
}
