"""Verify the Google-signed identity token on every request.

Cloud Run already rejects callers without roles/run.invoker before the request reaches us; we
verify again anyway (signature, expiry, issuer, AUDIENCE, verified email) so that a mistaken
`allUsers` binding or a request that bypasses the front end still cannot impersonate a caller."""

from __future__ import annotations

from collections.abc import Callable, Sequence

from google.auth.transport import requests as ga_requests
from google.oauth2 import id_token


class AuthError(Exception):
    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status, self.reason = status, reason


def _default_verifier(token: str, audiences: Sequence[str]) -> dict:
    return id_token.verify_oauth2_token(
        token, ga_requests.Request(), audience=list(audiences)
    )


def caller_email(
    authorization: str | None,
    audiences: Sequence[str],
    verifier: Callable[[str, Sequence[str]], dict] = _default_verifier,
) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise AuthError(401, "missing_bearer_token")
    token = authorization[7:].strip()
    try:
        claims = verifier(token, audiences)
    except (
        Exception
    ) as exc:  # google-auth raises ValueError / GoogleAuthError subclasses
        raise AuthError(401, f"invalid_token:{type(exc).__name__}") from exc
    email = claims.get("email")
    if not email or claims.get("email_verified") is not True:
        raise AuthError(401, "token_has_no_verified_email")
    return str(email).lower()
