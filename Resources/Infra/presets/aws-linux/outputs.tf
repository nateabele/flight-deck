# The module contract's outputs (spec §5.3). In tailnet mode Flight Deck replaces fd_address
# with the node's tailnet IP once it joins; the private IP is only the placeholder.

output "fd_address" {
  value = var.fd_allow_cidr == "" ? aws_instance.this.private_ip : aws_instance.this.public_ip
}

output "fd_instance_id" {
  value = aws_instance.this.id
}
