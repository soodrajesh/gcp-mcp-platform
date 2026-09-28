# 2. Connect an agent (Claude Code or similar)

Every caller — human or agent — authenticates as a **service account** ([ADR 0005](../adr/0005-human-callers-impersonate-too.md):
a raw human `gcloud auth print-identity-token` is truncated in transit by Cloud Run's front end and
cannot be used here). Give the agent's operator a personal or shared service account, registered in
`terraform/run.tf`'s `callers` map with the scopes it needs, and let it impersonate that account.

## Claude Code (`claude mcp add`)

```bash
PROJECT_ID=$(gcloud config get-value project)
AUDIENCE="https://mcp-notes-$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)').europe-west1.run.app"
URL="$(gcloud run services describe mcp-notes --project "$PROJECT_ID" --region europe-west1 --format='value(status.url)')"

claude mcp add --transport http notes "$URL/mcp" \
  --header "Authorization: Bearer $(gcloud auth print-identity-token --impersonate-service-account=mcp-agent@$PROJECT_ID.iam.gserviceaccount.com --audiences=$AUDIENCE --include-email)"
```

Identity tokens live about an hour; re-run the `claude mcp add` (or script the header refresh) when it
expires. `scripts/mcp_client.py` is a minimal reference client if you are wiring up something other than
Claude Code:

```bash
.venv/bin/python scripts/mcp_client.py "$URL" "$TOKEN" list
.venv/bin/python scripts/mcp_client.py "$URL" "$TOKEN" call search_notes '{"query":"x"}'
```

## Registering a new agent

Add it to `client_sas` in `terraform/identities.tf` and to `callers` in `terraform/run.tf` with the
scopes it should have (`ops:read`, `notes:read`, `notes:write`), then `terraform apply`. It needs no
Cloud Run IAM invoker binding beyond what `local.invokers` already grants unless it's a genuinely new
identity outside that set.
