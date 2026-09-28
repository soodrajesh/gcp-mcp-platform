"""Read-only operations tools for the project. Every tool needs the `ops:read` scope, validates its
inputs (they end up in API filters), and bounds its output."""

from __future__ import annotations

import os
import re
from datetime import datetime, timedelta, timezone

from mcp.server.fastmcp import FastMCP

from mcpkit.guard import guarded

SERVER = "ops"
SERVICE_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
USD_PER_TIB = 6.25  # BigQuery on-demand, an approximation: check current pricing before relying on it
MAX_SQL = 10_000


def _project() -> str:
    return os.environ["PROJECT_ID"]


def _region() -> str:
    return os.environ.get("REGION", "europe-west1")


def _service_row(svc) -> dict:
    image = svc.template.containers[0].image if svc.template.containers else ""
    return {
        "name": svc.name.rsplit("/", 1)[-1],
        "url": svc.uri,
        "latest_ready_revision": svc.latest_ready_revision.rsplit("/", 1)[-1]
        if svc.latest_ready_revision
        else "",
        "image_digest": image.split("@")[-1]
        if "@" in image
        else "(not pinned by digest)",
        "ingress": svc.ingress.name,
        "updated": svc.update_time.isoformat() if svc.update_time else "",
    }


def register(mcp: FastMCP) -> None:
    @mcp.tool()
    @guarded(SERVER, "ops:read")
    def list_cloud_run_services() -> dict:
        """List the Cloud Run services in the project's region: URL, ready revision, image digest, ingress."""
        from google.cloud import run_v2

        client = run_v2.ServicesClient()
        services = [
            _service_row(s)
            for s in client.list_services(
                parent=f"projects/{_project()}/locations/{_region()}"
            )
        ]
        return {"region": _region(), "count": len(services), "services": services}

    @mcp.tool()
    @guarded(SERVER, "ops:read")
    def recent_errors(service: str, minutes: int = 30, limit: int = 20) -> dict:
        """Recent ERROR-or-worse log entries of one Cloud Run service (newest first, text truncated)."""
        from google.cloud import logging as cloud_logging

        if not SERVICE_RE.match(service):
            raise ValueError(
                "service must be a Cloud Run service name (lowercase letters, digits, hyphens)"
            )
        if not 1 <= minutes <= 1440:
            raise ValueError("minutes must be between 1 and 1440")
        if not 1 <= limit <= 50:
            raise ValueError("limit must be between 1 and 50")
        since = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        flt = (
            'resource.type="cloud_run_revision" '
            f'AND resource.labels.service_name="{service}" AND severity>=ERROR AND timestamp>="{since}"'
        )
        client = cloud_logging.Client(project=_project())
        entries = []
        for e in client.list_entries(
            filter_=flt, order_by=cloud_logging.DESCENDING, max_results=limit
        ):
            payload = e.payload if isinstance(e.payload, str) else str(e.payload)
            entries.append(
                {
                    "time": e.timestamp.isoformat(),
                    "severity": e.severity,
                    "text": payload[:300],
                }
            )
        return {
            "service": service,
            "window_minutes": minutes,
            "count": len(entries),
            "entries": entries,
        }

    @mcp.tool()
    @guarded(SERVER, "ops:read")
    def estimate_bigquery_cost(sql: str) -> dict:
        """Dry-run a BigQuery SQL statement: bytes it would scan and an approximate on-demand cost. Nothing is executed."""
        from google.cloud import bigquery

        if len(sql) > MAX_SQL:
            raise ValueError(f"sql longer than {MAX_SQL} characters")
        client = bigquery.Client(project=_project())
        job = client.query(
            sql, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False)
        )
        scanned = job.total_bytes_processed or 0
        return {
            "bytes_processed": scanned,
            "gib_processed": round(scanned / 2**30, 3),
            "approx_usd_on_demand": round(scanned / 2**40 * USD_PER_TIB, 4),
            "note": "dry run only; first 1 TiB/month is free; pricing assumption in the server code",
        }
