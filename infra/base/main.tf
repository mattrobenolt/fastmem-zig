# Durable fleet resources for fastmem-bench (modules/bench-base).
#
# The bench profile (fastmem-bench) applies this stack. The harness reads the
# outputs with `tofu -chdir=infra/base output -json`. infra/README.md is the
# runbook.
#
# terraform.tfstate and bench.pem hold the private SSH key. Both are
# gitignored.

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

locals {
  # Keep equal to project.name and project.region in bench.toml. The harness
  # test suite checks that.
  project    = "fastmem-bench"
  region     = "us-west-2"
  account_id = "396684171460"
}

# Credentials come from AWS_PROFILE in the environment. default_tags puts
# Project and ManagedBy on every resource, in the create request itself. The
# bench-iam policy requires that.
provider "aws" {
  region              = local.region
  allowed_account_ids = [local.account_id]

  default_tags {
    tags = {
      Project   = local.project
      ManagedBy = "tofu"
    }
  }
}

module "bench" {
  source = "../modules/bench-base"

  project = local.project

  # Official NixOS 25.11.12484.b6018f87da91 AMIs in us-west-2. A new AMI
  # takes effect for new instances only.
  amis = {
    x86_64 = "ami-0e78db03e0a4e1eb0"
    arm64  = "ami-0b1109b091092c6fe"
  }

  # Keep equal to project.image_version in bench.toml.
  image_version = "1"
  nixos_module  = file("${path.module}/image.nix")
  key_file      = "${path.module}/bench.pem"
}

# The resources were created at the root before the module existed.
moved {
  from = aws_security_group.ssh
  to   = module.bench.aws_security_group.ssh
}

moved {
  from = tls_private_key.ssh
  to   = module.bench.tls_private_key.ssh
}

moved {
  from = aws_key_pair.bench
  to   = module.bench.aws_key_pair.bench
}

moved {
  from = local_sensitive_file.ssh_key
  to   = module.bench.local_sensitive_file.ssh_key
}

moved {
  from = aws_launch_template.bench
  to   = module.bench.aws_launch_template.bench
}
