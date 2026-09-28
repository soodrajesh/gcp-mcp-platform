import json

import pytest
from mcpkit import audit as audit_mod
from mcpkit.auth import AuthError, caller_email
from mcpkit.policy import Policy
from mcpkit.ratelimit import MemoryStore, RateLimiter


def test_policy_rejects_unknown_scopes_and_is_case_insensitive():
    with pytest.raises(ValueError):
        Policy({"a@b.c": ["ops:admin"]})
    assert Policy({"A@B.C": ["ops:read"]}).lookup("a@b.c").scopes == {"ops:read"}
    assert Policy({}).lookup("a@b.c") is None


def test_policy_from_json_rejects_non_objects():
    with pytest.raises(TypeError):
        Policy.from_json("[1,2]")
    assert Policy.from_json("").lookup("x@y.z") is None


def test_default_verifier_retries_once_then_succeeds():
    from mcpkit import auth as auth_mod

    calls = []

    def flaky_verify(token, request, audience):
        calls.append(1)
        if len(calls) == 1:
            raise ValueError("Could not verify token signature.")
        return {"email": "a@b.c", "email_verified": True}

    real = auth_mod.id_token.verify_oauth2_token
    auth_mod.id_token.verify_oauth2_token = flaky_verify
    try:
        claims = auth_mod._default_verifier("tok", ["aud"])
    finally:
        auth_mod.id_token.verify_oauth2_token = real
    assert claims["email"] == "a@b.c" and len(calls) == 2


def test_default_verifier_gives_up_after_two_failures():
    from mcpkit import auth as auth_mod

    def always_fails(token, request, audience):
        raise ValueError("Could not verify token signature.")

    real = auth_mod.id_token.verify_oauth2_token
    auth_mod.id_token.verify_oauth2_token = always_fails
    try:
        try:
            auth_mod._default_verifier("tok", ["aud"])
            raised = False
        except ValueError:
            raised = True
    finally:
        auth_mod.id_token.verify_oauth2_token = real
    assert raised


def test_caller_email_paths():
    ok = lambda t, a: {"email": "A@B.C", "email_verified": True}  # noqa: E731
    assert caller_email("Bearer t", ["aud"], verifier=ok) == "a@b.c"
    for header in (None, "", "Basic abc", "Bearer"):
        with pytest.raises(AuthError) as e:
            caller_email(header, ["aud"], verifier=ok)
        assert e.value.status == 401


def test_rate_limiter_window_rollover_and_retry_after():
    t = [1000.0]
    rl = RateLimiter(MemoryStore(), limit=2, window_s=60, clock=lambda: t[0])
    assert rl.check("a")[0] and rl.check("a")[0]
    allowed, retry = rl.check("a")
    assert not allowed and 1 <= retry <= 60
    t[0] += 60  # next window: a fresh budget
    assert rl.check("a")[0]
    assert rl.check("b")[0]  # other callers are independent


def test_audit_never_logs_argument_values(capsys):
    audit_mod.audit(
        server="notes",
        caller="a@b.c",
        tool="add_note",
        decision="allowed",
        args={"body": "TOP-SECRET-TEXT", "title": "t"},
    )
    out = capsys.readouterr().out
    assert "TOP-SECRET-TEXT" not in out
    entry = json.loads(out)
    assert entry["arg_names"] == ["body", "title"] and len(entry["args_digest"]) == 16 and entry["event"] == "mcp_call"


def test_audit_digest_is_stable_and_order_independent():
    assert audit_mod.args_digest({"a": 1, "b": 2}) == audit_mod.args_digest({"b": 2, "a": 1})
    assert audit_mod.args_digest({"a": 1}) != audit_mod.args_digest({"a": 2})
