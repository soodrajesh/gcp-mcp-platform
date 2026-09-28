# 0005 — Human operators authenticate as a service account too

**Status:** accepted (found live: the deployed service consistently returned 401 for the operator)

## What happened
`scripts/test.sh` failed at the very first live call: `gcloud auth print-identity-token` (a human account, no
audience) produced a 401 `invalid_token:MalformedError` — *"Could not verify token signature."* — from the
deployed app, even though the exact same token verified successfully run locally, in a Cloud Run **Job**, and
through `gcloud run services proxy`.

## Root cause
Added a debug log of the raw `Authorization` header length as the ASGI app receives it (before any of our
code runs):

```
sent by curl: 826 chars   ->   received by the app: 518 chars
```

A fresh service-account token used the same way arrived **byte-for-byte intact** (812 sent, 819 received —
`"Bearer "` + 812). The difference is not size: it is that the human token's audience is
`32555940559.apps.googleusercontent.com`, the Cloud SDK's own OAuth client id. Cloud Run's front end validates
that token for its own `roles/run.invoker` check (which is why the request reaches the app at all — the
platform's own IAM layer accepted it) but **forwards a truncated Authorization header to the container** when
the token was issued for Google's own first-party OAuth client. A service-account token — issued directly for
this service's audience — is not special-cased and passes through whole.

## Decision
The human operator gets a dedicated service account, `mcp-operator`, with every scope, exactly like `mcp-agent`
and `mcp-burst`. `scripts/lib.sh id_token` impersonates it by default (`gcloud auth print-identity-token
--impersonate-service-account=... --audiences=<service>`), producing an ordinary, non-redacted token. The raw
human path is kept in the code (`caller_email` still explicitly refuses it from service accounts, accepts it
from human accounts) and in `id_token_human` for one test that turns the failure into a permanent, understood
assertion instead of a mystery: **test §1b** confirms a raw human token is refused with `invalid_token`, so a
regression here fails loudly rather than silently working around itself.

## Consequences
* Every caller in this system — human or machine — presents a token whose audience is the specific service
  being called. Nothing relies on `32555940559.apps.googleusercontent.com` reaching the app intact.
* [Runbook 2](../runbooks/02-connect-claude-code.md) has an agent (human or AI) impersonate its own dedicated
  service account, which is also simply the more correct integration pattern: short-lived, service-scoped
  tokens rather than a long-lived human session.
* This is a Cloud Run **platform** behavior, not a bug in this repository, and it was not something this design
  could have anticipated from documentation — only from a debug header dump against the live deployment.
