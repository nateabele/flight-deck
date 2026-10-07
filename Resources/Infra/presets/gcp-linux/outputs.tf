# The module contract's outputs (spec §5.3). In tailnet mode Flight Deck replaces fd_address
# with the node's tailnet IP once it joins; the internal IP is only the placeholder.

output "fd_address" {
  value = var.fd_allow_cidr == "" ? google_compute_instance.this.network_interface[0].network_ip : google_compute_instance.this.network_interface[0].access_config[0].nat_ip
}

output "fd_instance_id" {
  value = google_compute_instance.this.id
}
