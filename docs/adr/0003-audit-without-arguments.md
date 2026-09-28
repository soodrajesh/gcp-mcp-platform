# 0003 — Audit every decision; never log argument values

Each allow or deny is one JSON line: caller, server, tool, decision, reason, latency, `args_digest` (sha256 of the canonical arguments, 16 hex) and `arg_names`. A log sink lands `event=mcp_call` lines in BigQuery.

Argument *values* are deliberately absent: notes hold user text, and SQL passed to the cost tool can embed data. A digest still lets two calls be correlated and an unusual argument shape stand out. This is asserted live: a unique marker written into a note body is searched for across the entire audit table and must not appear (`test §7`).

Refusals that happen before we know who called (no token, bad token) are logged with `caller=unauthenticated` and the reason; the verifier's error detail is included in the *log only*, never in the HTTP response.
