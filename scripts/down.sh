#!/usr/bin/env bash
# Delete everything this repo created.
#   ./scripts/down.sh            destroy
#   ./scripts/down.sh --purge    also delete this repo's Terraform state (and the bucket if now empty)
source "$(dirname "$0")/lib.sh"
need gcloud; need terraform
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

log "Project $PROJECT_ID — destroying everything managed by this repo"
tf_init
TF_VAR_image="$(cat "$ROOT/.last-image" 2>/dev/null || echo "")"; export TF_VAR_image
$TF destroy -input=false -auto-approve
ok "destroyed"
rm -f "$ROOT/.last-image" "$ROOT/.deploy-suffix"; rm -rf "$ROOT/.test-tmp"

if [ "$PURGE" = 1 ]; then
  gcloud storage rm -r "gs://$STATE_BUCKET/mcp-platform/" --quiet >/dev/null 2>&1 || true
  if [ -z "$(gcloud storage ls "gs://$STATE_BUCKET/" 2>/dev/null)" ]; then
    gcloud storage rm -r "gs://$STATE_BUCKET" --quiet >/dev/null 2>&1 || true; ok "state prefix and (now empty) bucket removed"
  else ok "state prefix removed; bucket kept because other stacks still use it"; fi
else log "Kept state bucket gs://$STATE_BUCKET (a few KB; --purge removes it)"; fi

log "Anything left?"
echo "  Cloud Run services (mcp-*):        $(gcloud run services list --project "$PROJECT_ID" --region "$REGION" --format='value(metadata.name)' 2>/dev/null | grep -c '^mcp-' || true)"
echo "  Firestore databases (mcp-*):       $(gcloud firestore databases list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | grep -c '/mcp-' || true)"
echo "  BigQuery dataset (mcp_audit):      $(bq --project_id "$PROJECT_ID" ls -d 2>/dev/null | grep -c ' mcp_audit *$' || true)"
echo "  Service accounts (mcp-*):          $(gcloud iam service-accounts list --project "$PROJECT_ID" --format='value(email)' 2>/dev/null | grep -c '^mcp-' || true)"
echo "  Artifact Registry (mcp):           $(gcloud artifacts repositories list --project "$PROJECT_ID" --location "$REGION" --format='value(name)' 2>/dev/null | grep -c '/mcp$' || true)"
echo "  Logging sink (mcp-audit-to-bigquery): $(gcloud logging sinks list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | grep -c '^mcp-audit-to-bigquery$' || true)"
log "DONE"
