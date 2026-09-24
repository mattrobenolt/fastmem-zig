# Offline checks of the rendered policy. The mock provider needs no AWS
# credentials. Run: tofu -chdir=infra/modules/bench-iam test

variables {
  project           = "fastmem-bench"
  region            = "us-west-2"
  account_id        = "396684171460"
  instance_families = ["c7i", "c8i", "c7a", "c8a", "c7g", "c8g", "c9g"]
}

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }

  # The attachment validates the ARN format.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::396684171460:policy/fastmem-bench-ec2"
    }
  }
}

run "policy" {
  command = plan

  # IAM counts characters without white space. jsonencode emits none.
  assert {
    condition     = length(aws_iam_policy.bench.policy) <= 6144
    error_message = "The policy has ${length(aws_iam_policy.bench.policy)} characters. A managed policy can have 6,144."
  }

  assert {
    condition = (
      one([for s in local.policy.Statement : s.Condition.StringLike["ec2:InstanceType"] if s.Sid == "RunInstancesInstance"])
      == ["c7i.*", "c8i.*", "c7a.*", "c8a.*", "c7g.*", "c8g.*", "c9g.*"]
    )
    error_message = "The instance type allowlist changed."
  }

  # Every RunInstances statement, except the one for the launch template
  # itself, must require a launch template.
  assert {
    condition = alltrue([
      for s in local.policy.Statement :
      s.Condition.ArnLike["ec2:LaunchTemplate"] == "arn:aws:ec2:us-west-2:396684171460:launch-template/*"
      if try(s.Action, "") == "ec2:RunInstances" && s.Sid != "RunInstancesLaunchTemplate"
    ])
    error_message = "A RunInstances statement does not require a launch template."
  }

  # Every Allow statement except Read names ARNs in the fleet region.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for r in flatten([s.Resource]) : startswith(r, "arn:aws:ec2:us-west-2:")
      ] if s.Effect == "Allow" && s.Sid != "Read"
    ]))
    error_message = "An Allow statement names a resource outside us-west-2."
  }

  # Only EC2 actions are allowed.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for a in flatten([s.Action]) : startswith(a, "ec2:")
      ] if s.Effect == "Allow"
    ]))
    error_message = "The policy allows an action outside EC2."
  }

  assert {
    condition     = length(regexall("vpc/vpc-0123456789abcdef0\"", aws_iam_policy.bench.policy)) == 1
    error_message = "CreateSecurityGroup is not limited to the default VPC."
  }
}
