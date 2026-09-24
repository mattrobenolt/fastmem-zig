# bench-iam: the IAM user and the reaper of a tag-scoped EC2 benchmark fleet.
#
# The user can launch, tag, and terminate only the EC2 resources that carry
# Project = var.project, and it can apply the bench-base module for the same
# project. policy.tf holds the policy and explains each statement.
#
# The reaper (reaper.tf) is a scheduled Lambda function that terminates the
# project instances past their lifetime. It is the lifetime guarantee. The
# TTL guard on each box is only the fast path, because the user controls the
# launch templates.
#
# A human applies this module with an IAM-capable profile. The caller owns
# the provider configuration (region, account guard, default tags).

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.66"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.8"
    }
  }
}

# The default VPC is the only VPC that the user can create security groups in.
data "aws_vpc" "default" {
  default = true
}

resource "aws_iam_user" "bench" {
  name = var.project
}

# A customer managed policy, not an inline policy: IAM limits the inline
# policies of a user to 2,048 characters in total, and this policy is larger.
# A managed policy can have 6,144 characters.
resource "aws_iam_policy" "bench" {
  name        = "${var.project}-ec2"
  description = "EC2 access for the ${var.project} fleet, scoped by the Project tag"
  policy      = jsonencode(local.policy)
}

resource "aws_iam_user_policy_attachment" "bench" {
  user       = aws_iam_user.bench.name
  policy_arn = aws_iam_policy.bench.arn
}

resource "aws_iam_access_key" "bench" {
  user = aws_iam_user.bench.name
}
