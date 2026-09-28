output "artifact_repo" { value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}" }
output "build_bucket" { value = google_storage_bucket.build.name }
output "build_sa" { value = local.sa_email["mcp-build"] }
output "firestore_db" { value = google_firestore_database.mcp.name }
output "audit_dataset" { value = google_bigquery_dataset.audit.dataset_id }
output "ops_url" { value = var.image == "" ? "" : google_cloud_run_v2_service.mcp["mcp-ops"].uri }
output "notes_url" { value = var.image == "" ? "" : google_cloud_run_v2_service.mcp["mcp-notes"].uri }
output "ops_audience" { value = local.audiences["mcp-ops"] }
output "notes_audience" { value = local.audiences["mcp-notes"] }
