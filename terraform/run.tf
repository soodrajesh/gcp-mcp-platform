locals {
  services = {
    "mcp-ops"   = { server = "ops", sa = "mcp-ops-server" }
    "mcp-notes" = { server = "notes", sa = "mcp-notes-server" }
  }
  # Cloud Run issues identity-token audiences of the form https://<service>-<project number>.<region>.run.app
  audiences = { for name, _ in local.services : name => "https://${name}-${data.google_project.this.number}.${var.region}.run.app" }

  # The whole access policy, reviewed in a PR. mcp-guest and mcp-stranger are deliberately absent.
  callers = {
    (lower(var.admin_email))      = ["ops:read", "notes:read", "notes:write"]
    (local.sa_email["mcp-agent"]) = ["ops:read", "notes:read"]
    (local.sa_email["mcp-burst"]) = ["ops:read"]
  }
}

resource "google_cloud_run_v2_service" "mcp" {
  for_each            = var.image == "" ? {} : local.services
  project             = var.project_id
  name                = each.key
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"

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
        name  = "ALLOWED_AUDIENCES"
        value = local.audiences[each.key]
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
