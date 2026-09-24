# IAM user for the fastmem-bench fleet (modules/bench-iam).
#
# A human applies this stack once, with an IAM-capable profile
# (playground-ops). write-credentials.sh then writes the access key to the
# fastmem-bench profile. infra/README.md is the runbook.
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
  # Keep equal to project.name and project.region in bench.toml. The harness
  # test suite checks that.
  project    = "fastmem-bench"
  region     = "us-west-2"
  account_id = "396684171460"
}

# Credentials come from AWS_PROFILE in the environment.
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
  source = "../modules/bench-iam"

  project           = local.project
  region            = local.region
  account_id        = local.account_id
  instance_families = ["c7i", "c8i", "c7a", "c8a", "c7g", "c8g", "c9g"]
}

# The resources were created at the root before the module existed.
moved {
  from = aws_iam_user.bench
  to   = module.bench.aws_iam_user.bench
}

moved {
  from = aws_iam_policy.bench
  to   = module.bench.aws_iam_policy.bench
}

moved {
  from = aws_iam_user_policy_attachment.bench
  to   = module.bench.aws_iam_user_policy_attachment.bench
}

moved {
  from = aws_iam_access_key.bench
  to   = module.bench.aws_iam_access_key.bench
}
