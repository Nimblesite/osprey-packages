# Implements [PACKAGE-HOSTED-TOPOLOGY], [PACKAGE-HOSTED-EDGE].
# Cloudflare → Worker → Cloud Run run.app URL. No GCP load balancer: the Worker sets
# Host for Cloud Run and the API's edge-secret gate refuses direct origin hits.
locals {
  run_host = trimprefix(google_cloud_run_v2_service.api.uri, "https://")
}

resource "cloudflare_workers_script" "edge" {
  account_id         = var.cloudflare_account_id
  script_name        = local.name
  main_module        = "edge.js"
  content            = file("${path.module}/../cloudflare/edge.js")
  compatibility_date = "2025-09-01"
  bindings = [
    { type = "plain_text", name = "RUN_HOST", text = local.run_host },
    { type = "plain_text", name = "WEBSITE_ALIAS", text = local.website_alias },
    { type = "plain_text", name = "WEBSITE_ORIGIN", text = "https://${var.website_hostname}" },
    { type = "secret_text", name = "EDGE_SECRET", text = random_password.edge_secret.result },
    # Per-IP, per-location: 50 requests per 10 s. Namespace IDs are account-unique integers.
    { type = "ratelimit", name = "LIMITER", namespace_id = var.environment == "production" ? "7701" : "7702", simple = { limit = 50, period = 10 } },
  ]
}

# Worker-only hostnames: the proxied record never reaches an origin (100:: is discard).
resource "cloudflare_dns_record" "edge" {
  for_each = local.edge_hostnames
  zone_id  = var.cloudflare_zone_id
  name     = each.value
  type     = "AAAA"
  content  = "100::"
  proxied  = true
  ttl      = 1
}

resource "cloudflare_workers_route" "edge" {
  for_each   = local.edge_hostnames
  zone_id    = var.cloudflare_zone_id
  pattern    = "${each.value}/*"
  script     = cloudflare_workers_script.edge.script_name
  depends_on = [cloudflare_dns_record.edge]
}

# Prebuilt WASM website, Direct Upload only; CI deploys the archived artifact.
resource "cloudflare_pages_project" "website" {
  account_id        = var.cloudflare_account_id
  name              = local.name
  production_branch = "main"
}

# CI's Pages Direct Upload credential: minted here, scoped to Pages on this account only.
data "cloudflare_account_api_token_permission_groups_list" "pages_write" {
  account_id = var.cloudflare_account_id
  name       = "Pages Write"
}

resource "cloudflare_account_token" "pages" {
  account_id = var.cloudflare_account_id
  name       = "${local.name}-pages"
  policies = [{
    effect            = "allow"
    permission_groups = [{ id = one(data.cloudflare_account_api_token_permission_groups_list.pages_write.result).id }]
    resources         = jsonencode({ "com.cloudflare.api.account.${var.cloudflare_account_id}" = "*" })
  }]
}

resource "cloudflare_dns_record" "website" {
  zone_id = var.cloudflare_zone_id
  name    = var.website_hostname
  type    = "CNAME"
  content = cloudflare_pages_project.website.subdomain
  proxied = true
  ttl     = 1
}

resource "cloudflare_pages_domain" "website" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.website.name
  name         = var.website_hostname
  depends_on   = [cloudflare_dns_record.website]
}
