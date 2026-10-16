# Resolve load-test credentials into the environment. SOURCE this, do not run it:
#
#     . provision/scripts/aws-session.sh
#
# Why it exists. OpenTofu's aws_kms key provider (state and plan encryption)
# uses the AWS SDK's credential chain, which reads `mfa_serial` from the profile
# but cannot prompt for the code — the CLI can prompt and cache, a library
# cannot. It fails with "assume role with MFA enabled, but
# AssumeRoleTokenProvider session option not set". The fix is to hand every
# consumer already-resolved credentials instead of a profile to assume.
#
# Why it is a script rather than a one-liner. The obvious
# `eval "$(aws configure export-credentials ...)"` is dangerous: if the CLI
# cannot prompt for MFA it prints nothing and exits non-zero, `eval ""`
# succeeds, and with AWS_PROFILE unset the SDK falls back to `default` — which
# is the PRODUCTION account. That has happened. Everything below exists to make
# that failure loud.
#
# If it asks for an MFA code and the terminal cannot echo, run
# `aws sts get-caller-identity --profile avni-load-test` in a real terminal
# first to refresh the cache, then source this.
#
# **NAME THE PROFILE WHEN SOURCING FROM A SCRIPT THAT TAKES ARGUMENTS.**
# `.` does not reset positional parameters, so this file sees the CALLER's "$1".
# A script invoked as `swap-dataset.sh pilot-day-120` that sources this bare
# makes it try to resolve a profile called "pilot-day-120", fail, and leave the
# shell on the default profile -- which is production. Write:
#
#   . provision/scripts/aws-session.sh avni-load-test
#
# Nothing warns about this at the call site, and it only appears once a caller
# starts taking arguments.

_avni_session() {
  local profile="${1:-avni-load-test}"
  local expect_account=936573213727
  local prod_account=118388513628
  local creds account

  if ! creds=$(aws configure export-credentials --profile "$profile" --format env 2>&1); then
    printf 'aws-session: could not resolve profile %s\n%s\n' "$profile" "$creds" >&2
    printf 'aws-session: refresh MFA in an interactive terminal:\n' >&2
    printf '  aws sts get-caller-identity --profile %s\n' "$profile" >&2
    # **Leave nothing usable behind.** Every other failure below unsets the
    # exported credentials; this path did not, and the caller was then left on
    # whatever was already configured -- which is the production profile. On
    # 16 Oct that turned a mistyped profile into two runs that resolved to
    # production and were stopped only by the caller's own account guard.
    # AWS_PROFILE is pinned to what was asked for rather than cleared, so a
    # later call fails loudly on that profile instead of quietly succeeding
    # against the default one.
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    export AWS_PROFILE="$profile"
    return 1
  fi

  # An empty or non-export payload means the CLI bailed without a clean exit
  # code. Do not let it through: the fallback is production.
  case "$creds" in
    *AWS_ACCESS_KEY_ID*) : ;;
    *) printf 'aws-session: no credentials in output; refusing to continue\n' >&2
       unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
       export AWS_PROFILE="$profile"
       return 1 ;;
  esac

  eval "$creds"

  # AWS_PROFILE must go. Left set, the SDK prefers the profile and retries the
  # assume-role path, ignoring what was just exported.
  unset AWS_PROFILE

  if ! account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    printf 'aws-session: exported credentials do not work\n' >&2
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    return 1
  fi

  if [ "$account" = "$prod_account" ] || [ "$account" != "$expect_account" ]; then
    printf 'aws-session: resolved to account %s, expected %s — unsetting\n' "$account" "$expect_account" >&2
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    return 1
  fi

  printf 'aws-session: %s (%s), credentials in environment\n' "$profile" "$account"
}

_avni_session "$@"
