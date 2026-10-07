# Bundled preset `aws-linux` (spec §5.3). Flight Deck copies this folder into
# `infra/<name>/module/` and runs it as the root module, so the provider is configured here.
# The provider version is pinned twice: the constraint below, and the exact build in
# .terraform.lock.hcl, so every Mac's `tofu init` fetches the same, hash-verified provider.

terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region
}
