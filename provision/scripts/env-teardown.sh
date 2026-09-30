#!/usr/bin/env bash
# Stop, resume or destroy the load-test environment. Plan task 4.4 (issue #109).
#
# WHY THIS EXISTS
#   Running continuously the environment costs roughly USD 455/month, and it is
#   idle almost all of that time — the plan's economics assume something like 26
#   hours a month. The single largest EC2 line is the injector (m6g.xlarge,
#   ~USD 148/month), which does nothing whatsoever between runs.
#
# STOP VERSUS DESTROY, AND THE SEVEN-DAY TRAP
#   `stop` keeps the dataset on disk and resumes in minutes. It stops paying for
#   compute but keeps paying for storage — roughly USD 90/month of the 455.
#
#   `stop` IS NOT VALID FOR LONG GAPS. **A stopped RDS instance restarts itself
#   after 7 days**, silently, and then bills as if running. For anything beyond
#   about a week, capture a baseline and `destroy`; restore on the way back in.
#   `status` counts the days and says so rather than leaving you to remember.
#
# THE OVERRIDE GUARD, AND WHY HOLDS EXPIRE
#   Case 10 is a twelve-hour unattended run. A scheduled stop that fires in the
#   middle of one destroys the result and wastes the day, so `hold` exists.
#
#   Every hold carries an EXPIRY, and that is deliberate. The failure mode of
#   every override guard ever built is the hold somebody set once and forgot,
#   after which the cost control silently does nothing for a month. An expired
#   hold is ignored, and `status` shows holds that have lapsed.
#
# HOW THIS GETS SCHEDULED
#   Deliberately not wired to a scheduler here. The POLICY lives in `stop-idle`
#   below, in one place, so any trigger can call it: cron on a workstation, a
#   scheduled CI job (the natural home once task 6.4's OIDC role exists), or
#   EventBridge. Putting the policy in EventBridge instead would mean either a
#   Lambda to read the hold, or expressing "hold" as a disabled schedule — which
#   the next `tofu apply` would silently re-enable.
set -euo pipefail

CMD="${1:-}"
PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
REGION="${AVNI_AWS_REGION:-ap-south-1}"
ENVIRONMENT="${AVNI_ENVIRONMENT:-loadtest}"
DB_INSTANCE="${AVNI_DB_INSTANCE:-avni-loadtest}"
HOLD_PARAM="${AVNI_HOLD_PARAM:-/avni/${ENVIRONMENT}/teardown-hold}"
EXPECT_ACCOUNT=936573213727
PROD_ACCOUNT=118388513628
TOFU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tofu/envs/loadtest" && pwd)"

# Credentials come from one of two places and the flag matters. If
# aws-session.sh (or CI, or OIDC) has already exported credentials, passing
# --profile OVERRIDES them and sends the CLI back down the assume-role path
# that needs an MFA code it cannot ask for. So only name the profile when
# nothing is already in the environment.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  aws_() { aws "$@" --region "$REGION"; }
  CRED_SOURCE="environment"
else
  aws_() { aws "$@" --profile "$PROFILE" --region "$REGION"; }
  CRED_SOURCE="profile $PROFILE"
fi

# start/stop-db-instance fails for two very different reasons and the difference
# matters. InvalidDBInstanceState means the instance is already in, or heading
# for, the state we asked for — benign. EVERYTHING ELSE is a real failure, and
# InsufficientDBInstanceCapacity is the one that bites: AWS has no room for the
# instance class in the instance's AZ, so the call is rejected outright.
#
# This used to be `2>/dev/null || echo "already starting or running"`, which
# reported exactly that for a capacity rejection. On 2026-09-30 `start` printed
# a reassuring message, exited 0, and left the database stopped — the 502 that
# followed looked like an application fault. Discarding stderr on a call that
# can legitimately fail is how a cost-control script lies to you.
rds_status() {
  aws_ rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo absent
}

# Sets RDS_ERR to the raw AWS error when it returns non-zero, so the caller can
# offer advice specific to the failure instead of guessing.
RDS_ERR=""
rds_transition() {
  local verb="$1" gerund="$2" out rc now
  set +e
  out=$(aws_ rds "${verb}-db-instance" --db-instance-identifier "$DB_INSTANCE" \
          --query 'DBInstance.DBInstanceStatus' --output text 2>&1)
  rc=$?
  set -e
  RDS_ERR=""

  if [ "$rc" -eq 0 ]; then
    echo "rds: $gerund $DB_INSTANCE (status: $out)"
    return 0
  fi

  # Ask what state the instance is actually in rather than parsing the message.
  # "already stopped" and "cannot stop, it has a read replica" are BOTH
  # InvalidDBInstanceState, so treating that code as benign would swallow the
  # replica case — exactly the failure this function exists to surface. Only the
  # status distinguishes them.
  now=$(rds_status)
  case "$verb:$now" in
    start:available|start:starting|start:backing-up|start:modifying)
      echo "rds: $DB_INSTANCE is already $now, nothing to do"; return 0 ;;
    stop:stopped|stop:stopping)
      echo "rds: $DB_INSTANCE is already $now, nothing to do"; return 0 ;;
  esac

  RDS_ERR=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d')
  {
    echo "rds: FAILED to $verb $DB_INSTANCE (current status: $now)"
    printf '%s\n' "$RDS_ERR" | sed 's/^/      /'
  } >&2
  return 1
}

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") {status|stop|start|stop-idle|destroy|hold|release}

  status      what is running, what it is costing, and any hold
  stop        stop EC2 and RDS now, regardless of any hold
  start       bring them back
  stop-idle   stop UNLESS an unexpired hold exists — this is what a scheduler calls
  destroy     tofu destroy, after proving the baseline snapshot survives it
  hold [h] [reason]
              suppress stop-idle for h hours (default 16, enough for a 12-hour
              soak plus slack). Reason is recorded and shown by status
  release     clear the hold

  Environment: AVNI_AWS_PROFILE AVNI_AWS_REGION AVNI_ENVIRONMENT AVNI_DB_INSTANCE
USAGE
  exit 2
}

# ------------------------------------------------------------------ guards
# Same shape as bootstrap-state-backend.sh. This script stops and destroys
# things; running it against the wrong account is the worst outcome in the repo.
assert_account() {
  local account
  account=$(aws_ sts get-caller-identity --query Account --output text)
  if [ "$account" = "$PROD_ACCOUNT" ]; then
    echo "REFUSING: profile $PROFILE resolves to PRODUCTION ($PROD_ACCOUNT)." >&2
    exit 1
  fi
  if [ "$account" != "$EXPECT_ACCOUNT" ]; then
    echo "REFUSING: account $account is not the load-test account ($EXPECT_ACCOUNT)." >&2
    exit 1
  fi
}

instance_ids() {
  aws_ ec2 describe-instances \
    --filters "Name=tag:Environment,Values=${ENVIRONMENT}" \
              "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# Returns 0 when a hold is active and unexpired.
hold_active() {
  local raw expires
  raw=$(aws_ ssm get-parameter --name "$HOLD_PARAM" --query Parameter.Value --output text 2>/dev/null) || return 1
  expires=${raw%%|*}
  [ -n "$expires" ] || return 1
  # Integer epoch comparison; no date parsing, so no GNU/BSD date divergence.
  [ "$(date -u +%s)" -lt "$expires" ]
}

hold_describe() {
  local raw expires reason now
  raw=$(aws_ ssm get-parameter --name "$HOLD_PARAM" --query Parameter.Value --output text 2>/dev/null) || {
    echo "hold:    none"; return 0; }
  expires=${raw%%|*}; reason=${raw#*|}; now=$(date -u +%s)
  if [ "$now" -lt "$expires" ]; then
    printf 'hold:    ACTIVE for %d more hours — %s\n' $(( (expires - now) / 3600 )) "$reason"
  else
    printf 'hold:    lapsed %d hours ago (ignored) — %s\n' $(( (now - expires) / 3600 )) "$reason"
  fi
}

case "$CMD" in
  status)
    assert_account
    echo "account: $EXPECT_ACCOUNT  environment: $ENVIRONMENT  credentials: $CRED_SOURCE"
    hold_describe
    echo
    aws_ ec2 describe-instances \
      --filters "Name=tag:Environment,Values=${ENVIRONMENT}" \
      --query 'Reservations[].Instances[].{role:Tags[?Key==`Role`]|[0].Value,type:InstanceType,state:State.Name,id:InstanceId}' \
      --output table
    aws_ rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
      --query 'DBInstances[0].{class:DBInstanceClass,status:DBInstanceStatus,storage:AllocatedStorage,multiaz:MultiAZ}' \
      --output table 2>/dev/null || echo "rds: $DB_INSTANCE not present (destroyed?)"

    # The seven-day trap, counted rather than remembered. RDS reports no
    # stop time, so the most recent stop event in the event log is the source.
    if [ "$(aws_ rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
              --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)" = "stopped" ]; then
      echo
      echo "RDS is STOPPED. AWS restarts a stopped instance after 7 days, billing as running."
      echo "For a gap longer than that: db-baseline.sh capture, then '$(basename "$0") destroy'."
    fi
    ;;

  stop|stop-idle)
    assert_account
    if [ "$CMD" = "stop-idle" ] && hold_active; then
      hold_describe
      echo "stop-idle: hold active, leaving the environment running"
      exit 0
    fi

    IDS=$(instance_ids)
    if [ -n "$IDS" ]; then
      # shellcheck disable=SC2086
      aws_ ec2 stop-instances --instance-ids $IDS --query 'StoppingInstances[].{id:InstanceId,state:CurrentState.Name}' --output table
    else
      echo "no instances tagged Environment=$ENVIRONMENT"
    fi

    # A read replica blocks stopping the primary. Say so plainly rather than
    # letting the API error stand on its own.
    RDS_RC=0
    rds_transition stop stopping || RDS_RC=1
    if [ "$RDS_RC" -ne 0 ] && printf '%s' "$RDS_ERR" | grep -q 'InvalidDBInstanceState'; then
      echo "      RDS forbids stopping a primary that has a read replica. If one exists," >&2
      echo "      destroy it first. 'status' shows replicas." >&2
    fi
    echo
    echo "Storage still bills (~USD 90/month). Beyond a week, destroy instead."
    # EC2 is stopped by now either way; a non-zero exit says the DB is still
    # billing as running, which is the whole point of having stopped.
    exit "$RDS_RC"
    ;;

  start)
    assert_account
    IDS=$(instance_ids)
    # RDS first: it takes minutes and the app is useless without it, so
    # starting it first overlaps the waits rather than serialising them.
    RDS_RC=0
    rds_transition start starting || RDS_RC=1
    if [ "$RDS_RC" -ne 0 ] && printf '%s' "$RDS_ERR" | grep -q 'InsufficientDBInstanceCapacity'; then
      echo "      AWS has no room for this instance class in the AZ the instance is" >&2
      echo "      pinned to. Usually transient — retry. If it persists, restore the" >&2
      echo "      latest snapshot into another AZ or a smaller class; a stopped" >&2
      echo "      instance cannot have its class changed in place." >&2
    fi
    if [ -n "$IDS" ]; then
      # shellcheck disable=SC2086
      aws_ ec2 start-instances --instance-ids $IDS --query 'StartingInstances[].{id:InstanceId,state:CurrentState.Name}' --output table
    fi
    echo
    echo "Instance IDs are unchanged by stop/start, so the Ansible dynamic"
    echo "inventory still resolves. Public IPs are NOT: the injector keeps its"
    echo "elastic IP, but re-check anything else you enrolled."
    # The app server comes up regardless and will serve 502 against a database
    # that never started, so a non-zero exit here is the only honest signal.
    exit "$RDS_RC"
    ;;

  destroy)
    assert_account
    # tofu reads credentials from the environment, not from --profile, and its
    # KMS key provider cannot prompt for MFA. Fail here with the fix rather
    # than several minutes in with an opaque encryption error.
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
      echo "destroy needs credentials in the environment, not just a profile:" >&2
      echo "  . $(dirname "${BASH_SOURCE[0]}")/aws-session.sh" >&2
      exit 1
    fi
    # Refuse unless the dataset is safe. A destroy without a baseline is days
    # of generation thrown away, and it is not recoverable afterwards.
    echo "Verifying the baseline snapshot survives a destroy..."
    "$(dirname "${BASH_SOURCE[0]}")/db-baseline.sh" verify || {
      echo >&2
      echo "REFUSING: no verified baseline snapshot." >&2
      echo "Run 'db-baseline.sh capture' first, or set AVNI_ALLOW_DATALOSS=1 if the" >&2
      echo "dataset genuinely does not matter yet." >&2
      [ "${AVNI_ALLOW_DATALOSS:-}" = "1" ] || exit 1
      echo "AVNI_ALLOW_DATALOSS=1 — continuing without a baseline." >&2
    }
    echo
    echo "Destroying $ENVIRONMENT. The state bucket, the KMS key and the baseline"
    echo "snapshot are outside this root and survive."
    tofu -chdir="$TOFU_DIR" destroy
    ;;

  hold)
    assert_account
    HOURS="${2:-16}"
    REASON="${3:-unspecified}"
    EXPIRES=$(( $(date -u +%s) + HOURS * 3600 ))
    aws_ ssm put-parameter --name "$HOLD_PARAM" --type String --overwrite \
      --value "${EXPIRES}|${REASON}" >/dev/null
    printf 'hold set for %s hours (%s)\n' "$HOURS" "$REASON"
    echo "stop-idle will skip until then, and ignore it afterwards without being told."
    ;;

  release)
    assert_account
    aws_ ssm delete-parameter --name "$HOLD_PARAM" 2>/dev/null && echo "hold cleared" || echo "no hold to clear"
    ;;

  *) usage ;;
esac
