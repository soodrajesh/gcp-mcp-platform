"""One image, two MCP servers: SERVER=ops or SERVER=notes selects which tools this instance serves.
Everything security-relevant (auth, registration, rate limit, audit, scopes) is in mcpkit."""

from __future__ import annotations

import importlib
import os

from mcp.server.fastmcp import FastMCP
from mcpkit.guard import GuardMiddleware
from mcpkit.policy import Policy
from mcpkit.ratelimit import FirestoreStore, MemoryStore, RateLimiter


def build_app(
    server: str | None = None,
    *,
    limiter: RateLimiter | None = None,
    verifier=None,
    policy: Policy | None = None,
):
    server = server or os.environ["SERVER"]
    mod = importlib.import_module(f"servers.{server}")
    mcp = FastMCP(
        f"gcp-{server}",
        stateless_http=True,
        json_response=True,
        host="0.0.0.0",
        streamable_http_path="/mcp",
    )
    mod.register(mcp)
    if limiter is None:
        limit = int(os.environ.get("RATE_LIMIT_PER_MIN", "60"))
        if os.environ.get("FIRESTORE_DB"):
            from google.cloud import firestore

            client = firestore.Client(project=os.environ["PROJECT_ID"], database=os.environ["FIRESTORE_DB"])
            limiter = RateLimiter(FirestoreStore(client), limit)
        else:
            limiter = RateLimiter(MemoryStore(), limit)
    policy = policy or Policy.from_json(os.environ.get("CALLERS_JSON", "{}"))
    audiences = [a for a in os.environ.get("ALLOWED_AUDIENCES", "").split(",") if a]
    return GuardMiddleware(
        mcp.streamable_http_app(),
        server=server,
        policy=policy,
        limiter=limiter,
        audiences=audiences,
        verifier=verifier,
    )


app = build_app() if os.environ.get("SERVER") else None
