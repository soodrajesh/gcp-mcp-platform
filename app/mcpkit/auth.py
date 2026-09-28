"""Verify the Google-signed identity token on every request.

Cloud Run already rejects callers without roles/run.invoker before the request reaches us; we
verify again anyway (signature, expiry, issuer, AUDIENCE, verified email) so that a mistaken
`allUsers` binding or a request that bypasses the front end still cannot impersonate a caller."""

from __future__ import annotations

from collections.abc import Callable, Sequence

from google.auth.transport import requests as ga_requests
from google.oauth2 import id_token

# `gcloud auth print-identity-token` for a USER account cannot set an audience: it always issues
# tokens for the gcloud CLI's own OAuth client (and so does `gcloud run services proxy`). Humans can
# therefore only be recognised by that audience; service accounts can and must target the service.
GCLOUD_CLIENT_ID = "32555940559.apps.googleusercontent.com"


class AuthError(Exception):
    def __init__(self, status: int, reason: str, detail: str = ""):
        super().__init__(reason)
        # `reason` goes to the client; `detail` only to our audit log (never echoed back).
        self.status, self.reason, self.detail = status, reason, detail


def _peek(token: str) -> str:
    """Unverified header/claim NAMES and non-secret claims, for the audit log only (diagnostics)."""
    import base64
    import json

    try:
        seg = lambda i: json.loads(base64.urlsafe_b64decode(token.split(".")[i] + "=" * (-len(token.split(".")[i]) % 4)))  # noqa: E731
        h, c = seg(0), seg(1)
        return f"alg={h.get('alg')} kid={str(h.get('kid'))[:8]} iss={c.get('iss')} aud={c.get('aud')} azp={c.get('azp')} claims={sorted(c)}"
    except Exception as e:  # noqa: BLE001
        return f"unparsable:{type(e).__name__}"


def _default_verifier(token: str, audiences: Sequence[str]) -> dict:
    # A fresh Request() (and so a fresh connection to fetch Google's certs) is used on retry: a stale
    # pooled connection returning a truncated/cached cert response was observed in production to fail
    # signature verification consistently until a new connection was made, while the same token verified
    # fine locally. One retry makes that class of transient failure self-heal without hiding a genuinely
    # bad token, which still fails identically on both attempts.
    try:
        return id_token.verify_oauth2_token(token, ga_requests.Request(), audience=list(audiences))
    except ValueError:
        return id_token.verify_oauth2_token(token, ga_requests.Request(), audience=list(audiences))


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
    except Exception as exc:  # google-auth raises ValueError / GoogleAuthError subclasses
        raise AuthError(
            401,
            f"invalid_token:{type(exc).__name__}",
            f"{exc!r}; segments={token.count('.') + 1} length={len(token)} {_peek(token)}"[:400],
        ) from exc
    email = claims.get("email")
    if not email or claims.get("email_verified") is not True:
        raise AuthError(401, "token_has_no_verified_email")
    email = str(email).lower()
    if claims.get("aud") == GCLOUD_CLIENT_ID and email.endswith(".gserviceaccount.com"):
        # A machine identity can mint a token for the exact service; accepting the shared CLI audience
        # from one would make its token replayable against anything that accepts CLI tokens.
        raise AuthError(401, "service_account_token_must_target_the_service")
    return email
