# Every allow/deny decision is one structured log line; this sink lands them in BigQuery
# (partitioned by day) so "who called what, and what was refused" is a SQL query.
resource "google_bigquery_dataset" "audit" {
  project                    = var.project_id
  dataset_id                 = "mcp_audit"
  location                   = var.region
  delete_contents_on_destroy = true
  depends_on                 = [google_project_service.apis]
}

resource "google_logging_project_sink" "audit" {
  project                = var.project_id
  name                   = "mcp-audit-to-bigquery"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.audit.dataset_id}"
  filter                 = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"mcp_call\""
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "sink_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.audit.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.audit.writer_identity
}

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "MCP platform alerts"
  type         = "email"
  labels       = { email_address = var.alert_email }
  depends_on   = [google_project_service.apis]
}

resource "google_logging_metric" "denied" {
  project     = var.project_id
  name        = "mcp_denied_calls"
  description = "MCP requests refused (unauthenticated, unregistered, rate limited, missing scope)."
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"mcp_call\" AND jsonPayload.decision=\"denied\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "denied_burst" {
  project      = var.project_id
  display_name = "MCP: burst of refused calls"
  combiner     = "OR"
  conditions {
    display_name = "more than 25 refused calls in 5 minutes"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.denied.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 25
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "Many MCP calls were refused in a short window: a misconfigured client, a token probe, or an agent in a loop. Query mcp_audit.run_googleapis_com_stdout grouped by caller and reason. Runbook: docs/runbooks/03-investigate-denials.md"
    mime_type = "text/markdown"
  }
}
