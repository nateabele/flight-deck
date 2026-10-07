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
