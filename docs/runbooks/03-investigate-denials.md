# 3. Investigate denials

An alert ("MCP: burst of refused calls") means more than 25 requests were refused in 5 minutes.

```sql
-- who, what, why, in the last hour
SELECT timestamp, jsonPayload.caller, jsonPayload.tool, jsonPayload.reason
FROM `PROJECT.mcp_audit.run_googleapis_com_stdout`
WHERE jsonPayload.event = 'mcp_call' AND jsonPayload.decision = 'denied'
  AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
ORDER BY timestamp DESC;

-- a caller's own call volume (for tuning RATE_LIMIT_PER_MIN)
SELECT jsonPayload.caller, COUNT(*) FROM `PROJECT.mcp_audit.run_googleapis_com_stdout`
WHERE jsonPayload.event = 'mcp_call' AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
GROUP BY 1 ORDER BY 2 DESC;
```

Common `reason` values: `missing_bearer_token` / `invalid_token:*` (layer 1/2 — bad or absent token;
a human's own raw token always shows here, see ADR 0005), `unregistered_caller` (valid token, not in the
policy), `rate_limited` (over budget this minute), `missing_scope:<scope>` (registered but not allowed to
call that tool).

Argument **values** are never logged, by design ([ADR 0003](../adr/0003-audit-without-arguments.md)) — the
`args_digest` lets you correlate repeated calls without ever seeing note bodies or SQL text.
