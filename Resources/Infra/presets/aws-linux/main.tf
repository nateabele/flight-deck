locals {
  # Graviton families put a `g` after the generation digit (t4g, m7g, m7gd, c7gn, x2gd, g5g);
  # GPU families like g6 or p5 start with their letter and so do not match.
  arch = coalesce(var.arch, can(regex("^[a-z]+[0-9]+[a-z]*g[a-z]*\\.", var.instance_type)) ? "arm64" : "x86_64")
}

# Canonical's Ubuntu 24.04 — the distro hostd-install.sh is tested against
# (scripts/test-hostd-install.sh runs it in ubuntu:24.04).
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"]
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.arch == "arm64" ? "arm64" : "amd64"}-server-*"]
  }
}

data "aws_vpc" "default" {
  default = true
}

# Not every type is offered in every zone (GPU families especially), and an unpinned launch
# lets AWS pick a zone that rejects the type. Pinning the first zone that offers it, and the
# default VPC's subnet there, turns that into a deterministic success.
data "aws_ec2_instance_type_offerings" "here" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = try(sort(data.aws_ec2_instance_type_offerings.here.locations)[0], null)
  default_for_az    = true

  lifecycle {
    precondition {
      condition     = length(data.aws_ec2_instance_type_offerings.here.locations) > 0
      error_message = "${var.instance_type} is not offered in any zone of ${var.region}."
    }
  }
}

# Creating a group drops AWS's default allow-all egress, so egress is restated below. There is
# never an SSH rule: the only inbound path, in either mode, is the one hostd rule.
resource "aws_security_group" "this" {
  name_prefix = "fd-${var.fd_name}-"
  description = "Flight Deck host ${var.fd_name}"
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(var.fd_labels, { Name = "fd-${var.fd_name}" })
}

# Outbound is required in both modes: cloud-init downloads hostd (and Tailscale) on boot.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.fd_labels
}

# Public mode only: hostd's port, from this Mac's /32 only (spec §6.2). Tailnet mode reaches
# hostd over the tailnet, so it gets no inbound rule at all.
resource "aws_vpc_security_group_ingress_rule" "hostd" {
  count = var.fd_allow_cidr == "" ? 0 : 1

  security_group_id = aws_security_group.this.id
  ip_protocol       = "tcp"
  from_port         = 47410
  to_port           = 47410
  cidr_ipv4         = var.fd_allow_cidr
  tags              = var.fd_labels
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.this.id]

  user_data                   = var.fd_user_data
  user_data_replace_on_change = true

  # A public address in both modes, because the default VPC's only route out is its internet
  # gateway and cloud-init must download hostd. Tailnet mode stays closed anyway: the group
  # above admits nothing inbound there.
  associate_public_ip_address = true

  # IMDSv2 with hop limit 1 (spec §5.2): a container on the host cannot reach the instance
  # credentials, and a plain GET (SSRF) gets nothing.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # The machine half of "nothing outlives its TTL" (spec §7.2): cloud-init's `shutdown -h`
  # becomes a termination, so a lost Mac cannot leave a stopped instance and its disk billing.
  instance_initiated_shutdown_behavior = "terminate"

  root_block_device {
    volume_size           = var.disk_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
    tags                  = var.fd_labels
  }

  dynamic "instance_market_options" {
    for_each = var.spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        # A one-time request: a "stop"/"hibernate" interruption would need a persistent one
        # and would leave a machine behind.
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  # volume_tags is deliberately unused: it conflicts with root_block_device.tags.
  tags = merge(var.fd_labels, { Name = "fd-${var.fd_name}" })
}
