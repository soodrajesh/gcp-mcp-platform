"""Glue: ASGI middleware (authenticate, register, rate-limit, audit) and the per-tool scope guard."""

from __future__ import annotations

import contextvars
import functools
import json
import time
from collections.abc import Callable, Sequence

from mcpkit.audit import audit
from mcpkit.auth import AuthError, caller_email
from mcpkit.policy import Caller, Policy
from mcpkit.ratelimit import RateLimiter

current_caller: contextvars.ContextVar[Caller | None] = contextvars.ContextVar("current_caller", default=None)


async def _reply(send, status: int, body: dict, headers: dict[str, str] | None = None) -> None:
    payload = json.dumps(body).encode()
    hdrs = [
        (b"content-type", b"application/json"),
        (b"content-length", str(len(payload)).encode()),
    ]
    hdrs += [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()]
    await send({"type": "http.response.start", "status": status, "headers": hdrs})
    await send({"type": "http.response.body", "body": payload})


class GuardMiddleware:
    """Order matters: authenticate -> is the caller registered -> rate limit -> pass through.
    Every refusal is audited with the reason, whether or not we know who the caller is."""

    def __init__(self, app, *, server: str, policy: Policy, limiter: RateLimiter, audiences: Sequence[str],
                 verifier: Callable | None = None):  # fmt: skip
        self.app, self.server, self.policy, self.limiter, self.audiences = (
            app,
            server,
            policy,
            limiter,
            audiences,
        )
        self.verifier = verifier

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":  # lifespan etc. pass straight through
            return await self.app(scope, receive, send)
        headers = {k.decode().lower(): v.decode() for k, v in scope["headers"]}
        import json as _json
        import sys as _sys

        print(
            _json.dumps(
                {
                    "event": "debug_headers",
                    "n": len(scope["headers"]),
                    "auth_len": len(headers.get("authorization", "")),
                    "all_lens": {k: len(v) for k, v in headers.items()},
                }
            ),
            file=_sys.stdout,
            flush=True,
        )
        try:
            kwargs = {"verifier": self.verifier} if self.verifier else {}
            email = caller_email(headers.get("authorization"), self.audiences, **kwargs)
        except AuthError as exc:
            audit(
                server=self.server,
                caller="unauthenticated",
                tool="*",
                decision="denied",
                reason=exc.reason + (f" [{exc.detail}]" if exc.detail else ""),
                status=exc.status,
            )
            return await _reply(send, exc.status, {"error": exc.reason})
        caller = self.policy.lookup(email)
        if caller is None:
            audit(
                server=self.server,
                caller=email,
                tool="*",
                decision="denied",
                reason="unregistered_caller",
                status=403,
            )
            return await _reply(send, 403, {"error": "unregistered_caller"})
        allowed, retry_after = self.limiter.check(email)
        if not allowed:
            audit(
                server=self.server,
                caller=email,
                tool="*",
                decision="denied",
                reason="rate_limited",
                status=429,
            )
            return await _reply(send, 429, {"error": "rate_limited"}, {"retry-after": str(retry_after)})
        token = current_caller.set(caller)
        try:
            return await self.app(scope, receive, send)
        finally:
            current_caller.reset(token)


def guarded(server: str, scope: str):
    """Decorator for MCP tools: require `scope`, audit the decision and the outcome."""

    def deco(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            caller = current_caller.get()
            who = caller.email if caller else "unknown"
            if caller is None or scope not in caller.scopes:
                audit(
                    server=server,
                    caller=who,
                    tool=fn.__name__,
                    decision="denied",
                    reason=f"missing_scope:{scope}",
                    args=kwargs,
                )
                raise PermissionError(f"caller lacks required scope {scope!r}")
            t0 = time.monotonic()
            try:
                result = fn(*args, **kwargs)
            except Exception as exc:
                audit(server=server, caller=who, tool=fn.__name__, decision="allowed", reason=f"tool_error:{type(exc).__name__}",
                      args=kwargs, latency_ms=(time.monotonic() - t0) * 1000)  # fmt: skip
                raise
            audit(
                server=server,
                caller=who,
                tool=fn.__name__,
                decision="allowed",
                args=kwargs,
                latency_ms=(time.monotonic() - t0) * 1000,
            )
            return result

        return wrapper

    return deco
