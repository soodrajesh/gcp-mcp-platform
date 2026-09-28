#!/usr/bin/env python3
"""Generates docs/img/architecture.svg (PNG via docs/diagrams/render.py)."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from archlib import Diagram  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "img", "architecture.svg")

W, H = 1780, 1320
d = Diagram(W, H, "Hardened remote MCP servers on Cloud Run",
            "Google identity tokens verified twice · per-caller scopes from a reviewed policy · Firestore rate limit · tenant isolation · BigQuery audit trail")

d.group(190, 100, 1480, 690, "Google Cloud project  ·  europe-west1", "#1a73e8", dash=False, fill="#f8faff", label_w=330)

d.node("agent", 70, 300, "MCP client", "user", "actor", "Claude Code, an agent,\nor a person (proxy)")
d.node("iam", 330, 300, "Cloud Run IAM", "shield", "security", "layer 1: invoker role +\ntoken audience")
d.node("ops", 700, 300, "mcp-ops", "run", "compute", "layer 2 in-app: verify token,\nregistered?, rate limit, scope")
d.node("notes", 1000, 300, "mcp-notes", "run", "compute", "same guard,\nper-owner notes")
d.node("apis", 700, 500, "Project APIs", "cloud", "ops", "Cloud Run · Logging ·\nBigQuery dry-run (read-only)")
d.node("fs", 1000, 500, "Firestore", "db", "data", "notes · rate-limit counters\n(TTL clean-up)")
d.node("logs", 1280, 300, "Cloud Logging", "policy", "ops", "one JSON line per decision\nno argument values")
d.node("bq", 1280, 500, "BigQuery mcp_audit", "db", "data", "log sink, partitioned")
d.node("metric", 1560, 300, "Log-based metric", "chart", "ops", "denied calls")
d.node("alert", 1560, 500, "Alert policy", "bolt", "ops", "> 25 in 5 min")

d.edge("agent", "iam", "h", num=1, label="Bearer ID token")
d.edge("iam", "ops", "h", num=2, label="allowed callers only")
d.path([(330, 270), (330, 150), (1000, 150), (1000, 270)], num=2, label="", lab_at=(660, 138))
d.edge("ops", "apis", "v", num=3, label="read-only tools")
d.edge("notes", "fs", "v", num=4, label="owner-scoped")
d.path([(730, 320), (730, 400), (1000, 400), (1000, 470)], num=5, label="rate-limit counter", lab_at=(880, 388))
d.edge("notes", "logs", "h", num=6)
d.path([(700, 270), (700, 200), (1280, 200), (1280, 270)], label="", lab_at=(990, 188))
d.edge("logs", "bq", "v", num=7, label="sink")
d.edge("logs", "metric", "h", num=8)
d.edge("metric", "alert", "v")

d.badge(250, 830, "9", "#1e8e3e")
d.text(270, 835, "Five identities exercise every layer: operator (all scopes), agent (read-only), burst (ops:read), guest (may invoke, NOT registered), stranger (may not invoke).", 12, "#3c4043")
d.text(270, 853, "Server service accounts hold only what their tools need; none has a key. Tool arguments are never logged: a digest and the argument names are.", 12, "#3c4043")

d.band(190, 880, 1480, 110, "WHAT THIS DOES NOT DO  ·  see docs/threat-model.md", "#d93025", "#fff8f7")
d.text(220, 922, "No OAuth authorization server and no IAP: humans and agents authenticate with Google identity tokens. Human CLI tokens carry the shared gcloud client audience (accepted for", 12.5, "#3c4043")
d.text(220, 946, "people, refused for service accounts). Note text is untrusted data: results carry a warning, but a model can still be steered by it. Rate limits are per caller, fixed-window.", 12.5, "#3c4043")

d.legend(34, 1020, "Numbered flows", [
    ("1", "The client sends a Google-signed identity token; the service URL is the audience for service accounts"),
    ("2", "Cloud Run IAM rejects callers without roles/run.invoker before any of our code runs (mcp-stranger)"),
    ("3", "mcp-ops tools: list services, recent errors of a service (validated), dry-run BigQuery cost — all read-only"),
    ("4", "mcp-notes tools: add, search, get, delete — each note belongs to its writer; others get an identical 'not found'"),
    ("5", "Every request increments a per-caller Firestore counter (shared across instances); over the limit returns 429 + Retry-After"),
    ("6", "Every allow/deny is logged as structured JSON with caller, tool, decision, reason, latency"),
    ("7", "A log sink lands those lines in BigQuery for SQL over who called what and what was refused"),
    ("8", "A log-based metric counts refusals; an alert policy emails on a burst"),
    ("9", "Scopes (ops:read, notes:read, notes:write) come from the CALLERS_JSON policy rendered by Terraform, reviewed in a PR"),
], w=1720)
d.key(34, 1270)
d.save(OUT)
