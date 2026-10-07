# `tofu test` for the gcp-linux preset (scripts/test-infra-presets.sh). mock_provider replaces
# the Google provider entirely, so these plans need no credentials and make no cloud call —
# every assertion is about what the module WOULD ask GCP for.

mock_provider "google" {}

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
}

# The default network's allow-ssh/rdp/icmp rules (priority 65534) must be outranked for this
# machine in both modes: "nothing else inbound (no SSH)", spec §6.2.
run "nothing_else_inbound" {
  command = plan

  assert {
    condition     = google_compute_firewall.deny_other_ingress.priority < 65534 && google_compute_firewall.deny_other_ingress.target_tags == toset(["fd-gpu"]) && google_compute_instance.this.tags == toset(["fd-gpu"])
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
