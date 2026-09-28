resource "google_firestore_database" "mcp" {
  project                     = var.project_id
  name                        = "mcp-${var.suffix}"
  location_id                 = var.region
  type                        = "FIRESTORE_NATIVE"
  delete_protection_state     = "DELETE_PROTECTION_DISABLED"
  deletion_policy             = "DELETE"
  app_engine_integration_mode = "DISABLED"
  depends_on                  = [google_project_service.apis]
}

# Old rate-limit windows delete themselves.
resource "google_firestore_field" "ratelimit_ttl" {
  project    = var.project_id
  database   = google_firestore_database.mcp.name
  collection = "ratelimit"
  field      = "expire_at"
  ttl_config {}
  index_config {}
}
