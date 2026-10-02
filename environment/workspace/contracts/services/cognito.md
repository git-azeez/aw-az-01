# Cognito User Pool and OAuth2 Scopes (`services/cognito.md`)

- Provision a Cognito User Pool (`aws_cognito_user_pool`) and User Pool Domain (`aws_cognito_user_pool_domain`).
- Provision a Cognito Resource Server (`aws_cognito_resource_server`) with:
  - `identifier = "clearledger"` (`manifest.auth.resource_server_identifier = "clearledger"`)
  - Three scopes: `read`, `write`, and `admin` (yielding full scope strings `clearledger/read`, `clearledger/write`, and `clearledger/admin`).
- Provision three separate Cognito User Pool Clients (`aws_cognito_user_pool_client`), each configured with:
  - `generate_secret = true`
  - `allowed_oauth_flows_user_pool_client = true`
  - `allowed_oauth_flows = ["client_credentials"]`
  - Exact single scope per client:
    - `clients.read`: `allowed_oauth_scopes = ["clearledger/read"]`
    - `clients.write`: `allowed_oauth_scopes = ["clearledger/write"]`
    - `clients.admin`: `allowed_oauth_scopes = ["clearledger/admin"]`
- Export `issuer_url` (`http://aws:4566/<user_pool_id>`) and `token_endpoint` (`http://aws:4566/cognito-idp/oauth2/token` or `http://aws:4566/<domain>.auth.<region>.amazoncognito.com/oauth2/token`) in `manifest.json`.
