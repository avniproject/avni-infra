module "avni_env" {
  source = "../../modules/avni-env"

  environment = "loadtest"

  # Everything else takes the module defaults, which encode the decisions in
  # provision/OPENTOFU_LOADTEST_ENV_PLAN.md. Override here only to deviate
  # deliberately — and record the deviation in the parity report.
}
