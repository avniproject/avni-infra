#!/usr/bin/env bash
# Launch one avni-perf scenario on the injector and PROVE it is the scenario
# that was asked for before leaving it to run.
#
#   AVNI_AWS_PROFILE=avni-load-test ./provision/scripts/launch-run.sh \
#       case11-burst15 -DUSER_COUNT=400 -DSYNC_WINDOW_HOURS=0.25 ...
#
#   AVNI_EXPECT_RATE="1600 syncs/hour"   assert the DERIVED rate from the banner
#
# WHY THIS EXISTS. Two runs were lost on 9 Oct 2026 to properties that never
# reached the JVM, neither of which failed loudly:
#
#   * the property list was written across several lines, so the embedded
#     newlines ended the ssh command early. The JVM got two of nine properties,
#     defaulted SYNC_MODE to csv and PUSH to false, and the redirect that should
#     have captured the log was on a line that never ran.
#   * every property was present and correct, and the scenario was still wrong:
#     syncsPerHour = userCount / syncWindowHours and SYNC_WINDOW_HOURS defaults
#     to 12 HOURS, not the run's duration, so 550 users became 46 syncs/hour.
#
# Hence two checks: the JVM's own argv, and the DERIVED rate off the banner.
# Inputs being right does not make the scenario right.
#
# AND WHY IT DOES NOT KILL ON A FAILED PROBE. The first version of this check
# treated an empty `ps` result as "the properties are missing" and ran pkill.
# An empty result means the question could not be asked -- a dropped ssh, an
# instance stopping, a slow proxy -- and on 9 Oct that fired against a run that
# had already finished. A check meant to protect runs must not be able to kill
# one it simply could not see. The probe now carries a sentinel: no sentinel
# means no answer, which is retried and never fatal.
set -uo pipefail

LABEL="${1:?usage: $0 <label> [-Dkey=value ...]}"; shift
PROPS="$*"
case "$PROPS" in *$'\n'*)
  echo "launch-run: the property list contains a newline. Interpolated into the" >&2
  echo "            ssh command that ends it early -- pass them on one line." >&2
  exit 2;; esac

INJECTOR="${AVNI_INJECTOR_ID:-i-041afc7c6e0761195}"
HOME_DIR="${AVNI_INJECTOR_HOME:-/opt/avni-perf}"
PROXY="${AVNI_EICE_PROXY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../configure/scripts" && pwd)/eice-ssh-proxy.sh}"
SENTINEL="__ARGV_OK__"
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=25 -o ServerAliveInterval=30 -o ProxyCommand="$PROXY %h" "ubuntu@$INJECTOR")

echo "launch-run: $LABEL on $INJECTOR"
"${SSH[@]}" "cd $HOME_DIR && rm -f $LABEL.log && setsid nohup ./run-scenario.sh $LABEL $PROPS > $LABEL.log 2>&1 < /dev/null & sleep 3; echo launched" 2>/dev/null

# --- wait for the JVM ------------------------------------------------------
for _ in $(seq 1 30); do
  "${SSH[@]}" 'pgrep -f "[A]vniSyncSimulation" >/dev/null' 2>/dev/null && break
  sleep 10
done

# --- probe argv, with a sentinel so "no answer" is distinguishable ---------
# The sentinel is echoed by the REMOTE shell. If it is absent, the probe did
# not run -- which is not evidence about the run.
probe() {
  "${SSH[@]}" "echo $SENTINEL; ps -eo args | grep '[A]vniSyncSimulation' | head -1" 2>/dev/null
}
argv=""; got=0
for attempt in 1 2 3 4 5; do
  out=$(probe)
  case "$out" in
    *"$SENTINEL"*) argv="${out#*$SENTINEL}"; got=1; break ;;
  esac
  echo "launch-run: argv probe did not answer (attempt $attempt) -- retrying, NOT killing" >&2
  sleep 15
done

if [ "$got" -eq 0 ]; then
  echo "launch-run: could not read the JVM's argv after 5 attempts." >&2
  echo "            The run is LEFT ALONE -- an unanswered probe is not a failed one." >&2
  echo "            Verify by hand before trusting this run's numbers." >&2
  exit 3
fi

missing=""
for kv in $PROPS; do
  case "$kv" in -D*) ;; *) continue ;; esac
  case "$argv" in *"$kv"*) ;; *) missing="$missing ${kv#-D}" ;; esac
done

if [ -n "${AVNI_EXPECT_RATE:-}" ]; then
  banner=$("${SSH[@]}" "echo $SENTINEL; grep -aE '^Profile:' $HOME_DIR/$LABEL.log | head -1" 2>/dev/null)
  case "$banner" in
    *"$SENTINEL"*)
      b="${banner#*$SENTINEL}"
      echo "launch-run: ${b# }"
      case "$b" in *"$AVNI_EXPECT_RATE"*) ;; *) missing="$missing DERIVED_RATE($AVNI_EXPECT_RATE)";; esac ;;
    *) echo "launch-run: banner probe did not answer -- derived rate UNVERIFIED" >&2 ;;
  esac
fi

if [ -n "$missing" ]; then
  echo "launch-run: these never reached the JVM:$missing" >&2
  echo "launch-run: killing rather than measuring the wrong scenario" >&2
  "${SSH[@]}" 'pkill -f "[A]vniSyncSimulation"; pkill -f "[r]un-scenario.sh"' 2>/dev/null
  exit 1
fi

echo "launch-run: all properties confirmed in the JVM's own argv"
