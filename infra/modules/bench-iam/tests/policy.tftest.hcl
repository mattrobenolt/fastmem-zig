# Offline checks of the rendered bench user policy. The mock providers need
# no AWS credentials and write no files.
# Run: tofu -chdir=infra/modules/bench-iam test

variables {
  project           = "fastmem-bench"
  region            = "us-west-2"
  account_id        = "396684171460"
  instance_families = ["c7i", "c8i", "c7a", "c8a", "c7g", "c8g", "c9g"]
}

mock_provider "archive" {}

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }

  # Resources that other resources validate as ARNs.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::396684171460:policy/fastmem-bench-ec2"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::396684171460:role/fastmem-bench-reaper"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:396684171460:log-group:/aws/lambda/fastmem-bench-reaper"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-west-2:396684171460:function:fastmem-bench-reaper"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-west-2:396684171460:rule/fastmem-bench-reaper"
    }
  }
}

run "policy" {
  command = plan

  # IAM counts characters without white space. jsonencode emits none. If this
  # fails, split the policy into two managed policies on the user.
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

  # A stopped box does not run its TTL guard, and a start resets LaunchTime.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for a in flatten([try(s.Action, [])]) : !contains(["ec2:StopInstances", "ec2:StartInstances", "ec2:*"], a)
      ] if s.Effect == "Allow"
    ]))
    error_message = "The policy allows StopInstances or StartInstances."
  }

  # Canonical tag keys: every Allow statement that creates tags (a
  # RunInstances statement that requires a request tag, a create action with
  # tags, or CreateTags) limits aws:TagKeys to the exact set. The default
  # tags of the root stacks (Project, ManagedBy) and the instance tags of the
  # harness are in the set.
  assert {
    condition = alltrue([
      for s in local.policy.Statement :
      try(s.Condition["ForAllValues:StringEquals"]["aws:TagKeys"], []) == ["Project", "ManagedBy", "Name", "Target", "ExpiresAt", "Owner"]
      if s.Effect == "Allow" && (
        contains(flatten([s.Action]), "ec2:CreateTags")
        || can(s.Condition.StringEquals["aws:RequestTag/Project"])
      )
    ])
    error_message = "A statement that creates tags does not limit aws:TagKeys to the canonical set."
  }

  assert {
    condition = toset([
      for s in local.policy.Statement : s.Sid
      if can(s.Condition["ForAllValues:StringEquals"]["aws:TagKeys"])
      ]) == toset([
      "RunInstancesInstance", "RunInstancesVolume", "RunInstancesNetworkInterface",
      "TagOnCreate", "TagProjectResources", "CreateBaseResources",
    ])
    error_message = "The set of statements with the canonical tag key condition changed."
  }

  # Project and ExpiresAt cannot be deleted, in any case spelling. The Deny
  # does not fire when aws:TagKeys is absent (DeleteTags without keys), so the
  # Allow must require the key.
  assert {
    condition = (
      one([
        for s in local.policy.Statement : s
        if s.Effect == "Deny" && try(s.Action, "") == "ec2:DeleteTags" && s.Resource == "*"
      ]).Condition == { "ForAnyValue:StringEqualsIgnoreCase" = { "aws:TagKeys" = ["Project", "ExpiresAt"] } }
      && one([for s in local.policy.Statement : s.Condition.Null["aws:TagKeys"] if s.Sid == "UntagProjectResources"]) == "false"
    )
    error_message = "Project and ExpiresAt are not protected from DeleteTags."
  }

  # EBS: gp3 baseline only, 100 GiB or smaller.
  assert {
    condition = (
      one([for s in local.policy.Statement : s.Condition.NumericLessThanEqualsIfExists if s.Sid == "RunInstancesVolume"])
      == { "ec2:VolumeSize" = "100", "ec2:VolumeIops" = "3000", "ec2:VolumeThroughput" = "125" }
      && one([for s in local.policy.Statement : s.Condition.StringEqualsIfExists["ec2:VolumeType"] if s.Sid == "RunInstancesVolume"]) == "gp3"
    )
    error_message = "The volume limits changed."
  }

  # On-demand only. EC2 sets the key on every launch, so no IfExists.
  assert {
    condition     = one([for s in local.policy.Statement : s.Condition.StringEquals["ec2:InstanceMarketType"] if s.Sid == "RunInstancesInstance"]) == "on-demand"
    error_message = "RunInstances does not require the on-demand market."
  }

  # Subnet and network interface are separate: a new network interface must
  # carry the project tag, and a subnet cannot.
  assert {
    condition = (
      one([for s in local.policy.Statement : s.Resource if s.Sid == "RunInstancesSubnet"]) == "arn:aws:ec2:us-west-2:396684171460:subnet/*"
      && one([for s in local.policy.Statement : s.Resource if s.Sid == "RunInstancesNetworkInterface"]) == "arn:aws:ec2:us-west-2:396684171460:network-interface/*"
      && one([for s in local.policy.Statement : s.Condition.StringEquals["aws:RequestTag/Project"] if s.Sid == "RunInstancesNetworkInterface"]) == "fastmem-bench"
    )
    error_message = "Subnet and network-interface authorization must be split, and a new network interface must carry the project tag."
  }

  # Every resource that RunInstances creates must carry the project tag.
  assert {
    condition = alltrue([
      for type in ["instance", "volume", "network-interface"] :
      anytrue([
        for s in local.policy.Statement :
        try(s.Action, "") == "ec2:RunInstances"
        && s.Resource == "arn:aws:ec2:us-west-2:396684171460:${type}/*"
        && try(s.Condition.StringEquals["aws:RequestTag/Project"], "") == "fastmem-bench"
      ])
    ])
    error_message = "RunInstances can create an instance, volume, or network interface without the project tag."
  }
}
