# `tofu test` for the gcp-linux preset (scripts/test-infra-presets.sh). mock_provider replaces
# the Google provider entirely, so these plans need no credentials and make no cloud call —
# every assertion is about what the module WOULD ask GCP for.

mock_provider "google" {
  # The module picks the first UP zone when none is given; the mock's default is no zones.
  # Unsorted on purpose, and without `-a`: us-east1 really has no us-east1-a.
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-c", "us-central1-b", "us-central1-f"]
    }
  }
}

variables {
  fd_name      = "gpu"
  fd_user_data = "#cloud-config\n"
  fd_labels = {
    flightdeck       = "1"
    flightdeck-owner = "ctl"
    flightdeck-name  = "gpu"
  }
  project       = "example-project"
  region        = "us-central1"
  instance_type = "g2-standard-4"
  ttl_seconds   = 3600
}

run "ttl_is_enforced_by_the_cloud" {
  command = plan

  assert {
    condition     = google_compute_instance.this.scheduling[0].max_run_duration[0].seconds == 3600
    error_message = "max_run_duration"
  }
  assert {
    condition     = google_compute_instance.this.scheduling[0].instance_termination_action == "DELETE"
    error_message = "DELETE on TTL"
  }
  assert {
    condition     = google_compute_instance.this.labels["flightdeck"] == "1"
    error_message = "labels"
  }
  assert {
    condition     = google_compute_instance.this.metadata["user-data"] == "#cloud-config\n"
    error_message = "user-data"
  }
}

run "gpu_types_terminate_on_maintenance" {
  command = plan

  assert {
    condition     = google_compute_instance.this.scheduling[0].on_host_maintenance == "TERMINATE"
    error_message = "GPU needs TERMINATE"
  }
}

run "public_mode_firewall" {
  command = plan

  variables {
    fd_allow_cidr = "198.51.100.7/32"
  }

  assert {
    condition     = google_compute_firewall.hostd[0].source_ranges == toset(["198.51.100.7/32"])
    error_message = "only /32"
  }
  assert {
    condition     = google_compute_firewall.hostd[0].priority < google_compute_firewall.deny_other_ingress.priority
    error_message = "the hostd allow rule must outrank the deny-all rule"
  }
  # Firewalls carry no labels, so the orphan scan reads the owner and name from here.
  assert {
    condition     = strcontains(google_compute_firewall.hostd[0].description, "flightdeck-owner=ctl") && strcontains(google_compute_firewall.hostd[0].description, "flightdeck-name=gpu") && strcontains(google_compute_firewall.deny_other_ingress.description, "flightdeck-owner=ctl")
    error_message = "owner and name in each firewall's description"
  }
}

# The default network's allow-ssh/rdp/icmp rules (priority 65534) must be outranked for this
# machine in both modes: "nothing else inbound (no SSH)", spec §6.2.
run "nothing_else_inbound" {
  command = plan

  assert {
    condition     = google_compute_firewall.deny_other_ingress.priority < 65534 && google_compute_firewall.deny_other_ingress.target_tags == toset(["fd-ctl-gpu"]) && google_compute_instance.this.tags == toset(["fd-ctl-gpu"])
    error_message = "a deny-all ingress rule must outrank the default network's rules for this machine"
  }
  assert {
    condition     = length(google_compute_firewall.hostd) == 0
    error_message = "no allow rule in tailnet mode"
  }
  assert {
    condition     = google_compute_instance.this.boot_disk[0].initialize_params[0].labels["flightdeck-owner"] == "ctl"
    error_message = "labels on the boot disk"
  }
}

# Firewall names and network tags are project-global: two controllers (or repos) with a host
# called `gpu` must not collide, so names carry the sanitised owner.
run "names_carry_the_owner" {
  command = plan

  variables {
    fd_allow_cidr = "198.51.100.7/32"
    fd_labels = {
      flightdeck       = "1"
      flightdeck-owner = "Mac_Studio.7f3a9c2e4b1d"
      flightdeck-name  = "gpu"
    }
  }

  assert {
    condition     = google_compute_firewall.hostd[0].name != google_compute_firewall.deny_other_ingress.name && startswith(google_compute_firewall.hostd[0].name, "fd-mac-studio-7")
    error_message = "firewall names carry the sanitised owner"
  }
  assert {
    condition     = alltrue([for n in [google_compute_firewall.hostd[0].name, google_compute_firewall.deny_other_ingress.name, one(google_compute_instance.this.tags)] : length(n) <= 63 && can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", n))])
    error_message = "every global name is a valid GCE name of at most 63 characters"
  }
}

run "long_names_still_fit" {
  command = plan

  variables {
    fd_name       = "a-very-long-host-name-that-someone-typed-into-delegate-toml-x"
    fd_allow_cidr = "198.51.100.7/32"
  }

  assert {
    condition     = alltrue([for n in [google_compute_firewall.hostd[0].name, google_compute_firewall.deny_other_ingress.name, one(google_compute_instance.this.tags)] : length(n) <= 63 && can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", n))])
    error_message = "every global name is a valid GCE name of at most 63 characters"
  }
}

# `<region>-a` is not a zone everywhere (us-east1 has b, c and d), so with no zone given the
# module asks GCP for the region's UP zones and takes the first by name.
run "zone_defaults_to_an_up_zone" {
  command = plan

  variables {
    region = "us-east1"
  }

  override_data {
    target = data.google_compute_zones.up
    values = {
      names = ["us-east1-d", "us-east1-b", "us-east1-c"]
    }
  }

  assert {
    condition     = google_compute_instance.this.zone == "us-east1-b"
    error_message = "the first UP zone by name, not a guessed us-east1-a"
  }
  assert {
    condition     = data.google_compute_zones.up[0].region == "us-east1" && data.google_compute_zones.up[0].status == "UP"
    error_message = "only UP zones of the machine's region"
  }
}

run "zone_override_wins" {
  command = plan

  variables {
    zone = "us-central1-f"
  }

  assert {
    condition     = google_compute_instance.this.zone == "us-central1-f"
    error_message = "var.zone is used as given"
  }
  assert {
    condition     = length(data.google_compute_zones.up) == 0
    error_message = "no zone lookup (and no compute.zones.list call) when the zone is given"
  }
}

# A running machine must survive a re-apply (spec §6.2 re-applies when this Mac's public IP
# changes): a newer image in the family (boot_disk image is force-new) and re-rendered
# user-data must neither replace nor alter it. Switching arch is the test's stand-in for "the
# image moved": it changes the image string the same way.
#
# The mocks make `apply` free and local, but a mock provider cannot see replacement: force-new
# is the real provider's plan logic, not part of its schema. What is asserted instead is that
# the triggers never reach the instance — the state still holds what it booted with.
run "create" {
  command = apply
}

run "reapply_keeps_the_machine" {
  command = apply

  variables {
    arch          = "arm64"
    fd_user_data  = "#cloud-config\n# re-rendered\n"
    fd_allow_cidr = "198.51.100.8/32"
  }

  assert {
    condition     = google_compute_instance.this.boot_disk[0].initialize_params[0].image == "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
    error_message = "a newer image must not reach (and so replace) the running instance"
  }
  assert {
    condition     = google_compute_instance.this.metadata["user-data"] == "#cloud-config\n"
    error_message = "re-rendered user-data must not alter the running instance"
  }
  assert {
    condition     = google_compute_firewall.hostd[0].source_ranges == toset(["198.51.100.8/32"])
    error_message = "the re-apply must still move the firewall to the new /32"
  }
}

# A zone that goes DOWN after launch moves the first UP zone, and zone is force-new: the
# spec §6.2 re-apply must not chase it and replace the machine `create` made above.
run "reapply_keeps_the_zone" {
  command = apply

  override_data {
    target = data.google_compute_zones.up
    values = {
      names = ["us-central1-f"]
    }
  }

  assert {
    condition     = google_compute_instance.this.zone == "us-central1-b"
    error_message = "a moved zone list must not reach (and so replace) the running instance"
  }
}
