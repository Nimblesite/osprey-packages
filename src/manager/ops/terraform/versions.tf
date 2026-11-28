terraform {
  required_version = ">= 1.5.7, < 2.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.24.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
  backend "gcs" {}
}

# Budgets bill against the project's quota, not the caller's ADC project.
provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

# Reads CLOUDFLARE_API_TOKEN from the environment.
provider "cloudflare" {}
