#!/usr/bin/env bash
# Build the MCP platform end to end, then prove it works:
#   state bucket -> Firestore, audit sink, IAM, alerts, registry -> image build -> two private Cloud Run
#   MCP services -> live tests through the real MCP protocol as five different identities.
#   ./scripts/up.sh [--skip-tests]
source "$(dirname "$0")/lib.sh"
SKIP_TESTS=0; [ "${1:-}" = "--skip-tests" ] && SKIP_TESTS=1
need gcloud; need terraform; need bq; need python3; need curl; need jq

log "Project $PROJECT_ID · $REGION · operator $ADMIN_EMAIL · suffix $SUFFIX"
log "1/6 Terraform state bucket"
"$ROOT/scripts/bootstrap.sh" "$PROJECT_ID" "$REGION" >/dev/null && ok "gs://$STATE_BUCKET"
tf_init

log "2/6 Phase 1: Firestore (+TTL), audit dataset and sink, identities, alerts, registry"
tf_apply
out() { $TF output -raw "$1"; }
REPO="$(out artifact_repo)"; BUCKET="$(out build_bucket)"; BUILD_SA="$(out build_sa)"

log "3/6 Unit tests, then build the image (Cloud Build, dedicated least-privilege SA)"
ensure_venv
PYTHONPATH=app "$PY" -m pytest app/tests -q
TAG="v$(date +%y%m%d-%H%M%S)"
gcloud builds submit --project "$PROJECT_ID" --region "$REGION" --config cloudbuild.yaml \
  --service-account "projects/$PROJECT_ID/serviceAccounts/$BUILD_SA" \
  --gcs-source-staging-dir "gs://$BUCKET/src" --substitutions "_REPO=$REPO,_TAG=$TAG" .
DIGEST="$(gcloud artifacts docker images describe "$REPO/mcp:$TAG" --format='get(image_summary.digest)')"
IMG="$REPO/mcp@$DIGEST"; ok "image $IMG"; echo "$IMG" > "$ROOT/.last-image"

log "4/6 Phase 2: the two MCP services"
tf_apply
ok "ops   $(out ops_url)"; ok "notes $(out notes_url)"

log "5/6 Smoke: list tools as the operator"
for svc in ops notes; do
  URL="$(out "${svc}_url")"; AUD="$(out "${svc}_audience")"
  "$PY" scripts/mcp_client.py "$URL" "$(id_token "$AUD")" list
done

if [ "$SKIP_TESTS" = 1 ]; then log "Skipping tests"; else log "6/6 Live test suite"; "$ROOT/scripts/test.sh"; fi
log "DONE — connect an agent: docs/runbooks/02-connect-claude-code.md · tear down: ./scripts/down.sh"
