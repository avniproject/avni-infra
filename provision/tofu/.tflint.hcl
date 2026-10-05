# Static analysis for the avni-env module.
#
# `tofu validate` checks syntax and types; it does not know that an instance
# type is invalid, that an argument was deprecated, or that a required field is
# missing for a particular resource. The AWS ruleset does, and it runs without
# credentials — which is the whole point while the account is still activating.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  call_module_type = "all"
}
