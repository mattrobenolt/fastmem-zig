# IAM user for the benchmark fleet.
#
# A human applies this stack once, with an IAM-capable profile
# (playground-ops). It creates the IAM user, its policy (policy.tf), and one
# access key. write-credentials.sh then writes the key to the profile that
# bench.toml names. infra/README.md is the runbook.
#
# terraform.tfstate holds the secret access key. It is gitignored. Do not
# commit it and do not copy it off this machine.

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
}

locals {
  region = "us-west-2"

  # The [project] table of bench.toml at the repository root, up to the next
  # table header. project.name names the resources, and it is the Project tag
  # value that the IAM policy requires. The harness tags instances with the
  # same value. One source keeps them equal, and a copy of infra/ into
  # another project needs no edits. project.profile names the credentials
  # profile that write-credentials.sh writes.
  bench_project = regex(
    "(?ms)^\\[project\\][^\\n]*\\n(.*?)(?:^\\[|\\z)",
    file("${path.module}/../../bench.toml"),
  )[0]
  project = regex("(?m)^[ \\t]*name[ \\t]*=[ \\t]*\"([^\"]+)\"", local.bench_project)[0]
  profile = regex("(?m)^[ \\t]*profile[ \\t]*=[ \\t]*\"([^\"]+)\"", local.bench_project)[0]
}

# Credentials come from AWS_PROFILE in the environment.
provider "aws" {
  region              = local.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = local.project
      ManagedBy = "tofu"
    }
  }
}

# The default VPC is the only VPC that the user can create security groups in.
data "aws_vpc" "default" {
  default = true
}

resource "aws_iam_user" "bench" {
  name = local.project
}

# A customer managed policy, not an inline policy: IAM limits the inline
# policies of a user to 2,048 characters in total, and this policy is larger.
# A managed policy can have 6,144 characters.
resource "aws_iam_policy" "bench" {
  name        = "${local.project}-ec2"
  description = "EC2 access for the ${local.project} fleet, scoped by the Project tag"
  policy      = jsonencode(local.policy)
}

resource "aws_iam_user_policy_attachment" "bench" {
  user       = aws_iam_user.bench.name
  policy_arn = aws_iam_policy.bench.arn
}

resource "aws_iam_access_key" "bench" {
  user = aws_iam_user.bench.name
}
