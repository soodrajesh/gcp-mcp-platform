#!/usr/bin/env bash
# Live test suite: the deployed MCP servers, driven through the real MCP protocol as five different
# identities so every layer of the access model is exercised, each negative next to its positive.
#   operator   registered, all scopes            agent    registered, read-only scopes
#   burst      registered, ops:read only         guest    Cloud Run invoker but NOT registered
#   stranger   no invoker role at all
source "$(dirname "$0")/lib.sh"
need gcloud; need bq; need curl; need jq
ensure_venv
PASS=0; FAIL=0
check() { # <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); ok "$desc"; else FAIL=$((FAIL+1)); printf '\033[1;31m✘ %s\033[0m\n' "$desc"; fi
}
eq()  { [ "$1" = "$2" ]; }
ge()  { [ "${1:-0}" -ge "$2" ]; }
le()  { [ "${1:-0}" -le "$2" ]; }
contains() { grep -q -- "$2" <<<"$1"; }
excludes() { ! grep -q -- "$2" <<<"$1"; }
one_of() { local v="$1"; shift; for x in "$@"; do [ "$v" = "$x" ] && return 0; done; return 1; }

tf_init
out() { $TF output -raw "$1"; }
OPS="$(out ops_url)"; NOTES="$(out notes_url)"; OPS_AUD="$(out ops_audience)"; NOTES_AUD="$(out notes_audience)"
DB="$(out firestore_db)"; AUDIT_DS="$(out audit_dataset)"
mcp() { "$PY" "$ROOT/scripts/mcp_client.py" "$@" || true; }   # never aborts the suite; the JSON says what happened
jq_() { jq -r "$1" <<<"$2"; }
status() { # <url> <token> -> HTTP status of a raw tools/list POST
  curl -s -o /dev/null -w '%{http_code}' -X POST "$1/mcp" -H "Authorization: Bearer $2" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
}
body() { curl -s -X POST "$1/mcp" -H "Authorization: Bearer $2" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'; }

T_OP_OPS="$(id_token "$OPS_AUD")";        T_OP_NOTES="$(id_token "$NOTES_AUD")"
T_AG_OPS="$(id_token "$OPS_AUD" mcp-agent)"; T_AG_NOTES="$(id_token "$NOTES_AUD" mcp-agent)"
T_GUEST="$(id_token "$OPS_AUD" mcp-guest)"; T_STRANGER="$(id_token "$OPS_AUD" mcp-stranger)"
T_BURST="$(id_token "$OPS_AUD" mcp-burst)"; T_BURST_NOTES="$(id_token "$NOTES_AUD" mcp-burst)"
MARK="marker-$(date +%s)-$RANDOM"

log "1. Infrastructure"
check "the caller-policy audience is exactly the service URL Cloud Run issues" eq "$OPS" "$OPS_AUD"
for svc in mcp-ops mcp-notes; do
  POL="$(gcloud run services get-iam-policy "$svc" --project "$PROJECT_ID" --region "$REGION" --format=json)"
  check "$svc has no allUsers / allAuthenticatedUsers binding" eq "$(jq '[.bindings[]?.members[]?|select(.=="allUsers" or .=="allAuthenticatedUsers")]|length' <<<"$POL")" 0
  check "$svc: mcp-stranger is not an invoker (but mcp-guest is)" \
    eq "$(jq -r '[.bindings[]?|select(.role=="roles/run.invoker")|.members[]]|map(select(test("mcp-stranger")))|length' <<<"$POL")/$(jq -r '[.bindings[]?|select(.role=="roles/run.invoker")|.members[]]|map(select(test("mcp-guest")))|length' <<<"$POL")" "0/1"
done
check "Firestore database $DB exists (native mode)" contains "$(gcloud firestore databases describe --database "$DB" --project "$PROJECT_ID" --format='value(type)')" FIRESTORE_NATIVE
check "rate-limit TTL policy on ratelimit.expire_at is ACTIVE" \
  eq "$(gcloud firestore fields describe expire_at --collection-group ratelimit --database "$DB" --project "$PROJECT_ID" --format='value(ttlConfig.state)')" ACTIVE

log "2. Layer 1 — Cloud Run IAM keeps unauthorised callers out before any of our code runs"
check "no token is refused (401/403)" one_of "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$OPS/mcp")" 401 403
check "a garbage token is refused (401/403)" one_of "$(status "$OPS" not.a.jwt)" 401 403
check "mcp-stranger (valid token, no invoker role) is refused at the platform (403)" eq "$(status "$OPS" "$T_STRANGER")" 403
check "…and the refusal is Cloud Run's, not ours (no app JSON error body)" \
  excludes "$(body "$OPS" "$T_STRANGER")" unregistered_caller
check "a token minted for the NOTES audience is refused by the OPS service" one_of "$(status "$OPS" "$T_OP_NOTES")" 401 403

log "3. Layer 2 — the application: registration, scopes"
check "mcp-guest passes Cloud Run but the app refuses it (403 unregistered_caller)" \
  eq "$(status "$OPS" "$T_GUEST")/$(jq_ .error "$(body "$OPS" "$T_GUEST")")" "403/unregistered_caller"
LIST_OP="$(mcp "$OPS" "$T_OP_OPS" list)"
check "operator lists the 3 ops tools" eq "$(jq -c .tools <<<"$LIST_OP")" '["estimate_bigquery_cost","list_cloud_run_services","recent_errors"]'
check "operator lists the 4 notes tools" eq "$(jq -c .tools <<<"$(mcp "$NOTES" "$T_OP_NOTES" list)")" '["add_note","delete_note","get_note","search_notes"]'
check "mcp-agent (read-only) can call an ops tool" eq "$(jq_ .is_error "$(mcp "$OPS" "$T_AG_OPS" call list_cloud_run_services '{}')")" false
R="$(mcp "$NOTES" "$T_AG_NOTES" call add_note '{"title":"x","body":"y"}')"
check "mcp-agent cannot WRITE notes (missing scope notes:write)" eq "$(jq_ .is_error <<<"$R")/$(contains "$R" 'notes:write' && echo y)" "true/y"
R="$(mcp "$NOTES" "$T_BURST_NOTES" call search_notes '{}')"
check "mcp-burst (ops:read only) cannot even READ notes (missing notes:read)" eq "$(jq_ .is_error <<<"$R")/$(contains "$R" 'notes:read' && echo y)" "true/y"

log "4. Ops tools are real, read-only and validated"
R="$(mcp "$OPS" "$T_OP_OPS" call list_cloud_run_services '{}')"
check "list_cloud_run_services sees both MCP services" eq "$(jq -r '.text|fromjson|[.services[].name]|map(select(startswith("mcp-")))|sort|join(",")' <<<"$R")" "mcp-notes,mcp-ops"
check "…and reports the image as digest-pinned" contains "$R" 'sha256:'
R="$(mcp "$OPS" "$T_OP_OPS" call estimate_bigquery_cost '{"sql":"SELECT word FROM `bigquery-public-data.samples.shakespeare`"}')"
check "estimate_bigquery_cost dry-runs a public table (bytes > 0)" ge "$(jq -r '.text|fromjson|.bytes_processed' <<<"$R")" 1
check "…a syntax error is reported as a tool error, not a crash" eq "$(jq_ .is_error "$(mcp "$OPS" "$T_OP_OPS" call estimate_bigquery_cost '{"sql":"SELEKT nothing"}')")" true
R="$(mcp "$OPS" "$T_OP_OPS" call recent_errors '{"service":"mcp-ops","minutes":60}')"
check "recent_errors returns a well-formed result" eq "$(jq -r '.text|fromjson|.service' <<<"$R")" mcp-ops
check "recent_errors rejects a log-filter injection attempt" \
  eq "$(jq_ .is_error "$(mcp "$OPS" "$T_OP_OPS" call recent_errors '{"service":"x\" OR severity>=DEFAULT OR \"","minutes":5}')")" true
check "recent_errors rejects an out-of-range window" eq "$(jq_ .is_error "$(mcp "$OPS" "$T_OP_OPS" call recent_errors '{"service":"mcp-ops","minutes":99999}')")" true

log "5. Notes: tenant isolation and input limits"
R="$(mcp "$NOTES" "$T_OP_NOTES" call add_note "{\"title\":\"isolation probe\",\"body\":\"$MARK\",\"tags\":[\"probe\"]}")"
NOTE_ID="$(jq -r '.text|fromjson|.id' <<<"$R")"
check "operator can add a note (got a 32-hex id)" eq "$(echo "$NOTE_ID" | grep -cE '^[0-9a-f]{32}$')" 1
check "operator finds it by content" eq "$(jq -r '.text|fromjson|.count' <<<"$(mcp "$NOTES" "$T_OP_NOTES" call search_notes "{\"query\":\"$MARK\"}")")" 1
check "mcp-agent (read scope) searching for the same text finds NOTHING" eq "$(jq -r '.text|fromjson|.count' <<<"$(mcp "$NOTES" "$T_AG_NOTES" call search_notes "{\"query\":\"$MARK\"}")")" 0
A="$(mcp "$NOTES" "$T_AG_NOTES" call get_note "{\"note_id\":\"$NOTE_ID\"}")"
B="$(mcp "$NOTES" "$T_OP_NOTES" call get_note '{"note_id":"00000000000000000000000000000000"}')"
check "mcp-agent cannot fetch the operator's note by id (not found)" eq "$(jq_ .is_error <<<"$A")/$(jq_ .text <<<"$A" | grep -c 'not found')" "true/1"
check "…and the error is identical to a note that never existed (no existence oracle)" eq "$(jq_ .text <<<"$A")" "$(jq_ .text <<<"$B")"
check "results warn that note text is untrusted data" contains "$(mcp "$NOTES" "$T_OP_NOTES" call get_note "{\"note_id\":\"$NOTE_ID\"}")" 'not instructions'
check "an oversized body is rejected" eq "$(jq_ .is_error "$(mcp "$NOTES" "$T_OP_NOTES" call add_note "{\"title\":\"t\",\"body\":\"$(head -c 4100 /dev/zero | tr '\0' a)\"}")")" true
check "operator can delete it" eq "$(jq_ .is_error "$(mcp "$NOTES" "$T_OP_NOTES" call delete_note "{\"note_id\":\"$NOTE_ID\"}")")" false
check "…and it is gone" eq "$(jq_ .is_error "$(mcp "$NOTES" "$T_OP_NOTES" call get_note "{\"note_id\":\"$NOTE_ID\"}")")" true

log "6. Rate limit: shared across instances, per caller"
CODES="$(for _ in $(seq 1 130); do status "$OPS" "$T_BURST"; echo; done | tr -d ' ' | grep -E '^[0-9]{3}$')"
N200="$(grep -c '^200$' <<<"$CODES" || true)"; N429="$(grep -c '^429$' <<<"$CODES" || true)"
check "130 rapid calls by mcp-burst: at least 60 served ($N200)" ge "$N200" 60
check "…and at least 10 were refused with 429 ($N429)" ge "$N429" 10
RA="$(curl -s -D - -o /dev/null -X POST "$OPS/mcp" -H "Authorization: Bearer $T_BURST" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | tr -d '\r' | awk -F': ' 'tolower($1)=="retry-after"{print $2}')"
check "…a 429 carries a numeric Retry-After header (${RA:-none})" eq "$(echo "${RA:-x}" | grep -cE '^[0-9]+$')" 1
check "the operator is NOT affected by mcp-burst's exhausted budget" eq "$(status "$OPS" "$T_OP_OPS")" 200
DOCS="$("$PY" - <<PY
from google.cloud import firestore
c = firestore.Client(project="$PROJECT_ID", database="$DB")
d = list(c.collection("ratelimit").limit(20).stream())
print(len(d), all("expire_at" in x.to_dict() for x in d))
PY
)"
check "counters live in Firestore with an expire_at for TTL cleanup ($DOCS)" contains "$DOCS" "True"

log "7. Audit trail in BigQuery (waits for the log sink)"
AT="\`$PROJECT_ID.$AUDIT_DS.run_googleapis_com_stdout\`"
qa() { bq --project_id "$PROJECT_ID" query --nouse_legacy_sql --quiet --format=csv "SELECT COUNT(*) FROM $AT WHERE $1" 2>/dev/null | tail -1; }
end=$(( $(date +%s) + 420 ))
until [ "$(qa "jsonPayload.caller='mcp-burst@$PROJECT_ID.iam.gserviceaccount.com' AND jsonPayload.reason='rate_limited'" || echo 0)" -ge 1 ] 2>/dev/null; do
  [ "$(date +%s)" -lt "$end" ] || break; sleep 15
done
check "rate-limited requests are audited with the caller and reason" ge "$(qa "jsonPayload.caller='mcp-burst@$PROJECT_ID.iam.gserviceaccount.com' AND jsonPayload.reason='rate_limited'")" 1
check "the read-only agent's refused write is audited (reason missing_scope:notes:write)" ge "$(qa "jsonPayload.caller='mcp-agent@$PROJECT_ID.iam.gserviceaccount.com' AND jsonPayload.tool='add_note' AND jsonPayload.decision='denied' AND jsonPayload.reason='missing_scope:notes:write'")" 1
check "mcp-guest's refusal is audited (unregistered_caller)" ge "$(qa "jsonPayload.caller='mcp-guest@$PROJECT_ID.iam.gserviceaccount.com' AND jsonPayload.reason='unregistered_caller'")" 1
check "the operator's allowed add_note is audited with a latency" ge "$(qa "jsonPayload.caller='$(echo "$ADMIN_EMAIL" | tr 'A-Z' 'a-z')' AND jsonPayload.tool='add_note' AND jsonPayload.decision='allowed' AND jsonPayload.latency_ms IS NOT NULL")" 1
check "argument VALUES never reach the log: the note body marker is absent everywhere" \
  eq "$(bq --project_id "$PROJECT_ID" query --nouse_legacy_sql --quiet --format=csv "SELECT COUNT(*) FROM $AT WHERE TO_JSON_STRING(jsonPayload) LIKE '%$MARK%'" 2>/dev/null | tail -1)" 0
check "…while the argument NAMES and a digest are recorded" ge "$(qa "jsonPayload.tool='add_note' AND jsonPayload.args_digest IS NOT NULL AND ARRAY_LENGTH(jsonPayload.arg_names) >= 2")" 1

log "8. Least privilege"
PROJ="$(gcloud projects get-iam-policy "$PROJECT_ID" --format=json)"
roles_of() { jq -r --arg m "serviceAccount:$1@$PROJECT_ID.iam.gserviceaccount.com" '[.bindings[]|select(.members|index($m))|.role]|sort|join(",")' <<<"$PROJ"; }
check "ops server: run.viewer + logging.viewer + bigquery.jobUser + datastore.user + logWriter only" \
  eq "$(roles_of mcp-ops-server)" "roles/bigquery.jobUser,roles/datastore.user,roles/logging.logWriter,roles/logging.viewer,roles/run.viewer"
check "notes server: datastore.user + logWriter only" eq "$(roles_of mcp-notes-server)" "roles/datastore.user,roles/logging.logWriter"
check "client service accounts hold NO project roles" eq "$(roles_of mcp-agent)$(roles_of mcp-burst)$(roles_of mcp-guest)$(roles_of mcp-stranger)" ""
check "no service account of this platform has a user-managed key" \
  eq "$(for s in mcp-ops-server mcp-notes-server mcp-build mcp-agent mcp-burst mcp-guest mcp-stranger; do gcloud iam service-accounts keys list --iam-account "$s@$PROJECT_ID.iam.gserviceaccount.com" --managed-by=user --format='value(name)'; done | wc -l | tr -d ' ')" 0

echo
printf '\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
