import {
  to = keycloak_realm.master
  id = "master"
}

resource "keycloak_realm" "master" {
  realm                       = "master"
  default_signature_algorithm = "EdDSA"
  display_name                = "Keycloak"
}

resource "random_uuid7" "main" {}

ephemeral "random_password" "main" {
  length = 32
}

resource "keycloak_openid_client" "main" {
  realm_id  = keycloak_realm.master.id
  client_id = random_uuid7.main.result
  name      = "example"

  access_type               = "CONFIDENTIAL"
  client_authenticator_type = "client-secret"
  service_accounts_enabled  = true
  # client_secret_wo         = ephemeral.random_password.main.result
  # client_secret_wo_version = 1
}

# ---------------------------------------------------------------------------
# Client roles
# ---------------------------------------------------------------------------

resource "keycloak_role" "read" {
  realm_id    = keycloak_realm.master.id
  client_id   = keycloak_openid_client.main.id
  name        = "read"
  description = "Read access"
}

resource "keycloak_role" "write" {
  realm_id    = keycloak_realm.master.id
  client_id   = keycloak_openid_client.main.id
  name        = "write"
  description = "Write access"
}

# ---------------------------------------------------------------------------
# Assign roles to the client's own service account
# (so they appear in tokens issued via client_credentials grant)
# ---------------------------------------------------------------------------

resource "keycloak_openid_client_service_account_role" "read" {
  realm_id                = keycloak_realm.master.id
  service_account_user_id = keycloak_openid_client.main.service_account_user_id
  client_id               = keycloak_openid_client.main.id
  role                    = keycloak_role.read.name
}

resource "keycloak_openid_client_service_account_role" "write" {
  realm_id                = keycloak_realm.master.id
  service_account_user_id = keycloak_openid_client.main.service_account_user_id
  client_id               = keycloak_openid_client.main.id
  role                    = keycloak_role.write.name
}

# ---------------------------------------------------------------------------
# Client scope that carries the roles claim
# ---------------------------------------------------------------------------

resource "keycloak_openid_client_scope" "roles" {
  realm_id               = keycloak_realm.master.id
  name                   = "example-roles"
  description            = "Exposes example client roles as a 'roles' claim in the access token"
  include_in_token_scope = true
}

# Protocol mapper: client roles → "roles" claim in the access token
resource "keycloak_openid_user_client_role_protocol_mapper" "roles" {
  realm_id        = keycloak_realm.master.id
  client_scope_id = keycloak_openid_client_scope.roles.id
  name            = "example-client-roles"

  # Only include roles from this specific client (not every client in the realm)
  client_id_for_role_mappings = keycloak_openid_client.main.client_id

  claim_name        = "hero-roles"
  claim_value_type  = "String"
  multivalued       = true
  add_to_id_token   = false
  add_to_access_token = true
  add_to_userinfo   = false
}

# ---------------------------------------------------------------------------
# Attach the scope to the client as a default scope
# Keycloak adds profile/email/roles/web-origins by default; keep those and
# append our custom scope so it is always included without the client having
# to request it explicitly.
# ---------------------------------------------------------------------------

resource "keycloak_openid_client_default_scopes" "main" {
  realm_id  = keycloak_realm.master.id
  client_id = keycloak_openid_client.main.id

  default_scopes = [
    "profile",
    "email",
    # "roles",
    "web-origins",
    keycloak_openid_client_scope.roles.name,
  ]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "client_id" {
  value = keycloak_openid_client.main.client_id
}

output "client_secret" {
  value     = keycloak_openid_client.main.client_secret
  sensitive = true
}

output "token_endpoint" {
  value       = "http://localhost:7080/realms/${keycloak_realm.master.realm}/protocol/openid-connect/token"
  description = "Use this endpoint to fetch an access token for the client credentials grant"
}

output "fetch_token_command" {
  value = "curl -s -X POST http://localhost:7080/realms/${keycloak_realm.master.realm}/protocol/openid-connect/token -d grant_type=client_credentials -d client_id=$(terraform output -raw client_id) -d client_secret=$(terraform output -raw client_secret) | jq -r '.access_token' | cut -d. -f2 | base64 -d 2>/dev/null | jq ."
}
