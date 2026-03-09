"""
Backend API - SSO Demo

A minimal Backend-for-Frontend (BFF) that demonstrates:
  - Option A: Server-side token exchange (KC token -> external IdP token)
  - Option B: Frontend silent authentication against the external IdP

The SPA never sees Keycloak tokens. It only holds:
  - A session cookie (app_session) for Backend API calls
  - A short-lived external token obtained via Option A or B
"""

import hashlib
import os
import secrets
import uuid
from base64 import urlsafe_b64encode
from urllib.parse import urlencode

import httpx
from authlib.jose import jwt
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import URLSafeSerializer

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://localhost:7080")
KEYCLOAK_EXTERNAL_URL = os.environ.get("KEYCLOAK_EXTERNAL_URL", "http://localhost:7080")
REALM = os.environ.get("REALM", "demo")
CLIENT_ID = os.environ.get("CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
IDP_ALIAS = os.environ.get("IDP_ALIAS", "mock-oauth2-server")
SESSION_SECRET = os.environ.get("SESSION_SECRET", secrets.token_hex(32))
MOCK_IDP_URL = os.environ.get("MOCK_IDP_URL", "http://host.docker.internal:8090")

OIDC_BASE = f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect"
OIDC_BASE_EXTERNAL = f"{KEYCLOAK_EXTERNAL_URL}/realms/{REALM}/protocol/openid-connect"

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

app = FastAPI(title="Backend API - SSO Demo")
templates = Jinja2Templates(directory="templates")
signer = URLSafeSerializer(SESSION_SECRET)

# In-memory session store: session_id -> session data
sessions: dict[str, dict] = {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def generate_pkce() -> tuple[str, str]:
    """Generate PKCE code_verifier and code_challenge (S256)."""
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def create_session(data: dict) -> str:
    """Create a new session and return the signed session ID."""
    session_id = str(uuid.uuid4())
    sessions[session_id] = data
    return signer.dumps(session_id)


def get_session(request: Request) -> dict | None:
    """Resolve session from the app_session cookie."""
    cookie = request.cookies.get("app_session")
    if not cookie:
        return None
    try:
        session_id = signer.loads(cookie)
    except Exception:
        return None
    return sessions.get(session_id)


def get_session_id(request: Request) -> str | None:
    """Return the raw session ID (for updating session data in-place)."""
    cookie = request.cookies.get("app_session")
    if not cookie:
        return None
    try:
        return signer.loads(cookie)
    except Exception:
        return None


def delete_session(request: Request) -> str | None:
    """Delete session and return the id_token for logout."""
    cookie = request.cookies.get("app_session")
    if not cookie:
        return None
    try:
        session_id = signer.loads(cookie)
    except Exception:
        return None
    session = sessions.pop(session_id, None)
    if session:
        return session.get("id_token")
    return None


def decode_jwt_unverified(token: str) -> dict:
    """Decode a JWT payload without verification (for display only)."""
    try:
        claims = jwt.decode(token, {"keys": []})
        return dict(claims)
    except Exception:
        import base64
        import json

        parts = token.split(".")
        if len(parts) >= 2:
            payload = parts[1]
            padding = 4 - len(payload) % 4
            if padding != 4:
                payload += "=" * padding
            return json.loads(base64.urlsafe_b64decode(payload))
        return {"error": "could not decode token"}


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Serve the SPA."""
    session = get_session(request)
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "logged_in": session is not None,
            "user": session.get("user") if session else None,
            "mock_oauth2_url": MOCK_IDP_URL,
        },
    )


@app.get("/oauth/login")
async def oauth_login():
    """Start the OIDC authorization code flow with PKCE."""
    verifier, challenge = generate_pkce()
    state = secrets.token_urlsafe(32)

    # Store PKCE verifier in a temporary pre-auth session
    signed_state = signer.dumps({"state": state, "verifier": verifier})

    params = urlencode(
        {
            "response_type": "code",
            "client_id": CLIENT_ID,
            "redirect_uri": "http://localhost:8000/oauth/callback",
            "scope": "openid profile email",
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "kc_idp_hint": IDP_ALIAS,
        }
    )

    response = RedirectResponse(url=f"{OIDC_BASE_EXTERNAL}/auth?{params}")
    response.set_cookie(
        key="oauth_state",
        value=signed_state,
        httponly=True,
        samesite="lax",
        max_age=600,
    )
    return response


@app.get("/oauth/callback")
async def oauth_callback(request: Request, code: str = "", state: str = ""):
    """Handle the OIDC callback: exchange code for tokens, create session."""
    # Recover PKCE verifier from the oauth_state cookie
    state_cookie = request.cookies.get("oauth_state")
    if not state_cookie:
        return JSONResponse({"error": "missing oauth_state cookie"}, status_code=400)

    try:
        state_data = signer.loads(state_cookie)
    except Exception:
        return JSONResponse({"error": "invalid oauth_state cookie"}, status_code=400)

    if state_data.get("state") != state:
        return JSONResponse({"error": "state mismatch"}, status_code=400)

    verifier = state_data["verifier"]

    # Exchange authorization code for tokens (backend-to-backend)
    async with httpx.AsyncClient() as client:
        token_response = await client.post(
            f"{OIDC_BASE}/token",
            data={
                "grant_type": "authorization_code",
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "code": code,
                "redirect_uri": "http://localhost:8000/oauth/callback",
                "code_verifier": verifier,
            },
        )

    if token_response.status_code != 200:
        return JSONResponse(
            {
                "error": "token exchange failed",
                "details": token_response.json(),
            },
            status_code=502,
        )

    tokens = token_response.json()
    access_token = tokens["access_token"]
    id_token = tokens.get("id_token", "")
    refresh_token = tokens.get("refresh_token", "")

    # Extract user info from the ID token
    user_info = decode_jwt_unverified(id_token) if id_token else {}

    # Create server-side session (tokens never leave the backend)
    signed_session_id = create_session(
        {
            "access_token": access_token,
            "id_token": id_token,
            "refresh_token": refresh_token,
            "user": {
                "sub": user_info.get("sub", ""),
                "name": user_info.get("name", ""),
                "preferred_username": user_info.get("preferred_username", ""),
                "email": user_info.get("email", ""),
            },
        }
    )

    response = RedirectResponse(url="/", status_code=302)
    response.set_cookie(
        key="app_session",
        value=signed_session_id,
        httponly=True,
        samesite="lax",
        max_age=86400,
    )
    # Clear the temporary oauth_state cookie
    response.delete_cookie("oauth_state")
    return response


@app.get("/oauth/logout")
async def oauth_logout(request: Request):
    """Destroy session and redirect to Keycloak logout."""
    id_token = delete_session(request)

    params = urlencode(
        {
            "id_token_hint": id_token or "",
            "post_logout_redirect_uri": "http://localhost:8000",
        }
    )

    response = RedirectResponse(url=f"{OIDC_BASE_EXTERNAL}/logout?{params}")
    response.delete_cookie("app_session")
    return response


@app.get("/whoami")
async def whoami(request: Request):
    """Return user info from session. No tokens are exposed."""
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "not authenticated"}, status_code=401)

    return JSONResponse({"user": session["user"]})


async def refresh_access_token(session_id: str) -> str | None:
    """
    Use the stored refresh token to obtain a fresh access token.
    Updates the session in-place and returns the new access token,
    or None if the refresh fails.
    """
    session = sessions.get(session_id)
    if not session or not session.get("refresh_token"):
        return None

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{OIDC_BASE}/token",
            data={
                "grant_type": "refresh_token",
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "refresh_token": session["refresh_token"],
            },
        )

    if resp.status_code != 200:
        return None

    tokens = resp.json()
    session["access_token"] = tokens["access_token"]
    if tokens.get("refresh_token"):
        session["refresh_token"] = tokens["refresh_token"]
    if tokens.get("id_token"):
        session["id_token"] = tokens["id_token"]
    return tokens["access_token"]


@app.get("/external/token")
async def external_token(request: Request):
    """
    Option A: Backend token exchange.

    Exchanges the Keycloak access token (from server-side session) for an
    external IdP token using requested_issuer. The external token is returned
    to the SPA for direct API calls.

    If the stored access token has expired, it is refreshed automatically
    using the refresh token before performing the exchange.
    """
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "not authenticated"}, status_code=401)

    kc_access_token = session["access_token"]

    # Perform internal-to-external token exchange (Keycloak V1)
    async with httpx.AsyncClient() as client:
        exchange_response = await client.post(
            f"{OIDC_BASE}/token",
            data={
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": kc_access_token,
                "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "requested_issuer": IDP_ALIAS,
            },
        )

    # If the token was rejected (likely expired), try refreshing and retrying
    if exchange_response.status_code != 200:
        error_body = exchange_response.json()
        error_desc = error_body.get("error_description", "")

        if "Invalid token" in error_desc or "expired" in error_desc.lower():
            session_id = get_session_id(request)
            if session_id:
                refreshed_token = await refresh_access_token(session_id)
                if refreshed_token:
                    # Retry the exchange with the fresh token
                    async with httpx.AsyncClient() as client:
                        exchange_response = await client.post(
                            f"{OIDC_BASE}/token",
                            data={
                                "client_id": CLIENT_ID,
                                "client_secret": CLIENT_SECRET,
                                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                                "subject_token": refreshed_token,
                                "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                                "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
                                "requested_issuer": IDP_ALIAS,
                            },
                        )

    if exchange_response.status_code != 200:
        error_body = exchange_response.json()
        return JSONResponse(
            {
                "error": "token exchange failed",
                "details": error_body,
            },
            status_code=502,
        )

    result = exchange_response.json()
    external_token = result.get("access_token", "")

    return JSONResponse(
        {
            "access_token": external_token,
            "expires_in": result.get("expires_in"),
            "token_payload": decode_jwt_unverified(external_token),
        }
    )


# ---------------------------------------------------------------------------
# Static files (must be mounted after routes to avoid shadowing them)
# ---------------------------------------------------------------------------

app.mount("/", StaticFiles(directory="static"), name="static")