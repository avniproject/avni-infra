# OpenTofu roots for Avni environments

Built to the plan in [`../OPENTOFU_LOADTEST_ENV_PLAN.md`](../OPENTOFU_LOADTEST_ENV_PLAN.md).
The load-test environment is the first consumer; the module is written to be
reusable for the dedicated customer environments that follow.

    modules/avni-env/    the reusable environment
    envs/loadtest/       first instantiation

**The backend exists.** `scripts/bootstrap-state-backend.sh` created the KMS key
and the state bucket (tasks 0.3-0.5), and `envs/loadtest` now carries a real
`backend "s3"` with S3-native locking plus client-side state *and plan*
encryption, both `enforced = true`.

Credentials come from `AWS_PROFILE` — the backend and the provider both leave it
unset deliberately, so they cannot resolve to different accounts:

    export AWS_PROFILE=avni-load-test
    tofu -chdir=envs/loadtest init
    tofu -chdir=envs/loadtest plan

Static checks still need no credentials:

    tofu -chdir=envs/loadtest init -backend=false
    tofu -chdir=envs/loadtest validate
    tofu -chdir=envs/loadtest fmt -recursive -check
    ../scripts/lint-tofu.sh

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
