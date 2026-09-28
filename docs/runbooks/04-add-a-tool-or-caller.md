# 4. Add a tool or a caller

**A tool**: add a function to `app/servers/ops.py` or `notes.py`, decorated
`@mcp.tool()` then `@guarded(SERVER, "scope:name")` — pick an existing scope or add a new one to
`mcpkit/policy.py`'s `SCOPES`. Validate every input (bounds, regex, ids) before it reaches an API call;
`recent_errors`' service-name regex and `get_note`'s hex-id check are the pattern to copy. Add a unit
test in `app/tests/test_tools_scopes.py` with a `FakeDb`/`FakeCol` if it touches Firestore.

**A caller**: see [runbook 2](02-connect-claude-code.md#registering-a-new-agent).

**A new server** (a third MCP surface): add `app/servers/<name>.py` with a `register(mcp)` function, add
it to `local.services` in `terraform/run.tf`, give it a dedicated service account in `identities.tf` with
only the roles its tools need.
