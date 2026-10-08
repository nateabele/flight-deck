# `<region>-a` is not a zone everywhere (us-east1 has b, c and d), so a guessed default fails
# at create time in those regions. With no zone given, take the first UP zone by name: sorted,
# because the API's order is not a contract and a reordering must not move the machine.
data "google_compute_zones" "up" {
  count = var.zone == null ? 1 : 0

  region = var.region
  status = "UP"

  lifecycle {
    postcondition {
      condition     = length(self.names) > 0
      error_message = "${var.region} has no zone that is UP; set zone in [infra.<name>] vars, or pick another region."
    }
  }
}

locals {
  zone = var.zone != null ? var.zone : sort(data.google_compute_zones.up[0].names)[0]
  arch = coalesce(var.arch, can(regex("^(t2a|c4a|n4a|a4x)-", var.instance_type)) ? "arm64" : "x86_64")

  # The newest families boot only from Hyperdisk; the rest take pd-balanced (pd-standard, the
  # API default, is refused by G2 and most current families).
  disk_type = can(regex("^(c4|c4a|c4d|n4|n4a|n4d|m4|x4|a4|a4x)-", var.instance_type)) ? "hyperdisk-balanced" : "pd-balanced"

  # Firewall names, network tags and (per zone) instance names are project-global, so two
  # controllers or repos that each name a host `gpu` would collide on "fd-gpu". The base name
  # carries a short owner discriminator from fd_labels; both parts are sanitised to GCE's
  # [a-z0-9-], and the base is capped at 49 so the longest suffix (-deny-ingress) stays
  # within GCE's 63.
  owner = trim(substr(replace(lower(lookup(var.fd_labels, "flightdeck-owner", "")), "/[^a-z0-9-]+/", "-"), 0, 12), "-")
  host  = trim(replace(lower(var.fd_name), "/[^a-z0-9-]+/", "-"), "-")
  base  = trim(substr(join("-", compact(["fd", local.owner, local.host])), 0, 49), "-")

  # The network tag both firewall rules target; GCE firewall rules cannot select by label.
  tag = local.base

  # Firewalls cannot carry labels, so the orphan scan (spec §7.3) reads these from the
  # description instead.
  firewall_description = "flightdeck-owner=${lookup(var.fd_labels, "flightdeck-owner", "")} flightdeck-name=${var.fd_name}"
}

resource "google_compute_instance" "this" {
  name         = local.base
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

  # All three drift on their own: the image family moves to a newer image (and boot_disk's
  # image is force-new), Flight Deck re-renders fd_user_data on every `up`, and the first UP
  # zone moves when a zone goes down (zone is force-new). Without this, the spec §6.2 re-apply
  # that only moves fd_allow_cidr would replace a running machine, or rewrite its metadata
  # under it. They matter at creation only.
  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image, metadata["user-data"], zone]
  }
}

# Public mode only: hostd's port, from this Mac's /32 only (spec §6.2).
resource "google_compute_firewall" "hostd" {
  count = var.fd_allow_cidr == "" ? 0 : 1

  name          = "${local.base}-hostd"
  description   = local.firewall_description
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
  name          = "${local.base}-deny-ingress"
  description   = local.firewall_description
  network       = "default"
  direction     = "INGRESS"
  priority      = 1001
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.tag]

  deny {
    protocol = "all"
  }
}
