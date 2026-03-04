terraform {
  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = ">=5,<6"
    }
    random = {
      source  = "hashicorp/random"
      version = ">=3,<4"
    }
  }
  required_version = ">=1.13,<2"
}
