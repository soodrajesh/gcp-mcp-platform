# Two kinds of service accounts. SERVERS run the MCP services and hold only what their tools need.
# CLIENTS exist to be callers: they stand in for agents and let the live tests exercise every
# layer of the access model (none of them has a key; the operator impersonates them).
locals {
  server_sas = {
    "mcp-ops-server"   = "Runs the gcp-ops MCP server (read-only project tools)"
    "mcp-notes-server" = "Runs the notes MCP server (Firestore)"
    "mcp-build"        = "Cloud Build: builds and pushes the image"
  }
  client_sas = {
    "mcp-agent"    = "Registered caller: ops:read + notes:read (cannot write notes)"
    "mcp-burst"    = "Registered caller: ops:read only; used to trip the rate limit"
    "mcp-guest"    = "Has run.invoker but is NOT registered in the caller policy"
    "mcp-stranger" = "Has no run.invoker at all"
  }
}

resource "google_service_account" "sa" {
  for_each     = merge(local.server_sas, local.client_sas)
  project      = var.project_id
  account_id   = each.key
  display_name = each.value
  depends_on   = [google_project_service.apis]
}

locals {
  sa_email = { for k, v in google_service_account.sa : k => v.email }
}

# ── server permissions ──
resource "google_project_iam_member" "ops_server" {
  for_each = toset(["roles/run.viewer", "roles/logging.viewer", "roles/bigquery.jobUser"])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${local.sa_email["mcp-ops-server"]}"
}

# Firestore has no resource-level role for a database id short of IAM Conditions; both servers
# need it (notes: the data, ops: the shared rate-limit counters).
resource "google_project_iam_member" "firestore_users" {
  for_each = toset(["mcp-ops-server", "mcp-notes-server"])
  project  = var.project_id
  role     = "roles/datastore.user"
  member   = "serviceAccount:${local.sa_email[each.key]}"
}

resource "google_project_iam_member" "log_writer" {
  for_each = toset(["mcp-ops-server", "mcp-notes-server", "mcp-build"])
  project  = var.project_id
  role     = "roles/logging.logWriter"
  member   = "serviceAccount:${local.sa_email[each.key]}"
}

# ── who can reach the services (Cloud Run IAM: the first layer) ──
locals {
  invokers = toset([
    "user:${var.admin_email}",
    "serviceAccount:${local.sa_email["mcp-agent"]}",
    "serviceAccount:${local.sa_email["mcp-burst"]}",
    "serviceAccount:${local.sa_email["mcp-guest"]}",
  ])
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = var.image == "" ? {} : { for pair in setproduct(keys(local.services), local.invokers) : "${pair[0]}|${pair[1]}" => pair }
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.mcp[each.value[0]].name
  role     = "roles/run.invoker"
  member   = each.value[1]
}

# the operator mints identity tokens AS the client service accounts to test the layers
resource "google_service_account_iam_member" "operator_impersonates_clients" {
  for_each           = local.client_sas
  service_account_id = google_service_account.sa[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.admin_email}"
}

# ── build ──
resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "mcp"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

resource "google_storage_bucket" "build" {
  project                     = var.project_id
  name                        = "${var.project_id}-mcp-build"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  versioning {
    enabled = true
  }
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "build_push" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.sa_email["mcp-build"]}"
}

resource "google_storage_bucket_iam_member" "build_src" {
  bucket = google_storage_bucket.build.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.sa_email["mcp-build"]}"
}

# operator: read the audit dataset in the live tests
resource "google_bigquery_dataset_iam_member" "operator_audit_viewer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.audit.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "user:${var.admin_email}"
}
