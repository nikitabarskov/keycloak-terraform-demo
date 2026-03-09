FROM docker.io/library/postgres:17-alpine@sha256:6f30057d31f5861b66f3545d4821f987aacf1dd920765f0acadea0c58ff975b1 AS postgres
FROM quay.io/keycloak/keycloak:26.5@sha256:ae8efb0d218d8921334b03a2dbee7069a0b868240691c50a3ffc9f42fabba8b4 AS keycloak
FROM ghcr.io/navikt/mock-oauth2-server:2.1.10 AS mock-oauth2-server
