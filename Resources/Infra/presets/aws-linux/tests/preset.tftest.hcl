# `tofu test` for the aws-linux preset (scripts/test-infra-presets.sh). mock_provider replaces
# the AWS provider entirely, so these plans need no credentials and make no cloud call — every
# assertion is about what the module WOULD ask AWS for.

mock_provider "aws" {
  # The AMI lookup is a data source; without a mock id the plan would carry an unknown `ami`
  # and nothing here depends on its value, but a realistic id keeps the plan readable.
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
  # The module pins the first zone that offers the type; the mock's default is no zones.
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = {
      locations = ["us-east-1a"]
    }
  }
  # Likewise no VPCs, which the module refuses as "no default VPC".
  mock_data "aws_vpcs" {
    defaults = {
      ids = ["vpc-0123456789abcdef0"]
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
  region        = "us-east-1"
  instance_type = "g6.xlarge"
  ttl_seconds   = 3600
}

run "tailnet_mode_has_no_inbound_rule" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required"
  }
  assert {
    condition     = aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "hop limit 1"
  }
  assert {
    condition     = aws_instance.this.instance_initiated_shutdown_behavior == "terminate"
    error_message = "shutdown must terminate"
  }
  assert {
    condition     = aws_instance.this.tags["flightdeck"] == "1"
    error_message = "labels on the instance"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.hostd) == 0
    error_message = "no inbound in tailnet mode"
  }
  # Every resource carries fd_labels (spec §5.3): the orphan check finds machines by them.
  assert {
    condition     = aws_instance.this.root_block_device[0].tags["flightdeck-owner"] == "ctl" && aws_security_group.this.tags["flightdeck-owner"] == "ctl" && aws_vpc_security_group_egress_rule.all.tags["flightdeck-owner"] == "ctl"
    error_message = "labels on the volume, the group and its rules"
  }
}

run "public_mode_admits_only_the_controller" {
  command = plan

  variables {
    fd_allow_cidr = "198.51.100.7/32"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.hostd[0].cidr_ipv4 == "198.51.100.7/32"
    error_message = "only /32"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.hostd[0].from_port == 47410 && aws_vpc_security_group_ingress_rule.hostd[0].to_port == 47410
    error_message = "only 47410"
  }
}

run "spot" {
  command = plan

  variables {
    spot = true
  }

  assert {
    condition     = length(aws_instance.this.instance_market_options) == 1
    error_message = "spot market options"
  }
}

# A running machine must survive a re-apply (spec §6.2 re-applies when this Mac's public IP
# changes). Canonical publishes a new Noble AMI about weekly and Flight Deck re-renders
# fd_user_data each `up`; `ami` is force-new and `user_data_replace_on_change` makes
# user_data force-new too, so either drifting into the instance would replace it.
#
# The mocks make `apply` free and local, but a mock provider cannot see replacement: force-new
# is the real provider's plan logic, not part of its schema, so the instance id survives
# either way. What is asserted instead is that the triggers themselves never reach the
# instance — the state still holds what it booted with.
run "create" {
  command = apply
}

run "reapply_keeps_the_machine" {
  command = apply

  variables {
    fd_user_data  = "#cloud-config\n# re-rendered\n"
    fd_allow_cidr = "198.51.100.8/32"
  }

  override_data {
    target = data.aws_ami.ubuntu
    values = {
      id = "ami-0fedcba9876543210"
    }
  }

  assert {
    condition     = aws_instance.this.ami == "ami-0123456789abcdef0"
    error_message = "a newer AMI must not reach (and so replace) the running instance"
  }
  assert {
    condition     = aws_instance.this.user_data == "#cloud-config\n"
    error_message = "re-rendered user-data must not reach (and so replace) the running instance"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.hostd[0].cidr_ipv4 == "198.51.100.8/32"
    error_message = "the re-apply must still move the firewall to the new /32"
  }
}

# The arch picks the AMI, and an amd64 image on an arm64 type (or the reverse) is refused by
# RunInstances. The AMI name filter is the one observable place the derived arch lands.
run "gpu_family_is_x86" {
  command = plan

  assert {
    condition     = anytrue([for f in data.aws_ami.ubuntu.filter : anytrue([for v in f.values : strcontains(v, "-amd64-")])])
    error_message = "g6 is an x86 GPU family, not Graviton"
  }
}

run "graviton_is_arm" {
  command = plan

  variables {
    instance_type = "m7g.large"
  }

  assert {
    condition     = anytrue([for f in data.aws_ami.ubuntu.filter : anytrue([for v in f.values : strcontains(v, "-arm64-")])])
    error_message = "m7g is Graviton"
  }
}

# a1 is the first Graviton generation and the one family without the `g` suffix.
run "a1_is_arm" {
  command = plan

  variables {
    instance_type = "a1.large"
  }

  assert {
    condition     = anytrue([for f in data.aws_ami.ubuntu.filter : anytrue([for v in f.values : strcontains(v, "-arm64-")])])
    error_message = "a1 is Graviton (arm64)"
  }
}

# RunInstances creates the primary ENI and, for spot, the spot request, and aws_instance tags
# neither (the provider sends tag specifications for the instance and its volumes only; its
# default_tags reach no further). So each gets fd_labels through aws_ec2_tag.
run "eni_carries_the_labels" {
  command = plan

  assert {
    condition     = { for k, t in aws_ec2_tag.eni : k => t.value } == var.fd_labels
    error_message = "every fd_label on the instance's network interface"
  }
  assert {
    condition     = length(aws_ec2_tag.spot_request) == 0
    error_message = "no spot request to tag on an on-demand machine"
  }
}

run "spot_request_carries_the_labels" {
  command = plan

  variables {
    spot = true
  }

  assert {
    condition     = { for k, t in aws_ec2_tag.spot_request : k => t.value } == var.fd_labels
    error_message = "every fd_label on the spot request"
  }
}

# An account or region with no default VPC (deleted by hand, or an account that predates them)
# must fail at plan, naming the fix. Before the precondition the singular lookup failed inside
# AWS's own read with "no matching EC2 VPC found", which says nothing about what to do. The
# plural lookup returns an empty list instead of failing, which is what the mock models here:
# a mocked singular `aws_vpc` always "finds" one, so it could never show the gap.
run "no_default_vpc_fails_at_plan" {
  command = plan

  override_data {
    target = data.aws_vpcs.default
    values = {
      ids = []
    }
  }

  expect_failures = [data.aws_vpc.default]
}
