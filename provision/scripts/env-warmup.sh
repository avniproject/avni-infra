#!/usr/bin/env bash
# Push one gentle pass of traffic through a freshly started app server, and
# throw the result away.
#
#   provision/scripts/env-warmup.sh            # waits for /ping, then warms
#   AVNI_SKIP_WARMUP=1 ...                     # skip entirely
#
# Run automatically by `env-teardown.sh start`. Safe to run by hand.
#
# WHY
#   A just-restarted avni-server delivers about a THIRD of its warm throughput.
#   Measured 5 Oct 2026, 100 devices over a 60 s window:
#
#     cold (JVM 2m49s old)   18.43 rps   p95 25,635 ms   9 timeouts
#     warm (20 min later)    50.00 rps   p95  2,767 ms   0 failures
#
#   It is the JVM, not the database: RDS ReadIOPS and ReadLatency were 0.0
#   throughout, so the buffer cache had already refilled, and the cold runs sat
#   at 99.2% app CPU buying less with it. avni-perf docs/findings-case1.md.
#
# WHY IT IS DISCARDED, NOT PUBLISHED
#   This deliberately runs ./gradlew rather than run-scenario.sh, so nothing
#   reaches the artefacts prefix. That mirrors avni-perf prepare-run.sh step 6,
#   whose point is that **warmth has to be produced, not declared**: all ten
#   runs of 5 Oct asserted `-DCACHE_POLICY=warm-incidental-no-reset`, including
#   the two it was false for, and nothing could contradict it. A discarded pass
#   makes the claim true before it is made. A published one would also put a
#   gentle, good-looking row in the run log belonging to no curve.
#
# HOW LONG, AND WHY IT DIFFERS FROM STEP 6
#   prepare-run.sh step 6 specifies BURST_SECONDS=900 -- 4,300 requests at ~5
#   rps, fifteen minutes, matching the accidental warm-up of 5 Oct. That is
#   right before a measured campaign and too slow to sit in every start, so the
#   default here is 180 s: the SAME 4,300 requests at ~22.75 rps, which is still
#   comfortably below the knee (the knee's left edge is 90 s), in about three
#   and a half minutes.
#
#   **The minimum sufficient warm-up is unmeasured.** 4,300 requests is the only
#   volume known to work; nothing establishes that delivering them faster warms
#   as well. Before a campaign whose numbers matter, prefer step 6 and set
#   AVNI_WARMUP_BURST_SECONDS=900.
set -uo pipefail

[ "${AVNI_SKIP_WARMUP:-0}" = "1" ] && { echo "warm-up: skipped (AVNI_SKIP_WARMUP=1)"; exit 0; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
REGION="${AVNI_AWS_REGION:-ap-south-1}"
BASE_URL="${AVNI_BASE_URL:-https://loadtest.avniproject.org}"
PROXY="${AVNI_EICE_PROXY:-$HERE/../../configure/scripts/eice-ssh-proxy.sh}"
WAIT="${AVNI_WARMUP_WAIT:-600}"
BURST="${AVNI_WARMUP_BURST_SECONDS:-180}"
USERS="${AVNI_WARMUP_USERS:-100}"
HOME_DIR="${AVNI_INJECTOR_HOME:-/opt/avni-perf}"

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then aws_() { aws "$@" --region "$REGION"; }
else aws_() { aws "$@" --profile "$PROFILE" --region "$REGION"; }; fi

# A warm-up must never be the reason a start reports failure: the environment is
# up either way and can be warmed by hand. Every exit below is 0.
warn() { echo "warm-up: $*" >&2; exit 0; }

INJ=$(aws_ ec2 describe-instances \
  --filters "Name=tag:Environment,Values=loadtest" "Name=tag:Role,Values=injector" \
            "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
[ -n "$INJ" ] && [ "$INJ" != "None" ] || warn "no injector running — nothing to warm from. Skipped."

echo "warm-up: waiting for ${BASE_URL}/ping (up to ${WAIT}s)"
START=$(date +%s)
while :; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE_URL}/ping" 2>/dev/null)
  [ "$CODE" = "200" ] && break
  ELAPSED=$(( $(date +%s) - START ))
  [ "$ELAPSED" -ge "$WAIT" ] && warn "/ping still $CODE after ${ELAPSED}s. Not warmed."
  sleep 15
done
echo "warm-up: /ping 200 after $(( $(date +%s) - START ))s"

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ProxyCommand="$PROXY %h" "ubuntu@$INJ")

"${SSH[@]}" "test -d '$HOME_DIR/harness'" 2>/dev/null \
  || warn "injector has no $HOME_DIR/harness — run loadtest_injector.yml first. Skipped."

echo "warm-up: ${USERS} devices over ${BURST}s against ${BASE_URL} (discarded)"
# JAVA_HOME is globbed for the same reason roles/avni_injector globs it: Java 8
# owns the `java` alternative on this host and the Gatling plugin needs 11+.
# The architecture is in the path, so it cannot be hardcoded either.
"${SSH[@]}" "set -e
  export GRADLE_USER_HOME='$HOME_DIR/.gradle'
  JH=\$(ls -d /usr/lib/jvm/java-17-openjdk-* 2>/dev/null | head -1)
  [ -n \"\$JH\" ] || { echo 'no java-17-openjdk-* under /usr/lib/jvm' >&2; exit 1; }
  export JAVA_HOME=\"\$JH\"
  cd '$HOME_DIR/harness'
  ./gradlew --no-daemon gatlingRun \
    -DBASE_URL='$BASE_URL' \
    -DPROFILE=burst \
    -DBURST_SECONDS=$BURST \
    -DSYNC_USERS=case1-users.csv \
    -DUSER_COUNT=$USERS \
    -DCACHE_POLICY=discarded-warmup" 2>&1 \
  | grep -aE '^(Profile|Sync mode):|^(request count|mean response time|mean throughput)|BUILD (SUCCESSFUL|FAILED)|error:' \
  || true

echo "warm-up: done, result discarded. Measured runs can start."
echo "         How long warm lasts is unmeasured: 20 min was warm, 2m49s was not."
exit 0
