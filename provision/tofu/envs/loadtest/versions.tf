terraform {
  # OpenTofu, not Terraform: this root relies on client-side state and plan
  # encryption (1.7+) and S3-native state locking (1.10+), neither of which
  # Terraform provides. See the plan, §8 Phase 0.
  required_version = ">= 1.12.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Backend and encryption are deliberately absent until the state bucket, KMS
  # key and lock table exist (tasks 0.3-0.5). Until then this root initialises
  # with `tofu init -backend=false` for validation only.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = "loadtest"
      ManagedBy   = "opentofu"
      Plan        = "provision/OPENTOFU_LOADTEST_ENV_PLAN.md"
    }
  }
}
