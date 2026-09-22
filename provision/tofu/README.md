# OpenTofu roots for Avni environments

Built to the plan in [`../OPENTOFU_LOADTEST_ENV_PLAN.md`](../OPENTOFU_LOADTEST_ENV_PLAN.md).
The load-test environment is the first consumer; the module is written to be
reusable for the dedicated customer environments that follow.

    modules/avni-env/    the reusable environment
    envs/loadtest/       first instantiation

**This is not yet applyable.** The backend, state encryption and lock table do
not exist (plan tasks 0.3-0.5, issue #103), so the root initialises for
validation only:

    tofu -chdir=envs/loadtest init -backend=false
    tofu -chdir=envs/loadtest validate
    tofu -chdir=envs/loadtest fmt -recursive -check

Nothing here requires AWS credentials until task 0.3.

**Two things must be true before an apply is useful.** The zone is public and
delegated from `avniproject.org`, which lives in the *production* account: take
`zone_name_servers` from the output and add it there as an NS record set, or the
name will not resolve and the ACM certificate will sit pending. And the
application port is reachable only from `injector_allowed_cidrs`, which is empty
by default and set per run:

    tofu -chdir=envs/loadtest apply -var 'injector_allowed_cidrs=["203.0.113.4/32"]'

That list feeds both the ALB security group and the WAF IP set. A run from an
un-enrolled address fails as connection errors that read like a server falling
over, so enrolling is a pre-run step, not a provisioning one.
