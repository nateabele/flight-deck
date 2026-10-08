# The module contract (spec §5.3): the fd_* inputs come from Flight Deck, the rest from the
# `[infra.<name>]` table in the repo's delegate.toml.

variable "fd_name" {
  description = "The host's Flight Deck name; prefixes every resource name."
  type        = string
}

variable "fd_user_data" {
  description = "cloud-init user-data rendered by Flight Deck (enrollment, hostd, TTL timer)."
  type        = string
  sensitive   = true
}

variable "fd_labels" {
  description = "Tags every resource carries; the orphan check and budget scope find machines by them."
  type        = map(string)
}

variable "fd_allow_cidr" {
  description = "Public mode: this Mac's /32, the only source admitted to hostd. Empty = tailnet mode, no inbound rule at all."
  type        = string
  default     = ""
}

variable "region" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "arch" {
  description = "\"x86_64\" or \"arm64\". Null derives it from the instance type (Graviton families carry a `g` after the generation, e.g. m7g, c7gn, t4g, plus a1)."
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
  description = "The machine's lifetime. AWS has no cloud-side TTL, so this preset only enforces the shutdown half: cloud-init (in fd_user_data) arms a poweroff timer at the deadline, and instance_initiated_shutdown_behavior turns that shutdown into termination."
  type        = number

  validation {
    condition     = var.ttl_seconds > 0
    error_message = "ttl_seconds must be positive: a machine without a TTL is exactly what the presets exist to prevent."
  }
}
