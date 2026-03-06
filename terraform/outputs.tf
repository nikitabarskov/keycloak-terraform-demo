output "client_id" {
  value = keycloak_openid_client.main.client_id
}

output "client_secret" {
  value     = keycloak_openid_client.main.client_secret
  sensitive = true
}

output "token_endpoint" {
  value       = "http://localhost:7080/realms/${keycloak_realm.demo.realm}/protocol/openid-connect/token"
  description = "Use this endpoint to fetch an access token for the client credentials grant"
}

output "fetch_token_command" {
  value = "curl -s -X POST http://localhost:7080/realms/${keycloak_realm.demo.realm}/protocol/openid-connect/token -d grant_type=client_credentials -d client_id=$(terraform output -raw client_id) -d client_secret=$(terraform output -raw client_secret) | jq -r '.access_token' | cut -d. -f2 | base64 -d 2>/dev/null | jq ."
}

output "mock_idp_alias" {
  value       = keycloak_oidc_identity_provider.mock.alias
  description = "The alias of the mock OIDC Identity Provider configured in Keycloak"
}

output "mock_idp_login_url" {
  value       = "http://localhost:7080/realms/${keycloak_realm.demo.realm}/broker/${keycloak_oidc_identity_provider.mock.alias}/endpoint"
  description = "The broker endpoint for the mock IdP"
}

output "test_username" {
  value       = keycloak_user.test.username
  description = "Username for the test user with a linked external identity"
}

output "test_password" {
  value       = "testuser"
  description = "Password for the test user"
}
