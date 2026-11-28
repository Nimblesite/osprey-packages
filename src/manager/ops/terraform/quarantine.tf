# [PACKAGE-SECURITY-SCAN] The collector may add objects; the scanner verifies their frozen bytes.
resource "google_storage_bucket" "quarantine" {
  name                        = "${var.project_id}-${local.name}-quarantine"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  depends_on                  = [google_project_service.required]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "publication" {
  for_each     = toset(["collector", "scanner"])
  account_id   = "registry-${var.environment}-${each.key}"
  display_name = "Registry publication ${each.key}"
  depends_on   = [google_project_service.required]
}

resource "google_storage_bucket_iam_member" "quarantine" {
  for_each = { collector = "roles/storage.objectCreator", scanner = "roles/storage.objectViewer" }
  bucket   = google_storage_bucket.quarantine.name
  role     = each.value
  member   = "serviceAccount:${google_service_account.publication[each.key].email}"
}

# The agent configuration (including its API key) is supplied directly in Secret Manager.
# The listener cannot mount either scanner secret.
resource "google_secret_manager_secret" "scanner" {
  for_each  = toset(["scan-db", "scan-agent"])
  secret_id = "${local.name}-${each.key}"
  replication {
    auto {}
  }
  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "scanner_db" {
  secret      = google_secret_manager_secret.scanner["scan-db"].id
  secret_data = local.service_entries["scan"]
}

locals {
  scan_mounts = {
    database = { dir = "/run/registry-scan-db", file = "pg_service.conf", secret = google_secret_manager_secret.scanner["scan-db"].secret_id, version = google_secret_manager_secret_version.scanner_db.version }
    agent    = { dir = "/run/registry-scan", file = "agent.json", secret = google_secret_manager_secret.scanner["scan-agent"].secret_id, version = var.scan_agent_secret_version }
    ca       = { dir = "/run/catalog-ca", file = "ca.pem", secret = google_secret_manager_secret.mounted["catalog-ca"].secret_id, version = google_secret_manager_secret_version.mounted["catalog-ca"].version }
  }
}

resource "google_secret_manager_secret_iam_member" "scanner" {
  for_each  = local.scan_mounts
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.publication["scanner"].email}"
}

variable "scan_agent_secret_version" {
  type        = string
  description = "Numeric Secret Manager version for the provisioned tool-free agent. Empty keeps the scan job inactive."
  default     = ""
  validation {
    condition     = var.scan_agent_secret_version == "" || can(regex("^[1-9][0-9]*$", var.scan_agent_secret_version))
    error_message = "Pin a numeric secret version or leave it empty."
  }
}

resource "google_cloud_run_v2_job" "scan" {
  count               = var.scan_agent_secret_version == "" ? 0 : 1
  name                = "${local.name}-scan"
  location            = var.region
  deletion_protection = false
  template {
    task_count  = 1
    parallelism = 1
    template {
      service_account = google_service_account.publication["scanner"].email
      max_retries     = 0
      timeout         = "280s"
      containers {
        image   = var.image
        command = ["/usr/local/bin/registry-scan-once"]
        resources {
          limits = { cpu = "1", memory = "1Gi" }
        }
        dynamic "volume_mounts" {
          for_each = local.scan_mounts
          content {
            name       = volume_mounts.key
            mount_path = volume_mounts.value.dir
          }
        }
        volume_mounts {
          name       = "quarantine"
          mount_path = "/run/registry-quarantine"
        }
      }
      dynamic "volumes" {
        for_each = local.scan_mounts
        content {
          name = volumes.key
          secret {
            secret = volumes.value.secret
            items {
              version = volumes.value.version
              path    = volumes.value.file
              mode    = 292
            }
          }
        }
      }
      volumes {
        name = "quarantine"
        gcs {
          bucket    = google_storage_bucket.quarantine.name
          read_only = true
        }
      }
    }
  }
  lifecycle {
    precondition {
      condition     = startswith(var.image, "${var.region}-docker.pkg.dev/${var.project_id}/${local.name}/")
      error_message = "Select the registry image built for this environment."
    }
  }
  depends_on = [google_secret_manager_secret_iam_member.scanner, google_storage_bucket_iam_member.quarantine]
}

resource "google_cloud_run_v2_job_iam_member" "collect_and_scan" {
  count    = length(google_cloud_run_v2_job.scan)
  location = var.region
  name     = google_cloud_run_v2_job.scan[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.publication["collector"].email}"
}
