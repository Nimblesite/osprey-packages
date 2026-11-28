# Implements [PACKAGE-HOSTED-TOPOLOGY]. Per-environment values live in
# environments/<environment>.tfvars; nothing here is a secret.
variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Use an isolated staging or production environment."
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "australia-southeast1"
}

variable "cloudflare_account_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "api_hostname" {
  type = string
}

variable "website_hostname" {
  type = string
}

variable "content_hostname" {
  type = string
}

variable "image" {
  description = "Image digest Terraform creates the service with. CI deploys later digests; Terraform ignores them."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9.-]+/[^@]+@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Deploy an audited immutable Artifact Registry image digest, never a mutable tag."
  }
}

variable "max_instances" {
  description = "Cost ceiling, not a performance knob."
  type        = number
  default     = 2
  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 50 && floor(var.max_instances) == var.max_instances
    error_message = "Use an explicit integer instance cap between one and fifty."
  }
}

variable "supabase_project_ref" {
  type = string
  validation {
    condition     = can(regex("^[a-z]{20}$", var.supabase_project_ref))
    error_message = "Use the 20-letter Supabase project ref from the dashboard URL."
  }
}

variable "supabase_publishable_key" {
  description = "Public by design; it grants only what RLS allows."
  type        = string
}

variable "supabase_pooler_host" {
  description = "Dashboard → Connect → Transaction pooler host, e.g. aws-1-ap-southeast-2.pooler.supabase.com."
  type        = string
  validation {
    condition     = can(regex("^aws-[0-9]+-[a-z0-9-]+\\.pooler\\.supabase\\.com$", var.supabase_pooler_host))
    error_message = "Use the Supabase pooler hostname, not the IPv6-only direct db host."
  }
}

variable "github_repository" {
  type    = string
  default = "Nimblesite/osprey-packages"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the exact GitHub owner/repository identity."
  }
}

variable "github_repository_id" {
  description = "Stable numeric repository ID, not its reusable name."
  type        = string
  default     = "1474207568"
}

variable "github_owner_id" {
  description = "Stable numeric repository owner ID."
  type        = string
  default     = "178527684"
}

locals {
  management_port  = 8081
  public_hostnames = [var.website_hostname, var.api_hostname, var.content_hostname]
  hostname_pattern = "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$"
  name             = "osprey-registry-${var.environment}"
  # One Cloudflare zone hosts both environments; zone-wide singletons belong to production.
  zone_owner      = var.environment == "production"
  edge_hostnames  = { api = var.api_hostname, content = var.content_hostname }
  supabase_origin = "https://${var.supabase_project_ref}.supabase.co"
  required_services = toset([
    "artifactregistry.googleapis.com", "run.googleapis.com", "storage.googleapis.com", "cloudkms.googleapis.com",
    "secretmanager.googleapis.com", "iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com",
    "logging.googleapis.com", "monitoring.googleapis.com", "cloudresourcemanager.googleapis.com"
  ])
}
