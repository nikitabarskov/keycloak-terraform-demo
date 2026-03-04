variable "keycloak_url" {
  description = "The URL of the Keycloak instance."
  type        = string
  default     = "http://localhost:7080"
}

variable "keycloak_client_id" {
  description = "The client ID used by Terraform to authenticate against Keycloak."
  type        = string
  default     = "terraform"
}

variable "keycloak_client_secret" {
  description = "The client secret used by Terraform to authenticate against Keycloak."
  type        = string
  sensitive   = true
  default     = "terraform-client-secret"
}
