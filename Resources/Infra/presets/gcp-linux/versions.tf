# Bundled preset `gcp-linux` (spec §5.3). Flight Deck copies this folder into
# `infra/<name>/module/` and runs it as the root module, so the provider is configured here.
# The provider version is pinned twice: the constraint below, and the exact build in
# .terraform.lock.hcl, so every Mac's `tofu init` fetches the same, hash-verified provider.

terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region

  # Belt and braces for "every resource carries fd_labels" (spec §5.3): anything labelable this
  # module creates gets them even where a resource below forgets to say so.
  default_labels = var.fd_labels
}
