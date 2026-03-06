resource "keycloak_realm" "demo" {
  realm                       = "demo"
  default_signature_algorithm = "EdDSA"
  display_name                = "Demo"
}

resource "random_uuid7" "main" {}

ephemeral "random_password" "main" {
  length = 32
}

resource "keycloak_openid_client" "main" {
  realm_id  = keycloak_realm.demo.id
  client_id = random_uuid7.main.result
  name      = "example"

  access_type                  = "CONFIDENTIAL"
  client_authenticator_type    = "client-secret"
  service_accounts_enabled     = true
  direct_access_grants_enabled = true
  standard_flow_enabled        = true
  valid_redirect_uris          = ["http://localhost:8000/oauth/callback"]
  web_origins                  = ["http://localhost:8000"]
}

resource "keycloak_role" "read" {
  realm_id    = keycloak_realm.demo.id
  client_id   = keycloak_openid_client.main.id
  name        = "read"
  description = "Read access"
}

resource "keycloak_role" "write" {
  realm_id    = keycloak_realm.demo.id
  client_id   = keycloak_openid_client.main.id
  name        = "write"
  description = "Write access"
}

resource "keycloak_openid_client_service_account_role" "read" {
  realm_id                = keycloak_realm.demo.id
  service_account_user_id = keycloak_openid_client.main.service_account_user_id
  client_id               = keycloak_openid_client.main.id
  role                    = keycloak_role.read.name
}

resource "keycloak_openid_client_service_account_role" "write" {
  realm_id                = keycloak_realm.demo.id
  service_account_user_id = keycloak_openid_client.main.service_account_user_id
  client_id               = keycloak_openid_client.main.id
  role                    = keycloak_role.write.name
}

resource "keycloak_openid_client_scope" "roles" {
  realm_id               = keycloak_realm.demo.id
  name                   = "example-roles"
  description            = "Exposes example client roles as a 'roles' claim in the access token"
  include_in_token_scope = true
}

# Protocol mapper: client roles → "roles" claim in the access token
resource "keycloak_openid_user_client_role_protocol_mapper" "roles" {
  realm_id        = keycloak_realm.demo.id
  client_scope_id = keycloak_openid_client_scope.roles.id
  name            = "example-client-roles"

  # Only include roles from this specific client (not every client in the realm)
  client_id_for_role_mappings = keycloak_openid_client.main.client_id

  claim_name          = "hero-roles"
  claim_value_type    = "String"
  multivalued         = true
  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_client_default_scopes" "main" {
  realm_id  = keycloak_realm.demo.id
  client_id = keycloak_openid_client.main.id

  default_scopes = [
    "profile",
    "email",
    "web-origins",
    keycloak_openid_client_scope.roles.name,
  ]
}

# ---------------------------------------------------------------------------
# External Identity Provider: mock-oauth2-server
# ---------------------------------------------------------------------------

resource "keycloak_oidc_identity_provider" "mock" {
  realm = keycloak_realm.demo.id
  alias = "mock-oauth2-server"

  # The mock-oauth2-server derives its issuer from the request Host header.
  # Using host.docker.internal ensures Keycloak (inside Docker) and the host
  # machine both see the same issuer, avoiding token validation failures.
  authorization_url = "http://host.docker.internal:8090/default/authorize"
  token_url         = "http://host.docker.internal:8090/default/token"
  user_info_url     = "http://host.docker.internal:8090/default/userinfo"
  jwks_url          = "http://host.docker.internal:8090/default/jwks"
  issuer            = "http://host.docker.internal:8090/default"

  client_id     = "keycloak"
  client_secret = "keycloak-secret"

  default_scopes     = "openid profile email"
  store_token        = true
  trust_email        = true
  sync_mode          = "FORCE"
  validate_signature = false

  extra_config = {
    "clientAuthMethod" = "client_secret_post"
  }
}

# ---------------------------------------------------------------------------
# Token exchange permission for the mock IdP
#
# Grants the "example" client permission to exchange tokens with the mock
# identity provider. This works cleanly in non-master realms where the
# "realm-management" client exists.
# ---------------------------------------------------------------------------

resource "keycloak_identity_provider_token_exchange_scope_permission" "mock" {
  realm_id       = keycloak_realm.demo.id
  provider_alias = keycloak_oidc_identity_provider.mock.alias
  policy_type    = "client"
  clients        = [keycloak_openid_client.main.id]
}

# ---------------------------------------------------------------------------
# Test user with a pre-linked external identity
#
# The federated_identity block creates the Keycloak ↔ external IdP link.
# To store a broker token (required for internal-to-external exchange),
# the user must complete the broker login flow at least once -- the demo
# script automates this via curl.
# ---------------------------------------------------------------------------

resource "keycloak_user" "test" {
  realm_id = keycloak_realm.demo.id
  username = "testuser"
  email    = "testuser@example.com"

  first_name     = "Test"
  last_name      = "User"
  email_verified = true
  enabled        = true

  initial_password {
    value     = "testuser"
    temporary = false
  }

  federated_identity {
    identity_provider = keycloak_oidc_identity_provider.mock.alias
    user_id           = "testuser"
    user_name         = "testuser"
  }
}
