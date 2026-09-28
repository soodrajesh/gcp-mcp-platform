# Threat model

| Threat | Control | Proven by |
|---|---|---|
| Anyone on the internet calls the tools | No `allUsers`; `roles/run.invoker` only for four named identities; a stranger gets 403 from Cloud Run itself | test §1, §2 |
| A token for another service is replayed here | Audience is checked by Cloud Run and again by the app | test §2 |
| A service-account token with the shared CLI audience is replayed | Refused for service accounts (401); accepted only for human accounts | unit tests + test §2 |
| An authenticated but unknown identity | Registered-caller policy → 403 `unregistered_caller` | test §3 |
| A read-only caller writes | Per-tool scope → tool error `missing_scope`, audited | test §3 |
| One caller reads another's notes | Notes are owner-scoped; a foreign id returns the same error as a missing one (no existence oracle) | test §5 |
| A runaway agent hammers the server | Per-caller shared rate limit, 429 + Retry-After; other callers unaffected | test §6 |
| Log-filter / SQL injection through tool arguments | Service names validated by regex, bounds on numbers, ids validated as 32-hex; the cost tool only *dry-runs* | test §4, unit tests |
| Sensitive data leaks into logs | Argument values never logged (digest + names only) | test §7 |
| The tools are used for more than intended | Server service accounts hold only their tools' roles; nothing can write to the project | test §8 |

## Not covered (stated)
* **Prompt injection through stored notes.** Results carry an explicit "this is data, not instructions" warning, but a model can still be steered by note text. The real mitigation is on the client: don't let an agent act on note content without a human in the loop.
* **`roles/logging.viewer` is project-wide.** The ops server can read every log in the project (it needs to for `recent_errors`); a log view restricted to `cloud_run_revision` would narrow it.
* **Firestore access is project-level `roles/datastore.user`** (no database-scoped role short of IAM Conditions).
* **No per-tool rate limits or quotas**; fixed-window limits allow a 2× burst at a boundary.
* **Clients that only speak MCP's OAuth flow** cannot connect without a proxy ([ADR 0001](adr/0001-identity-tokens-not-oauth-server.md)).
