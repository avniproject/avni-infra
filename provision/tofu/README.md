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
