#!/usr/bin/env bash
# token-exchange-demo.sh
#
# Demonstrates the internal-to-external token exchange flow:
#   1. Obtain a token from the external IdP (mock-oauth2-server)
#   2. Exchange it for a Keycloak token (external-to-internal)
#   3. Exchange the Keycloak token back for an external IdP token (internal-to-external)
#
# Prerequisites:
#   - docker compose up -d
#   - cd terraform && terraform apply
#   - jq installed
#
# Usage:
#   ./scripts/token-exchange-demo.sh

set -euo pipefail

# -- Configuration -----------------------------------------------------------
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:7080}"
EXTERNAL_IDP_URL="${EXTERNAL_IDP_URL:-http://host.docker.internal:8090}"
REALM="${REALM:-demo}"
IDP_ALIAS="${IDP_ALIAS:-mock-oauth2-server}"
EXTERNAL_IDP_ISSUER_ID="${EXTERNAL_IDP_ISSUER_ID:-default}"

# Read client credentials from Terraform outputs
TERRAFORM_DIR="${TERRAFORM_DIR:-$(dirname "$0")/../terraform}"
CLIENT_ID="$(terraform -chdir="$TERRAFORM_DIR" output -raw client_id)"
CLIENT_SECRET="$(terraform -chdir="$TERRAFORM_DIR" output -raw client_secret)"

TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token"

# -- Helpers ------------------------------------------------------------------
header() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
info()   { printf '    %s\n' "$1"; }
error()  {
    printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2
    exit 1
}

decode_jwt_payload() {
    local payload
    payload="$(echo "$1" | cut -d. -f2)"
    local pad=$((4 - ${#payload} % 4))
    [ "$pad" -ne 4 ] && payload="${payload}$(printf '%0.s=' $(seq 1 "$pad"))"
    echo "$payload" | base64 -d 2>/dev/null | jq .
}

# -- Step 1: Get a token from the external IdP --------------------------------
header "Step 1: Obtain a token from the external IdP (mock-oauth2-server)"

EXTERNAL_TOKEN_RESPONSE=$(curl -s -X POST \
    "${EXTERNAL_IDP_URL}/${EXTERNAL_IDP_ISSUER_ID}/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=mock-client" \
    -d "client_secret=mock-secret" \
    -d "scope=openid profile email")

EXTERNAL_TOKEN=$(echo "$EXTERNAL_TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$EXTERNAL_TOKEN" ]; then
    info "Response: $(echo "$EXTERNAL_TOKEN_RESPONSE" | jq .)"
    error "Failed to obtain token from external IdP. Is it running on ${EXTERNAL_IDP_URL}?"
fi

info "External IdP token obtained successfully."
info "External token payload:"
decode_jwt_payload "$EXTERNAL_TOKEN"

# -- Step 2: Exchange external token for a Keycloak token ---------------------
header "Step 2: Exchange external IdP token for a Keycloak token (external-to-internal)"
info "Using subject_issuer=${IDP_ALIAS}"

KC_TOKEN_RESPONSE=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "subject_token=${EXTERNAL_TOKEN}" \
    -d "subject_issuer=${IDP_ALIAS}" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token")

KC_ACCESS_TOKEN=$(echo "$KC_TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$KC_ACCESS_TOKEN" ]; then
    info "Response:"
    echo "$KC_TOKEN_RESPONSE" | jq .
    error "Failed to exchange external token for Keycloak token. See error above."
fi

info "Keycloak token obtained successfully."
info "Keycloak token payload:"
decode_jwt_payload "$KC_ACCESS_TOKEN"

# -- Step 3: Exchange Keycloak token for external IdP token -------------------
header "Step 3: Exchange Keycloak token for external IdP token (internal-to-external)"
info "Using requested_issuer=${IDP_ALIAS}"

EXCHANGE_RESPONSE=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "subject_token=${KC_ACCESS_TOKEN}" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "requested_issuer=${IDP_ALIAS}")

EXCHANGED_TOKEN=$(echo "$EXCHANGE_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$EXCHANGED_TOKEN" ]; then
    info "Response:"
    echo "$EXCHANGE_RESPONSE" | jq .
    error "Failed to exchange Keycloak token for external IdP token. See error above."
fi

info "External IdP token retrieved via token exchange!"
info "Exchanged token payload:"
decode_jwt_payload "$EXCHANGED_TOKEN"

# -- Summary ------------------------------------------------------------------
header "Token Exchange Complete"
info "1. External IdP token was exchanged for a Keycloak token (external-to-internal)"
info "2. The Keycloak token was then exchanged back for an external IdP token"
info "   using requested_issuer=${IDP_ALIAS}"