# Implements [PACKAGE-HOSTED-RELEASE]. Provider federation is restricted to the
# stable repository/owner IDs and the GitHub environment approval boundary.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "registry-${var.environment}"
  display_name              = "Registry ${var.environment} deploys"
  depends_on                = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
  }
  attribute_condition = "assertion.repository_id == '${var.github_repository_id}' && assertion.repository_owner_id == '${var.github_owner_id}' && assertion.repository == '${var.github_repository}' && assertion.sub == 'repo:${var.github_repository}:environment:registry-${var.environment}'${var.environment == "production" ? " && assertion.ref == 'refs/heads/main'" : ""}"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "federated_deploy" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/${var.github_repository_id}"
}

resource "google_cloud_run_v2_service_iam_member" "deploy" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_service_account_iam_member" "deploy_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_artifact_registry_repository_iam_member" "deploy" {
  location   = var.region
  repository = google_artifact_registry_repository.registry.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_service_account" "deploy" {
  account_id   = "registry-${var.environment}-deploy"
  display_name = "Registry exact-SHA deployment identity"
  depends_on   = [google_project_service.required]
}

# Consumed by scripts/deploy (GitHub environment variables, database logins).
output "github_environment" {
  value = {
    GCP_PROJECT_ID          = var.project_id
    GCP_REGION              = var.region
    GCP_WORKLOAD_IDENTITY   = google_iam_workload_identity_pool_provider.github.name
    GCP_DEPLOY_SA           = google_service_account.deploy.email
    REGISTRY_IMAGE_REPO     = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.registry.repository_id}"
    REGISTRY_SERVICE        = local.name
    REGISTRY_API_ORIGIN     = "https://${var.api_hostname}"
    REGISTRY_CONTENT_ORIGIN = "https://${var.content_hostname}"
    PAGES_PROJECT           = cloudflare_pages_project.website.name
    CLOUDFLARE_ACCOUNT_ID   = var.cloudflare_account_id
  }
}

output "pages_token" {
  value     = cloudflare_account_token.pages.value
  sensitive = true
}

output "run_host" {
  value = local.run_host
}

output "database_logins" {
  value     = { for service, role in local.database_logins : role => random_password.database[service].result }
  sensitive = true
}
