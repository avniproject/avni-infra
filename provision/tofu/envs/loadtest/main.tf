module "avni_env" {
  source = "../../modules/avni-env"

  environment = "loadtest"

  # The addresses permitted to reach the application port. This is the only
  # input that changes between RUNS rather than between environments, and it is
  # the whole isolation control for that port — the server runs with
  # AVNI_IDP_TYPE=none after the cutover, so anyone who can reach it is
  # whoever they claim to be.
  #
  # Set it per run rather than committing a list here: the office NAT address
  # for a local run, the injector's elastic IP (injector_public_ip output) for
  # an in-VPC one.
  #
  #   tofu -chdir=envs/loadtest apply -var 'injector_allowed_cidrs=["203.0.113.4/32"]'
  #
  # Empty means the port is unreachable, which is the safe default and not an
  # oversight.
  injector_allowed_cidrs = var.injector_allowed_cidrs

  # Everything else takes the module defaults, which encode the decisions in
  # provision/OPENTOFU_LOADTEST_ENV_PLAN.md. Override here only to deviate
  # deliberately — and record the deviation in the parity report.
}
