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

  # ETL host off: testing under concurrent ETL load is deferred.
  #
  # This is a deliberate deviation, not a saving, and it is worth being precise
  # about what it costs. The module defaults this ON because the harness treats
  # sync-with-concurrent-ETL as a scenario rather than an option: ETL runs a
  # 90-minute Quartz cycle that reads `public` in competition with sync, writes
  # org schemas, and drops and recreates materialised views — all against the
  # same fixed 3,000 IOPS the sync path is contending for. An environment
  # without it is quieter than any real one.
  #
  # So while this is false, results describe sync with the database to itself.
  # That is a real measurement and a useful one; it is just not the number the
  # hosting decision needs, which is the DELTA between the two. Turn it back on
  # and re-run before treating any result as production-representative.
  #
  # The parity report renders ETL as "absent" on every apply while this holds,
  # so the caveat travels with the results rather than living here.
  enable_etl = false

  # Everything else takes the module defaults, which encode the decisions in
  # provision/OPENTOFU_LOADTEST_ENV_PLAN.md. Override here only to deviate
  # deliberately — and record the deviation in the parity report.
}
