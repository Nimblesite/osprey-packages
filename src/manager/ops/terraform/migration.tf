# [PACKAGE-HOSTED-RELEASE] The migration build uses its own identity and private source bucket.
resource "google_service_account" "migration" {
  account_id   = "registry-${var.environment}-migrate"
  display_name = "Registry database migration"
  depends_on   = [google_project_service.required]
}

resource "google_storage_bucket" "migration_source" {
  name                        = "${var.project_id}-registry-migrations"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  depends_on                  = [google_project_service.required]
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 1
    }
  }
}

resource "google_storage_bucket_iam_member" "migration_source" {
  bucket = google_storage_bucket.migration_source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.migration.email}"
}

resource "google_project_iam_member" "migration_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.migration.email}"
}

resource "google_secret_manager_secret_iam_member" "migration_owner" {
  secret_id = "${local.name}-db-owner"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.migration.email}"
}

output "migration_build" {
  value = { account = google_service_account.migration.name, bucket = google_storage_bucket.migration_source.name }
}
