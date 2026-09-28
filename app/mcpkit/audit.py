"""One structured JSON log line per decision. Cloud Run parses JSON stdout into jsonPayload; a log
sink routes `event=mcp_call` to BigQuery. Arguments are NOT logged (notes can hold sensitive text);
a digest and the argument names are enough to correlate calls and spot anomalies."""

from __future__ import annotations

import hashlib
import json
import sys
from typing import Any


def args_digest(args: dict[str, Any] | None) -> str:
    canon = json.dumps(args or {}, sort_keys=True, default=str, separators=(",", ":"))
    return hashlib.sha256(canon.encode()).hexdigest()[:16]


def audit(*, server: str, caller: str, tool: str, decision: str, reason: str = "", args: dict | None = None,
          latency_ms: float | None = None, status: int | None = None, stream=None) -> dict:  # fmt: skip
    entry = {
        "severity": "INFO" if decision == "allowed" else "WARNING",
        "event": "mcp_call",
        "server": server,
        "caller": caller,
        "tool": tool,
        "decision": decision,
        "reason": reason,
        "args_digest": args_digest(args),
        "arg_names": sorted((args or {}).keys()),
    }
    if latency_ms is not None:
        entry["latency_ms"] = round(latency_ms, 1)
    if status is not None:
        entry["status"] = status
    print(json.dumps(entry), file=stream or sys.stdout, flush=True)
    return entry
