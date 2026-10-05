#!/usr/bin/env bash
# Static analysis for the OpenTofu roots.
#
# `tofu validate` checks syntax and types. It does not know that an instance
# type is invalid, that an argument was deprecated, or that a required field is
# missing — tflint's AWS ruleset does, and it needs no credentials.
#
# The --config is passed explicitly and deliberately. tflint resolves
# .tflint.hcl relative to --chdir, so without this the AWS plugin silently does
# not load: you get a clean exit that means nothing, because only the bundled
# terraform ruleset ran. That is how this was first set up, and it passed an
# invalid instance type without comment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tofu"
CFG="$ROOT/.tflint.hcl"

command -v tflint >/dev/null || {
  echo "tflint not installed: brew install terraform-linters/tap/tflint" >&2
  exit 1
}

tflint --config="$CFG" --init >/dev/null

FAIL=0
for d in modules/avni-env envs/loadtest; do
  echo "== $d"
  ( cd "$ROOT" && tofu fmt -check -recursive "$d" ) || { echo "   fmt: needs formatting"; FAIL=1; }
  tflint --config="$CFG" --chdir="$ROOT/$d" --format compact || FAIL=1
done

# Guard against the silent-pass failure mode above: prove the AWS ruleset is
# actually loaded rather than trusting a clean exit. --version lists the
# rulesets tflint resolved from the config.
tflint --config="$CFG" --version | grep -q "ruleset.aws" || {
  echo "ERROR: the AWS ruleset is not loaded — a clean run above means nothing" >&2
  exit 1
}

[ $FAIL -eq 0 ] && echo "all clean"
exit $FAIL
