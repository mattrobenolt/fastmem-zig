# Offline checks of the launch templates. The mock provider needs no AWS
# credentials, and `command = plan` writes no key file.
# Run: tofu -chdir=infra/modules/bench-base test

variables {
  project = "fastmem-bench"
  amis = {
    x86_64 = "ami-0e78db03e0a4e1eb0"
    arm64  = "ami-0b1109b091092c6fe"
  }
  image_version = "7"
  nixos_module  = "{ pkgs, ... }: { environment.systemPackages = [ pkgs.jq ]; }"
  key_file      = "/tmp/bench-base-test/bench.pem"
}

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }
}

# The mock cannot vary by instance, so both AMIs get the same values. The
# owner and architecture filters of data.aws_ami.pinned run only in AWS.
override_data {
  target = data.aws_ami.pinned
  values = {
    root_device_name = "/dev/xvda"
  }
}

run "launch_templates" {
  command = plan

  assert {
    condition     = toset(keys(aws_launch_template.bench)) == toset(["x86_64", "arm64"])
    error_message = "Expected one launch template for x86_64 and one for arm64."
  }

  assert {
    condition     = aws_launch_template.bench["x86_64"].name == "fastmem-bench-x86_64" && aws_launch_template.bench["arm64"].name == "fastmem-bench-arm64"
    error_message = "Launch template names must be <project>-<arch>."
  }

  assert {
    condition = alltrue([
      for lt in aws_launch_template.bench :
      lt.instance_initiated_shutdown_behavior == "terminate"
      && lt.instance_type == null
      && lt.metadata_options[0].http_tokens == "required"
      && lt.metadata_options[0].instance_metadata_tags == "enabled"
      && lt.user_data == base64encode(output.user_data)
    ])
    error_message = "A launch template lost terminate-on-shutdown, IMDSv2, metadata tags, or the user_data."
  }

  assert {
    condition = alltrue([
      for lt in aws_launch_template.bench :
      lt.block_device_mappings[0].device_name == "/dev/xvda"
      && lt.block_device_mappings[0].ebs[0].volume_type == "gp3"
      && lt.block_device_mappings[0].ebs[0].volume_size == 20
    ])
    error_message = "The root volume must be gp3, 20 GiB, on the AMI root device."
  }

  assert {
    condition = alltrue([
      for lt in aws_launch_template.bench :
      toset([for spec in lt.tag_specifications : spec.resource_type]) == toset(["instance", "volume", "network-interface"])
      && alltrue([for spec in lt.tag_specifications : spec.tags == tomap({ Project = "fastmem-bench", ManagedBy = "ec2bench" })])
    ])
    error_message = "Instances, volumes, and network interfaces must get Project and ManagedBy from the launch template."
  }

  assert {
    condition     = aws_security_group.ssh.name == "fastmem-bench-ssh"
    error_message = "The security group must be <project>-ssh."
  }

  assert {
    condition     = local_sensitive_file.ssh_key.file_permission == "0600" && output.key_file == "/tmp/bench-base-test/bench.pem"
    error_message = "The key file must be var.key_file with mode 0600."
  }

  # The harness interface: these three outputs, with these shapes.
  assert {
    condition = (
      keys(output.launch_template_ids) == ["arm64", "x86_64"]
      && output.launch_template_ids["x86_64"] == aws_launch_template.bench["x86_64"].id
      && output.launch_template_ids["arm64"] == aws_launch_template.bench["arm64"].id
    )
    error_message = "launch_template_ids must map exactly x86_64 and arm64 to launch template IDs."
  }

  assert {
    condition     = startswith(output.key_file, "/")
    error_message = "key_file must be an absolute path."
  }

  assert {
    condition     = output.security_group_id == aws_security_group.ssh.id
    error_message = "security_group_id must be the ID of the SSH security group."
  }

  # The rendered box configuration carries the fleet contract and the
  # project module, and no unrendered template syntax.
  assert {
    condition = (
      strcontains(output.user_data, "environment.etc.\"bench-image\".text = \"7\\n\";")
      && strcontains(output.user_data, "pkgs.jq")
      && strcontains(output.user_data, "programs.nix-ld.enable = true;")
      && strcontains(output.user_data, "systemd.timers.bench-ttl-guard")
      && strcontains(output.user_data, "-w '%%{http_code}'")
      && !startswith(output.user_data, "#!")
      && length(regexall("(?m)^###", output.user_data)) == 0
    )
    error_message = "The rendered user_data lost part of the fleet contract."
  }
}
