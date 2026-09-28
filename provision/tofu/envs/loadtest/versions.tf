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

  # ---------------------------------------------------------------------
  # State backend (task 0.3)
  #
  # Created by provision/scripts/bootstrap-state-backend.sh, and a different
  # bucket from provision/server/'s `terraform-state` — deliberately, so the
  # historical environment and this one cannot collide.
  #
  # No `profile` here, matching the provider below: both resolve credentials
  # from AWS_PROFILE. Hardcoding it in one and not the other is how state ends
  # up in a different account from the resources it describes.
  #
  # use_lockfile is S3-native locking (task 0.4). OpenTofu 1.12 does this
  # without DynamoDB, so there is no lock table to create or pay for.
  # ---------------------------------------------------------------------
  backend "s3" {
    bucket       = "avni-tofu-state-936573213727"
    key          = "loadtest/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:ap-south-1:936573213727:key/452e7e2d-4862-458d-9503-927127b3caae"
    use_lockfile = true
  }

  # ---------------------------------------------------------------------
  # State and plan encryption (task 0.5)
  #
  # This is the reason for OpenTofu rather than Terraform. `encrypt` on the
  # backend above is S3 doing server-side encryption at rest; this is the
  # client encrypting before the bytes ever leave the machine.
  #
  # `plan` matters as much as `state` and is easy to forget: a saved plan file
  # carries the same secret values the state does — the generated database
  # password among them — so an unencrypted plan undoes an encrypted state.
  #
  # enforced = true on both means a read or write of unencrypted data FAILS
  # rather than silently falling back. That is the point; without it this is
  # decoration.
  # ---------------------------------------------------------------------
  encryption {
    key_provider "aws_kms" "state" {
      kms_key_id = "arn:aws:kms:ap-south-1:936573213727:key/452e7e2d-4862-458d-9503-927127b3caae"
      region     = "ap-south-1"
      key_spec   = "AES_256"
    }

    method "aes_gcm" "default" {
      keys = key_provider.aws_kms.state
    }

    state {
      method   = method.aes_gcm.default
      enforced = true
    }

    plan {
      method   = method.aes_gcm.default
      enforced = true
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      # Cost attribution. The account is already a billing dimension in its own
      # right, so this is for aggregating one client's spend ACROSS accounts.
      # Remember it does not reach Cost Explorer until activated as a cost
      # allocation tag in Billing, and activation is not retroactive.
      Client      = "Tanuh"
      Environment = "loadtest"
      ManagedBy   = "opentofu"
      Plan        = "provision/OPENTOFU_LOADTEST_ENV_PLAN.md"
    }
  }
}
