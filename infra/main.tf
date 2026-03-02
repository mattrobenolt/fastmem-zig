terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    orbstack = {
      source  = "registry.terraform.io/robertdebock/orbstack"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  # Reads AWS_PROFILE and AWS_REGION from environment
}
