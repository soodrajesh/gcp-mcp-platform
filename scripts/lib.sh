#!/usr/bin/env bash
# Shared helpers. Sourced, not executed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1${2:+ ($2)}"; }

[ -f "$ROOT/deploy.env" ] && set -a && . "$ROOT/deploy.env" && set +a

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
ADMIN_EMAIL="${ADMIN_EMAIL:-$(gcloud config get-value account 2>/dev/null)}"
ALERT_EMAIL="${ALERT_EMAIL:-$ADMIN_EMAIL}"
[ -n "$PROJECT_ID" ] || die "no project: set PROJECT_ID in deploy.env or run 'gcloud config set project'"

TF="terraform -chdir=$ROOT/terraform"
STATE_BUCKET="${PROJECT_ID}-tfstate"

# Firestore database ids are not reusable straight after deletion: one suffix per deployment.
[ -s "$ROOT/.deploy-suffix" ] || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$ROOT/.deploy-suffix"
SUFFIX="$(cat "$ROOT/.deploy-suffix")"

export TF_VAR_project_id="$PROJECT_ID" TF_VAR_region="$REGION" TF_VAR_admin_email="$ADMIN_EMAIL" \
       TF_VAR_alert_email="$ALERT_EMAIL" TF_VAR_suffix="$SUFFIX"

tf_init() { $TF init -input=false -backend-config="bucket=$STATE_BUCKET" >/dev/null; }

tf_apply() {
  if [ -s "$ROOT/.last-image" ]; then TF_VAR_image="$(cat "$ROOT/.last-image")"; export TF_VAR_image; fi
  $TF apply -input=false -auto-approve "$@"
}

# Identity token for an MCP service, impersonating a service account.
#   id_token <audience>              -> mcp-operator (the human's caller identity; see ADR 0005 —
#                                        a raw human `gcloud auth print-identity-token` is truncated
#                                        in transit by Cloud Run's front end and cannot be used here)
#   id_token <audience> <sa-name>    -> e.g. mcp-agent
id_token() {
  local sa="${2:-mcp-operator}"
  gcloud auth print-identity-token --impersonate-service-account="$sa@$PROJECT_ID.iam.gserviceaccount.com" \
    --audiences="$1" --include-email 2>/dev/null
}

# The RAW human token, for the one test that documents why it can't be used (ADR 0005).
id_token_human() { gcloud auth print-identity-token 2>/dev/null; }

# The Python environment for the MCP client and unit tests.
PY="$ROOT/.venv/bin/python"
ensure_venv() {
  [ -x "$PY" ] || { python3 -m venv "$ROOT/.venv" && "$ROOT/.venv/bin/pip" install -q -r "$ROOT/app/requirements-dev.txt"; }
}
