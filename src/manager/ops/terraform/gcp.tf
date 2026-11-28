# Implements [PACKAGE-HOSTED-TOPOLOGY], [PACKAGE-HOSTED-EDGE].
resource "google_project_service" "required" {
  for_each           = local.required_services
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "this" {}

resource "google_artifact_registry_repository" "registry" {
  location      = var.region
  repository_id = local.name
  format        = "DOCKER"
  depends_on    = [google_project_service.required]

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }
}

resource "google_service_account" "runtime" {
  account_id   = "registry-${var.environment}-runtime"
  display_name = "Registry runtime; no deployment or migration authority"
  depends_on   = [google_project_service.required]
}

resource "google_service_account" "incident" {
  account_id   = "registry-${var.environment}-incident"
  display_name = "Registry independent incident job; grant DB deny-only credentials separately"
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_member" "runtime_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Separate keys: pending-login verifiers and browser-session provider tokens [PACKAGE-HOSTED-AUTH].
resource "google_kms_key_ring" "registry" {
  name       = local.name
  location   = var.region
  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "sealing" {
  for_each        = toset(["login", "session"])
  name            = each.value
  key_ring        = google_kms_key_ring.registry.id
  rotation_period = "7776000s"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "sealing" {
  for_each      = google_kms_crypto_key.sealing
  crypto_key_id = each.value.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.runtime.email}"
}

# Published source bundles: private, uniform access, no public reads [PACKAGE-HOSTED-PUBLISH].
resource "google_storage_bucket" "published_source" {
  name                        = "${var.project_id}-${local.name}-source"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  depends_on                  = [google_project_service.required]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "published_source" {
  bucket = google_storage_bucket.published_source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_cloud_run_v2_service" "api" {
  name                = local.name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = true
  lifecycle {
    # CI deploys new digests with `gcloud run services update`; Terraform owns everything else.
    ignore_changes = [template[0].containers[0].image, client, client_version]
    precondition {
      condition     = length(distinct(local.public_hostnames)) == 3 && alltrue([for host in local.public_hostnames : length(host) <= 253 && can(regex(local.hostname_pattern, host))])
      error_message = "Supply distinct valid hostnames for the API, website and cookieless content origin."
    }
    precondition {
      condition     = startswith(var.image, "${var.region}-docker.pkg.dev/${var.project_id}/${local.name}/")
      error_message = "Select an immutable image from this environment's Artifact Registry repository."
    }
  }
  template {
    service_account                  = google_service_account.runtime.email
    timeout                          = "30s"
    max_instance_request_concurrency = 16
    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances
    }
    containers {
      image = var.image
      ports {
        container_port = 8080
      }
      resources {
        limits            = { cpu = "1", memory = "512Mi" }
        cpu_idle          = true
        startup_cpu_boost = false
      }
      dynamic "volume_mounts" {
        for_each = local.mounted_secrets
        content {
          name       = volume_mounts.key
          mount_path = volume_mounts.value.mount
        }
      }
      volume_mounts {
        name       = "published-source"
        mount_path = "/run/registry-source"
      }
      startup_probe {
        http_get {
          path = "/v1/ready"
          port = local.management_port
        }
        period_seconds    = 5
        failure_threshold = 12
        timeout_seconds   = 2
      }
      liveness_probe {
        http_get {
          path = "/v1/ready"
          port = local.management_port
        }
        period_seconds    = 30
        failure_threshold = 3
        timeout_seconds   = 2
      }
    }
    dynamic "volumes" {
      for_each = local.mounted_secrets
      content {
        name = volumes.key
        secret {
          secret = volumes.value.secret.secret_id
          items {
            version = volumes.value.version.version
            path    = volumes.value.file
            mode    = 292
          }
        }
      }
    }
    volumes {
      name = "published-source"
      gcs {
        bucket    = google_storage_bucket.published_source.name
        read_only = true
      }
    }
  }
  depends_on = [google_secret_manager_secret_iam_member.mounted, google_storage_bucket_iam_member.published_source, google_kms_crypto_key_iam_member.sealing]
}

# Public invocation is intended: the Worker reaches the default run.app URL, and the API
# 403s every request without the edge secret before routing [PACKAGE-HOSTED-EDGE].
resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
