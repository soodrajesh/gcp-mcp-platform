# Live test results

Captured output of `./scripts/test.sh` against the deployed platform (project `claude-code-507112`, europe-west1) on 2026-09-28, after settling from earlier debugging traffic: **52 passed, 0 failed**.

```
==> 1. Infrastructure
✔ the audience the app verifies is declared as a custom audience on the Cloud Run service
✔ mcp-ops has no allUsers / allAuthenticatedUsers binding
✔ mcp-ops: mcp-stranger is not an invoker (but mcp-guest is)
✔ mcp-notes has no allUsers / allAuthenticatedUsers binding
✔ mcp-notes: mcp-stranger is not an invoker (but mcp-guest is)
✔ Firestore database mcp-ca26b7 exists (native mode)
✔ rate-limit TTL policy on ratelimit.expire_at is ACTIVE
✔ the app rejects the human's own token (401): Cloud Run's front end truncates it in transit
✔ …specifically at signature verification, not because it is unregistered or malformed at rest
==> 2. Layer 1 — Cloud Run IAM keeps unauthorised callers out before any of our code runs
✔ no token is refused (401/403)
✔ a garbage token is refused (401/403)
✔ mcp-stranger (valid token, no invoker role) is refused at the platform (403)
✔ …and the refusal is Cloud Run's, not ours (no app JSON error body)
✔ a service-account token minted for the NOTES audience is refused by the OPS service
✔ a service-account token carrying the shared CLI audience is refused (401)
==> 3. Layer 2 — the application: registration, scopes
✔ mcp-guest passes Cloud Run but the app refuses it (403 unregistered_caller)
✔ operator lists the 3 ops tools
✔ operator lists the 4 notes tools
✔ mcp-agent (read-only) can call an ops tool
✔ mcp-agent cannot WRITE notes (missing scope notes:write)
✔ mcp-burst (ops:read only) cannot even READ notes (missing notes:read)
==> 4. Ops tools are real, read-only and validated
✔ list_cloud_run_services sees both MCP services
✔ …and reports the image as digest-pinned
✔ estimate_bigquery_cost dry-runs a public table (bytes > 0)
✔ …a syntax error is reported as a tool error, not a crash
✔ recent_errors returns a well-formed result
✔ recent_errors rejects a log-filter injection attempt
✔ recent_errors rejects an out-of-range window
==> 5. Notes: tenant isolation and input limits
✔ operator can add a note (got a 32-hex id)
✔ operator finds it by content
✔ mcp-agent (read scope) searching for the same text finds NOTHING
✔ mcp-agent cannot fetch the operator's note by id (not found)
✔ …and the error is identical to a note that never existed (no existence oracle)
✔ results warn that note text is untrusted data
✔ an oversized body is rejected
✔ operator can delete it
✔ …and it is gone
==> 6. Rate limit: shared across instances, per caller
✔ 130 rapid calls by mcp-burst: most of the per-minute budget served (60)
✔ …and at least 10 were refused with 429 (70)
✔ …a 429 carries a numeric Retry-After header (33)
✔ the operator is NOT affected by mcp-burst's exhausted budget
✔ counters live in Firestore with an expire_at for TTL cleanup (20 True)
==> 7. Audit trail in BigQuery (waits for the log sink)
✔ rate-limited requests are audited with the caller and reason
✔ the read-only agent's refused write is audited (reason missing_scope:notes:write)
✔ mcp-guest's refusal is audited (unregistered_caller)
✔ the operator's allowed add_note is audited with a latency
✔ argument VALUES never reach the log: the note body marker is absent everywhere
✔ …while the argument NAMES and a digest are recorded
==> 8. Least privilege
✔ ops server: run.viewer + logging.viewer + bigquery.jobUser + datastore.user + logWriter only
✔ notes server: datastore.user + logWriter only
✔ client service accounts hold NO project roles
✔ no service account of this platform has a user-managed key
52 passed, 0 failed
```

## What the first runs got wrong

| # | Found by | Defect | Fix |
|---|---|---|---|
| 1 | first `up.sh` | a human ID token audience cannot be constructed as a list in `id_token()` the way SA impersonation needs it | fixed the helper, then discovered defect 6 made this moot |
| 2 | smoke test | `google_cloud_run_v2_service.ui` custom audience was needed for anything to verify a *service-account* token; without it Cloud Run only accepted its own generated URL | added `custom_audiences` on both services |
| 3 | live calls with a human token | the app refused every call, even the operator's own, with `invalid_token:MalformedError` | root-caused below (defect 6) |
| 4 | investigation | a Rego-adjacent decoy: assumed a transient network blip fetching Google's certs; added a retry-on-failure to the verifier | harmless and kept, but not the real cause |
| 5 | investigation | a debug log of the raw ASGI `Authorization` header length proved the header itself arrived truncated — 826 sent, 518 received — **only** for tokens whose audience is `32555940559.apps.googleusercontent.com` (the gcloud SDK's own OAuth client); a service-account token of similar length arrived intact | this is a Cloud Run platform behavior, not a bug here |
| 6 | root cause | **Cloud Run's front end truncates the `Authorization` header in transit for tokens issued to Google's own first-party OAuth client id**, even though its own IAM invoker check (using the same, untruncated token) already accepted the request | every caller, including the human operator, now authenticates as a dedicated service account ([ADR 0005](adr/0005-human-callers-impersonate-too.md)); a live test (§1b) asserts the raw human token is refused, turning the finding into a permanent regression check |
| 7 | first full live run | two `jq_ <field> <<<"$VAR"` calls in test.sh passed nothing to the function (heredoc redirects stdin, which `jq_` never reads) | pass the variable as an argument |
| 8 | live run | `gcloud firestore fields describe` is not a real subcommand | switched to `gcloud firestore fields ttls list --filter` |
| 9 | live run | the audit-latency check still queried by the pre-ADR-0005 human email | updated to query the `mcp-operator` service account |
