# bench-base: the durable resources of a tag-scoped EC2 benchmark fleet.
#
# It creates the SSH security group, the key pair, and one launch template
# for each architecture. A harness (ec2bench) launches and terminates
# instances from the launch templates, and reads the outputs with
# `tofu output -json`. The bench user that the bench-iam module creates, for
# the same project, can apply this module.
#
# The caller owns the provider configuration. Its default_tags must put
# Project = var.project on every resource: the bench-iam policy requires the
# tag in each create request.

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.66"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.4"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.9"
    }
  }
}

locals {
  user_data = templatefile("${path.module}/image.nix.tftpl", {
    image_version = var.image_version
    nixos_module  = var.nixos_module
  })
}

data "aws_vpc" "default" {
  default = true
}

# Look up each pinned AMI. The owner and architecture filters make a wrong
# or swapped ID fail at plan time, before it reaches a launch template.
data "aws_ami" "pinned" {
  for_each = var.amis

  owners = [var.image_owner]

  filter {
    name   = "image-id"
    values = [each.value]
  }

  filter {
    name   = "architecture"
    values = [each.key]
  }
}

resource "aws_security_group" "ssh" {
  name        = "${var.project}-ssh"
  description = "SSH to ${var.project} boxes"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_ingress_cidrs
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "bench" {
  key_name   = var.project
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = var.key_file
  file_permission = "0600"
}

locals {
  # Tags for instances and volumes that a launch template creates. The
  # harness sends the same Project and ManagedBy tags, plus Name, Target,
  # ExpiresAt, and Owner, in its RunInstances request. The IAM policy
  # requires Project and ExpiresAt in that request.
  box_tags = {
    Project   = var.project
    ManagedBy = "ec2bench"
  }
}

# No instance type: the harness sets it in each RunInstances request.
resource "aws_launch_template" "bench" {
  for_each = var.amis

  name        = "${var.project}-${each.key}"
  description = "${var.project} box (${each.key})"

  image_id               = data.aws_ami.pinned[each.key].id
  key_name               = aws_key_pair.bench.key_name
  vpc_security_group_ids = [aws_security_group.ssh.id]

  # The TTL guard on the box runs poweroff. Terminate, not stop, so that an
  # expired box costs nothing.
  instance_initiated_shutdown_behavior = "terminate"

  # amazon-init applies this file with nixos-rebuild on first boot.
  user_data = base64encode(local.user_data)

  # The harness launches the latest version. Keep the default version equal
  # to it for people who launch from the console.
  update_default_version = true

  # IMDSv2 only. Instance metadata tags let the TTL guard read ExpiresAt.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # The root device of the AMI. A different device name would add a second
  # volume and leave the root volume at its AMI size.
  block_device_mappings {
    device_name = data.aws_ami.pinned[each.key].root_device_name

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_gib
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.box_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.box_tags
  }
}
