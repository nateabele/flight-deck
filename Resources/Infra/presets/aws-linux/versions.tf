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

  # Belt and braces for "every resource carries fd_labels" (spec §5.3): anything taggable this
  # module creates gets them even where a resource forgets to say so. The resource-level tags
  # stay, because they are what the tests can see (a mock provider never computes tags_all),
  # and default_tags does not reach the ENI or spot request (see aws_ec2_tag in main.tf).
  default_tags {
    tags = var.fd_labels
  }
}
