# Durable fleet resources: the SSH security group, the key pair, and one
# launch template for each architecture.
#
# The bench profile (fastmem-bench) applies this stack. The harness launches
# and terminates instances through the EC2 API from these launch templates.
# It reads the outputs with `tofu -chdir=infra/base output -json`.
# infra/README.md is the runbook.
#
# terraform.tfstate and bench.pem hold the private SSH key. Both are
# gitignored.

terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

locals {
  region = "us-west-2"

  # The [project] table of bench.toml at the repository root, up to the next
  # table header. project.name names the resources, and it is the Project tag
  # value that the IAM policy requires. The harness tags instances with the
  # same value. One source keeps them equal, and a copy of infra/ into
  # another project needs no edits.
  bench_project = regex(
    "(?ms)^\\[project\\][^\\n]*\\n(.*?)(?:^\\[|\\z)",
    file("${path.module}/../../bench.toml"),
  )[0]
  project = regex("(?m)^[ \\t]*name[ \\t]*=[ \\t]*\"([^\"]+)\"", local.bench_project)[0]

  # Official NixOS 25.11.12484.b6018f87da91 AMIs in us-west-2, by the
  # architecture name that EC2 uses. The key is also the launch template
  # suffix and the `arch` value of a target in bench.toml. A new AMI takes
  # effect for new instances only.
  amis = {
    x86_64 = "ami-0e78db03e0a4e1eb0"
    arm64  = "ami-0b1109b091092c6fe"
  }
}

# Credentials come from AWS_PROFILE in the environment. default_tags puts
# Project and ManagedBy on every resource of this stack, in the create
# request itself. The IAM policy requires that.
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

data "aws_vpc" "default" {
  default = true
}

# Look up each pinned AMI. The owner and architecture filters make a wrong
# or swapped ID fail at plan time, before it reaches a launch template.
data "aws_ami" "pinned" {
  for_each = local.amis

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
