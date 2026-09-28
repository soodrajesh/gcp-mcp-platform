# 0001 — Google identity tokens and Cloud Run IAM, not an OAuth authorization server or IAP

**Status:** accepted, with the trade-offs below

## Context
Remote MCP servers need to know *who* is calling. The MCP authorization spec describes OAuth 2.1 flows; running a compliant authorization server (or fronting with IAP) adds a load balancer, a custom domain and a moving part that costs money and can fail.

## Decision
Callers present a **Google-signed identity token** (`Authorization: Bearer …`). Two independent layers check it:

1. **Cloud Run IAM** — the caller needs `roles/run.invoker` on the service, and the token's audience must be the service URL or a declared custom audience. This runs before any of our code.
2. **The application** verifies the token again (signature, expiry, issuer, audience, verified email), then looks the email up in a caller policy (`CALLERS_JSON`, rendered by Terraform), then rate-limits, then checks the *scope* each tool requires.

## Consequences
* No public endpoint, no shared secrets, no client registration flow. Service accounts (agents, CI) and people authenticate with the same mechanism.
* Tokens live about an hour. A long-running agent must refresh; `gcloud run services proxy` does this for a human ([runbook 2](runbooks/02-connect-claude-code.md)).
* **Human tokens carry the gcloud CLI's OAuth client id as their audience** (user accounts cannot set one), so the app must accept that audience for people. It refuses it from service accounts, which can and must target the service (`test §2`, unit-tested).
* Clients that only speak the MCP OAuth flow cannot talk to this server without a proxy. Not an accident: this is a design for operators and their own agents, not for arbitrary third-party clients.
