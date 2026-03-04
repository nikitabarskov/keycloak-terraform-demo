# keycloak-terraform-demo

A local Keycloak setup for testing the [keycloak/keycloak](https://registry.terraform.io/providers/keycloak/keycloak/latest) Terraform provider. Demonstrates provisioning a confidential client with client roles mapped to a custom scope, authenticated via the Client Credentials grant.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.13
- `jq` (`brew install jq`)

## Start Keycloak

```shell
docker compose up -d
```

Keycloak will be available at `http://localhost:7080` once healthy (allow ~60s on first boot).

## Apply Terraform

```shell
cd terraform
terraform init
terraform apply
```

The provider authenticates using the bootstrap admin credentials configured in `terraform.tfvars`.

## What is provisioned

| Resource | Description |
|---|---|
| `keycloak_realm` | Imports and configures the `master` realm with EdDSA token signing |
| `keycloak_openid_client` | Confidential client with a random UUID as `client_id` and service accounts enabled |
| `keycloak_role` | Client roles: `read` and `write` |
| `keycloak_openid_client_service_account_role` | Assigns `read` and `write` to the client's service account |
| `keycloak_openid_client_scope` | Custom scope `example-roles` |
| `keycloak_openid_user_client_role_protocol_mapper` | Maps client roles into a `hero-roles` claim in the access token |
| `keycloak_openid_client_default_scopes` | Attaches `example-roles` as a default scope on the client |

## Verify

Fetch and decode an access token:

```shell
eval "$(terraform output -raw fetch_token_command)"
```

The decoded token will contain:

```json
{
  "hero-roles": ["read", "write"],
  "scope": "profile example-roles email web-origins"
}
```

Call the userinfo endpoint:

```shell
eval "$(terraform output -raw fetch_userinfo_command)"
```
