# The module contract (spec §5.3): the fd_* inputs come from Flight Deck, the rest from the
# `[infra.<name>]` table in the repo's delegate.toml.

variable "fd_name" {
  description = "The host's Flight Deck name; prefixes every resource name."
  type        = string
}

variable "fd_user_data" {
  description = "cloud-init user-data rendered by Flight Deck (enrollment, hostd; no TTL timer on GCP, max_run_duration is the TTL)."
  type        = string
  sensitive   = true
}

variable "fd_labels" {
  description = "Labels every resource carries; the orphan check and budget scope find machines by them."
  type        = map(string)
}

variable "fd_allow_cidr" {
  description = "Public mode: this Mac's /32, the only source admitted to hostd. Empty = tailnet mode, no allow rule at all."
  type        = string
  default     = ""
}

variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  description = "Null means \"<region>-a\"."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "A GCE machine type. GPU types (g2, a2, a3) carry their GPUs, so there is no accelerator input."
  type        = string
}

variable "arch" {
  description = "\"x86_64\" or \"arm64\". Null derives it from the machine family (Axion/Ampere: t2a, c4a, n4a, a4x)."
  type        = string
  default     = null

  validation {
    condition     = contains(["x86_64", "arm64"], coalesce(var.arch, "x86_64"))
    error_message = "arch must be \"x86_64\" or \"arm64\"."
  }
}

variable "disk_gb" {
  type    = number
  default = 50
}

variable "spot" {
  type    = bool
  default = false
}

variable "ttl_seconds" {
  description = "The machine's lifetime, enforced by GCE itself via scheduling.max_run_duration."
  type        = number

  validation {
    condition     = var.ttl_seconds > 0
    error_message = "ttl_seconds must be positive: a machine without a TTL is exactly what the presets exist to prevent."
  }
}
