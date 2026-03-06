# keycloak-terraform-demo

A browser-based SSO demo implementing the authentication flows described in RFC-001 for the Hero project. Demonstrates two approaches for obtaining external IdP (DIPS/DFS) tokens through Keycloak federation:

- **Option A** -- Backend token exchange: Hero API stores Keycloak tokens server-side and exchanges them for external IdP tokens using `requested_issuer` (Keycloak V1 legacy token exchange).
- **Option B** -- Frontend silent authentication: The SPA performs a `prompt=none` authorization request directly against the external IdP, leveraging the SSO cookie from the initial federated login.

## Architecture

```
Browser (SPA at localhost:8000)
  │ Option A: session cookie     │ Option B: direct to mock IdP
  ▼                               ▼
Hero API (FastAPI :8000)    mock-oauth2-server (:8090, "DFS")
  │                               ▲
  │ OIDC auth code + PKCE         │ broker federation
  │ + token exchange              │
  ▼                               │
Keycloak (:7080, demo realm) ─────┘
```

The SPA never sees Keycloak tokens. It only holds a session cookie (`hero_session`) for Hero API calls and short-lived DIPS tokens obtained via Option A or B.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.13
- `host.docker.internal` must resolve to `127.0.0.1`. The mock-oauth2-server derives its issuer from the request `Host` header, so both Keycloak (inside Docker) and the host must use the same hostname. Add the following to `/etc/hosts` if not already present:

  ```
  127.0.0.1 host.docker.internal
  ```

## Quick start

```shell
# 1. Start infrastructure
docker compose up -d postgresql keycloak mock-oauth2-server

# 2. Wait for Keycloak to be healthy (~60s on first boot)
docker compose logs -f keycloak  # wait for "Listening on: http://0.0.0.0:7080"

# 3. Provision Keycloak resources
cd terraform
terraform init
terraform apply

# 4. Export client credentials for Hero API
export CLIENT_ID=$(terraform output -raw client_id)
export CLIENT_SECRET=$(terraform output -raw client_secret)
cd ..

# 5. Start Hero API
docker compose up -d hero-api

# 6. Open the demo
open http://localhost:8000
```

## What happens in the browser

1. Click **Login with Keycloak** -- redirects to Keycloak, which federates to mock-oauth2-server (acting as DFS). After login, you are redirected back with a session cookie. Keycloak tokens are stored server-side only.

2. Click **Get DIPS Token (Option A)** -- Hero API resolves your session to the stored Keycloak access token, performs a V1 token exchange with `requested_issuer=mock-oauth2-server`, and returns the external IdP token. The decoded JWT payload is displayed.

3. Click **Get DIPS Token (Option B)** -- The SPA opens a popup directly to mock-oauth2-server with `prompt=none`, gets an authorization code, exchanges it for a token via PKCE (public client, no backend involvement), and displays the decoded JWT payload.

4. Click **Logout** -- Destroys the server-side session and redirects to Keycloak's logout endpoint.

## Hero API endpoints

| Endpoint | Description |
|---|---|
| `GET /` | Serves the HTML SPA |
| `GET /oauth/login` | Generates PKCE, redirects to Keycloak `/authorize` |
| `GET /oauth/callback` | Exchanges code for tokens, creates server-side session |
| `GET /oauth/logout` | Deletes session, redirects to Keycloak logout |
| `GET /whoami` | Returns user info from session (no tokens exposed) |
| `GET /dips/token` | Option A: KC access_token -> token exchange -> external IdP token |

## What Terraform provisions

| Resource | Description |
|---|---|
| `keycloak_realm` | `demo` realm with EdDSA token signing |
| `keycloak_openid_client` | Confidential client with service accounts, standard flow, PKCE |
| `keycloak_role` | Client roles: `read` and `write` |
| `keycloak_openid_client_service_account_role` | Assigns roles to the service account |
| `keycloak_openid_client_scope` | Custom scope `example-roles` |
| `keycloak_openid_user_client_role_protocol_mapper` | Maps client roles into `hero-roles` claim |
| `keycloak_oidc_identity_provider` | OIDC IdP pointing to mock-oauth2-server with `store_token = true` |
| `keycloak_identity_provider_token_exchange_scope_permission` | Grants token exchange permission with the mock IdP |
| `keycloak_user` | Test user (`testuser` / `password`) with federated identity link |

## Key design decisions

- **V1 token exchange** -- V2 does not support internal-to-external exchange (`requested_issuer`). Keycloak is started with `--features=token-exchange:v1,admin-fine-grained-authz:v1`.
- **`demo` realm** -- The `keycloak_identity_provider_token_exchange_scope_permission` resource hardcodes `realm-management` which does not exist in the `master` realm.
- **`host.docker.internal`** -- Used as the hostname for mock-oauth2-server everywhere so the issuer in tokens is consistent between Docker containers and the host.
- **Option B is simulated** -- mock-oauth2-server auto-approves all requests, so the `prompt=none` silent auth always succeeds regardless of SSO cookie state.

## CLI-based token exchange demo

The original curl-based demo script is still available:

```shell
./scripts/token-exchange-demo.sh
```

See the script for manual step-by-step instructions.
