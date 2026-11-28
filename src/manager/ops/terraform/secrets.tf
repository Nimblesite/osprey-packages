# Implements [PACKAGE-HOSTED-RELEASE], [PACKAGE-HOSTED-EDGE], [PACKAGE-OWNERSHIP-RLS].
# Terraform generates every credential it can, so the only operator-held secrets are
# the Supabase database owner password and the Cloudflare API tokens. State lives in
# a private, versioned GCS bucket; treat read access to it as secret access.
resource "random_password" "edge_secret" {
  length  = 64
  special = false
}

# One restricted login per database service the API mounts [PACKAGE-OWNERSHIP-RLS].
locals {
  api_database_logins = {
    catalog         = "registry_catalog_reader"
    login           = "registry_login_runtime"
    session-issuer  = "registry_session_issuer"
    session-runtime = "registry_session_runtime"
    session-revoker = "registry_session_revoker"
    catalog-writer  = "registry_catalog_writer"
  }
  # Transaction pooler: one short transaction per psql run; Supavisor names users <role>.<ref>.
  publication_logins = { collector = "registry_publication_collector", scan = "registry_scan_worker" }
  database_logins    = merge(local.api_database_logins, local.publication_logins)
  service_entries = { for service, role in local.database_logins : service => <<-EOT
    [${service}]
    host=${var.supabase_pooler_host}
    port=6543
    dbname=postgres
    user=${role}.${var.supabase_project_ref}
    password=${random_password.database[service].result}
    EOT
  }
  pg_service = join("\n", [for service in keys(local.api_database_logins) : local.service_entries[service]])
  runtime_config = jsonencode({
    apiHost                = var.api_hostname
    websiteOrigin          = "https://${var.website_hostname}"
    contentHost            = var.content_hostname
    edgeSecret             = random_password.edge_secret.result
    supabaseOrigin         = local.supabase_origin
    supabasePublishableKey = var.supabase_publishable_key
    loginKmsKey            = google_kms_crypto_key.sealing["login"].id
    sessionKmsKey          = google_kms_crypto_key.sealing["session"].id
  })
  # Name → mount path, file name, payload. The API reads these exact paths.
  secret_files = {
    runtime-config  = { mount = "/run/registry", file = "runtime.json", data = local.runtime_config }
    catalog-service = { mount = "/run/catalog-service", file = "pg_service.conf", data = local.pg_service }
    catalog-ca      = { mount = "/run/catalog-ca", file = "ca.pem", data = file("${path.module}/../supabase/supabase-root-2021.crt") }
  }
  mounted_secrets = { for key, value in local.secret_files : key => merge(value, {
    secret  = google_secret_manager_secret.mounted[key]
    version = google_secret_manager_secret_version.mounted[key]
  }) }
}

resource "random_password" "database" {
  for_each = local.database_logins
  length   = 48
  special  = false
}

resource "google_secret_manager_secret" "mounted" {
  for_each  = local.secret_files
  secret_id = "${local.name}-${each.key}"
  replication {
    auto {}
  }
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "mounted" {
  for_each    = local.secret_files
  secret      = google_secret_manager_secret.mounted[each.key].id
  secret_data = each.value.data
}

resource "google_secret_manager_secret_iam_member" "mounted" {
  for_each  = google_secret_manager_secret.mounted
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}
