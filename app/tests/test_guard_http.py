import json

from starlette.testclient import TestClient

from tests.conftest import HEADERS, rpc


def post(client, token, body, extra=None):
    h = {
        **HEADERS,
        **({"Authorization": f"Bearer {token}"} if token else {}),
        **(extra or {}),
    }
    return client.post("/mcp", content=body, headers=h)


def test_no_token_is_401_and_audited(make_app, capsys):
    with TestClient(make_app()) as c:
        r = post(c, None, rpc("tools/list"))
    assert r.status_code == 401 and r.json()["error"] == "missing_bearer_token"
    line = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert line["decision"] == "denied" and line["reason"] == "missing_bearer_token" and line["caller"] == "unauthenticated"


def test_forged_token_is_401(make_app):
    with TestClient(make_app()) as c:
        assert post(c, "forged", rpc("tools/list")).status_code == 401


def test_unverified_email_and_missing_email_are_401(make_app):
    with TestClient(make_app()) as c:
        assert post(c, "tok-unverified", rpc("tools/list")).status_code == 401
        assert post(c, "tok-noemail", rpc("tools/list")).status_code == 401


def test_valid_token_but_unregistered_caller_is_403(make_app, capsys):
    with TestClient(make_app()) as c:
        r = post(c, "tok-stranger", rpc("tools/list"))
    assert r.status_code == 403 and r.json()["error"] == "unregistered_caller"
    assert '"reason": "unregistered_caller"' in capsys.readouterr().out


def test_registered_caller_can_list_tools(make_app):
    with TestClient(make_app()) as c:
        r = post(c, "tok-op", rpc("tools/list"))
    assert r.status_code == 200
    names = {t["name"] for t in r.json()["result"]["tools"]}
    assert names == {"add_note", "search_notes", "get_note", "delete_note"}


def test_rate_limit_returns_429_with_retry_after(make_app):
    with TestClient(make_app(limit=3)) as c:
        codes = [post(c, "tok-op", rpc("tools/list", id_=i)).status_code for i in range(5)]
        blocked = post(c, "tok-op", rpc("tools/list"))
    assert codes == [200, 200, 200, 429, 429]
    assert blocked.headers["retry-after"].isdigit()


def test_rate_limit_is_per_caller(make_app):
    with TestClient(make_app(limit=1)) as c:
        assert post(c, "tok-op", rpc("tools/list")).status_code == 200
        assert post(c, "tok-op", rpc("tools/list")).status_code == 429
        assert post(c, "tok-agent", rpc("tools/list")).status_code == 200  # a different budget


def test_human_token_with_the_cli_audience_is_accepted(make_app):
    with TestClient(make_app()) as c:
        assert post(c, "tok-human-cli-aud", rpc("tools/list")).status_code == 200


def test_service_account_token_with_the_cli_audience_is_refused(make_app, capsys):
    with TestClient(make_app()) as c:
        r = post(c, "tok-sa-cli-aud", rpc("tools/list"))
    assert r.status_code == 401 and r.json()["error"] == "service_account_token_must_target_the_service"
    assert "service_account_token_must_target_the_service" in capsys.readouterr().out
