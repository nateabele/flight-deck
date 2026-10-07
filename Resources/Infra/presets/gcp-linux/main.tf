locals {
  zone = coalesce(var.zone, "${var.region}-a")
  arch = coalesce(var.arch, can(regex("^(t2a|c4a|n4a|a4x)-", var.instance_type)) ? "arm64" : "x86_64")

  # The newest families boot only from Hyperdisk; the rest take pd-balanced (pd-standard, the
  # API default, is refused by G2 and most current families).
  disk_type = can(regex("^(c4|c4a|c4d|n4|n4a|n4d|m4|x4|a4|a4x)-", var.instance_type)) ? "hyperdisk-balanced" : "pd-balanced"

  # The network tag both firewall rules target; GCE firewall rules cannot select by label.
  tag = "fd-${var.fd_name}"
}

resource "google_compute_instance" "this" {
  name         = "fd-${var.fd_name}"
  machine_type = var.instance_type
  zone         = local.zone
  tags         = [local.tag]
  labels       = var.fd_labels

  # Canonical's Ubuntu 24.04 — the distro hostd-install.sh is tested against.
  boot_disk {
    auto_delete = true
    initialize_params {
      image  = "ubuntu-os-cloud/ubuntu-2404-lts-${local.arch == "arm64" ? "arm64" : "amd64"}"
      size   = var.disk_gb
      type   = local.disk_type
      labels = var.fd_labels
    }
  }

  network_interface {
    network = "default"

    # An external address in both modes: without Cloud NAT it is the only way out, and
    # cloud-init must download hostd. Tailnet mode stays closed by the deny rule below.
    access_config {}
  }

  # Ubuntu's cloud-init reads `user-data` from instance metadata. GCE metadata already demands
  # the Metadata-Flavor header (spec §5.2), so there is no IMDS setting to harden here.
  metadata = {
    user-data = var.fd_user_data
  }

  # The cloud half of "nothing outlives its TTL" (spec §7.2): GCE deletes the instance (and
  # its auto_delete boot disk) at max_run_duration, whether or not this Mac is awake.
  # TERMINATE on maintenance is what GPU types require; automatic_restart = false is what
  # TERMINATE and spot both require.
  scheduling {
    provisioning_model          = var.spot ? "SPOT" : "STANDARD"
    preemptible                 = var.spot
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = "DELETE"

    max_run_duration {
      seconds = var.ttl_seconds
    }
  }

  shielded_instance_config {
    enable_secure_boot = true
  }
}

# Public mode only: hostd's port, from this Mac's /32 only (spec §6.2).
resource "google_compute_firewall" "hostd" {
  count = var.fd_allow_cidr == "" ? 0 : 1

  name          = "fd-${var.fd_name}-hostd"
  network       = "default"
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = [var.fd_allow_cidr]
  target_tags   = [local.tag]

  allow {
    protocol = "tcp"
    ports    = ["47410"]
  }
}

# The auto-created default network ships `default-allow-ssh` (and RDP, ICMP) open to
# 0.0.0.0/0 for every instance at priority 65534. This rule outranks them for this machine
# only, so the hostd rule above is the sole inbound path in public mode and there is none in
# tailnet mode ("nothing else inbound (no SSH)", spec §6.2). Replies to outbound traffic,
# Tailscale's included, are unaffected: GCE firewalls are stateful.
resource "google_compute_firewall" "deny_other_ingress" {
  name          = "fd-${var.fd_name}-deny-ingress"
  network       = "default"
  direction     = "INGRESS"
  priority      = 1001
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.tag]

  deny {
    protocol = "all"
  }
}
