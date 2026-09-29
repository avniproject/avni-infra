#!/usr/bin/env python3
"""Emit the extra-vars JSON the load-test playbooks need, secrets included.

WHY THIS IS NOT AN ANSIBLE LOOKUP
    The obvious design is `lookup('amazon.aws.secretsmanager_secret', ...)` in
    group_vars. On a macOS control machine that segfaults. The aws_ec2 dynamic
    inventory calls AWS in the PARENT process, initialising Apple's
    Network.framework; Ansible then forks a worker, the lookup touches the
    framework in the child, and it dies inside nw_path_evaluator_evaluate.

    It surfaces as "[ERROR]: A worker was found in a dead state" on whichever
    task first needs a secret -- here, rendering newrelic.yml.j2 -- and names
    neither AWS nor fork. OBJC_DISABLE_INITIALIZE_FORK_SAFETY does not fix it;
    that suppresses the Obj-C initialiser check, a different crash.

    Running before Ansible starts sidesteps forking entirely. Linux CI would
    not hit the crash, but this works on both rather than only one.

OUTPUT IS SECRET
    stdout carries the database password and the New Relic licence key. The
    caller redirects it to a file created under umask 077. Do not log it, and
    do not pass these on a command line, where ps would show them.
"""
import json
import os
import subprocess
import sys


def aws(*args: str) -> str:
    """Run the AWS CLI and return stdout, failing loudly with its stderr."""
    proc = subprocess.run(
        ["aws", *args], capture_output=True, text=True,
        # The CLI inherits credentials from the environment. Naming a profile
        # here would override them and retry the MFA-gated assume-role that a
        # non-interactive run cannot complete -- the same trap as everywhere
        # else in this repo.
    )
    if proc.returncode != 0:
        sys.exit(f"{' '.join(args[:2])} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def main() -> None:
    region = os.environ["AVNI_REGION"]

    secret_json = aws("secretsmanager", "get-secret-value",
                      "--secret-id", os.environ["AVNI_DB_SECRET"],
                      "--region", region,
                      "--query", "SecretString", "--output", "text")
    try:
        password = json.loads(secret_json)["password"]
    except (ValueError, KeyError):
        sys.exit("the RDS managed secret did not contain a 'password' field")

    # A missing licence key is fatal rather than empty: an agent that starts
    # and reports nothing makes the rig quietly faster than production, which
    # is the failure the New Relic requirement exists to prevent.
    key = aws("ssm", "get-parameter",
              "--name", os.environ["AVNI_NR_PARAM"],
              "--with-decryption", "--region", region,
              "--query", "Parameter.Value", "--output", "text")
    if not key:
        sys.exit(f"{os.environ['AVNI_NR_PARAM']} resolved to an empty value")

    json.dump({
        "loadtest_db_host": os.environ["AVNI_DB_HOST"],
        "loadtest_db_secret_name": os.environ["AVNI_DB_SECRET"],
        "loadtest_db_password": password,
        "loadtest_newrelic_license_key": key,
    }, sys.stdout)


if __name__ == "__main__":
    main()
