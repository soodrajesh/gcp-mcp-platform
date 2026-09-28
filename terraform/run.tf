locals {
  services = {
    "mcp-ops"   = { server = "ops", sa = "mcp-ops-server" }
    "mcp-notes" = { server = "notes", sa = "mcp-notes-server" }
  }
  # One stable audience string per service, declared on the service as a custom audience below.
  audiences = { for name, _ in local.services : name => "https://${name}-${data.google_project.this.number}.${var.region}.run.app" }

  # The whole access policy, reviewed in a PR. mcp-guest and mcp-stranger are deliberately absent.
  # The human operator authenticates as a service account too (ADR 0005): a raw
  # `gcloud auth print-identity-token` user token is truncated in transit by Cloud Run's front
  # end before it reaches the app, so it cannot be relied on for MCP calls.
  callers = {
    (local.sa_email["mcp-operator"]) = ["ops:read", "notes:read", "notes:write"]
    (local.sa_email["mcp-agent"])    = ["ops:read", "notes:read"]
    (local.sa_email["mcp-burst"])    = ["ops:read"]
  }
}

resource "google_cloud_run_v2_service" "mcp" {
  for_each            = var.image == "" ? {} : local.services
  project             = var.project_id
  name                = each.key
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"
  # Tokens minted for this string are accepted by Cloud Run's own IAM check AND verified again by the
  # app. (A URL we merely construct is NOT accepted as an audience unless declared here.)
  custom_audiences = [local.audiences[each.key]]

  template {
    service_account = local.sa_email[each.value.sa]
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }
    containers {
      image = var.image
      env {
        name  = "SERVER"
        value = each.value.server
      }
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "REGION"
        value = var.region
      }
      env {
        name  = "FIRESTORE_DB"
        value = google_firestore_database.mcp.name
      }
      env {
        name  = "CALLERS_JSON"
        value = jsonencode(local.callers)
      }
      env {
        name = "ALLOWED_AUDIENCES"
        # the service's own audience, plus the gcloud CLI client id that every HUMAN token carries
        # (the app refuses that audience from service accounts; see app/mcpkit/auth.py)
        value = "${local.audiences[each.key]},32555940559.apps.googleusercontent.com"
      }
      env {
        name  = "RATE_LIMIT_PER_MIN"
        value = tostring(var.rate_limit_per_min)
      }
      resources {
        limits = { cpu = "1", memory = "512Mi" }
      }
    }
  }
  depends_on = [
    google_project_iam_member.ops_server,
    google_project_iam_member.firestore_users,
    google_project_iam_member.log_writer,
  ]
}
