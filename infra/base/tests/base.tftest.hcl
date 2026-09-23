# Offline checks of the launch templates. The mock provider needs no AWS
# credentials, and `command = plan` writes no key file.
# Run: tofu -chdir=infra/base test

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
      && lt.user_data == filebase64("${path.module}/../image/configuration.nix")
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
      toset([for spec in lt.tag_specifications : spec.resource_type]) == toset(["instance", "volume"])
      && alltrue([for spec in lt.tag_specifications : spec.tags["Project"] == "fastmem-bench"])
    ])
    error_message = "Instances and volumes must get the Project tag from the launch template."
  }

  assert {
    condition     = aws_security_group.ssh.name == "fastmem-bench-ssh"
    error_message = "The security group must be <project>-ssh."
  }

  assert {
    condition     = local_sensitive_file.ssh_key.file_permission == "0600" && endswith(output.key_file, "/bench.pem")
    error_message = "The key file must be bench.pem with mode 0600."
  }
}
