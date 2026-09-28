import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from mcpkit.policy import Policy  # noqa: E402
from mcpkit.ratelimit import MemoryStore, RateLimiter  # noqa: E402

os.environ.setdefault("PROJECT_ID", "test-project")

TOKENS = {  # token -> claims: stands in for Google's signature check
    "tok-op": {"email": "op@example.com", "email_verified": True},
    "tok-agent": {"email": "agent@p.iam.gserviceaccount.com", "email_verified": True},
    "tok-stranger": {
        "email": "stranger@p.iam.gserviceaccount.com",
        "email_verified": True,
    },
    "tok-unverified": {"email": "op@example.com", "email_verified": False},
    "tok-noemail": {"sub": "123"},
}
POLICY = {
    "op@example.com": ["ops:read", "notes:read", "notes:write"],
    "agent@p.iam.gserviceaccount.com": ["ops:read", "notes:read"],
}


def fake_verifier(token, audiences):
    assert audiences == ["https://svc.example"]
    if token not in TOKENS:
        raise ValueError("bad signature")
    return TOKENS[token]


@pytest.fixture
def make_app(monkeypatch):
    monkeypatch.setenv("ALLOWED_AUDIENCES", "https://svc.example")

    def _make(server="notes", limit=1000):
        from main import build_app

        return build_app(
            server,
            limiter=RateLimiter(MemoryStore(), limit),
            verifier=fake_verifier,
            policy=Policy(POLICY),
        )

    return _make


HEADERS = {
    "Accept": "application/json, text/event-stream",
    "Content-Type": "application/json",
}


def rpc(method, params=None, id_=1):
    return json.dumps(
        {"jsonrpc": "2.0", "id": id_, "method": method, "params": params or {}}
    )
