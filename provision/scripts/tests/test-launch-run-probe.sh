#!/usr/bin/env bash
# launch-run.sh must never kill a run it could not see.
#
# The bug this pins: the first version read the JVM's argv over ssh and treated
# an EMPTY result as "the properties are missing", then ran pkill. An empty
# result means the question could not be asked. On 9 Oct 2026 that fired while
# the instances were stopping, against a run that had already published.
#
# Kill state is recorded in a FILE, not a variable: the probe runs inside $( ),
# so a variable set by the stub would be discarded with the subshell. An
# earlier test in this directory passed against zero calls for exactly that.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../launch-run.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

mkssh() { # $1 = mode
  cat > "$WORK/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${@: -1}"
case "\$cmd" in
  *pkill*)        echo killed >> "$WORK/kills"; exit 0 ;;
  *pgrep*)        case "$1" in hang) sleep 60 ;; *) echo "__ARGV_OK__"; echo 1 ;; esac; exit 0 ;;
  *run-scenario*) echo launched; exit 0 ;;
esac
case "\$cmd" in
  *__ARGV_OK__*ps\ -eo*)
    case "$1" in
      good)    echo "__ARGV_OK__"; echo "java -DUSER_COUNT=400 -DPUSH=on -DSYNC_MODE=realistic x" ;;
      missing) echo "__ARGV_OK__"; echo "java -DUSER_COUNT=400 x" ;;
      silent)  : ;;                        # no sentinel: the probe did not answer
      hang)    sleep 60 ;;                   # never returns -- the 12 Oct incident
    esac; exit 0 ;;
  *__ARGV_OK__*Profile*)
    case "$1" in
      good)    echo "__ARGV_OK__"; echo "Profile: steady | 1600 syncs/hour for 15 min" ;;
      missing) echo "__ARGV_OK__"; echo "Profile: steady | 46 syncs/hour for 15 min" ;;
      silent)  : ;;
      hang)    sleep 60 ;;
    esac; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$WORK/ssh"
}

run() { # $1 mode, $2.. args
  local mode="$1"; shift
  mkssh "$mode"; rm -f "$WORK/kills"
  PATH="$WORK:$PATH" AVNI_EICE_PROXY=/bin/true AVNI_PROBE_TIMEOUT="${PROBE_T:-2}" \
    AVNI_RETRY_SLEEP=0 AVNI_JVM_WAIT_TRIES=3 AVNI_JVM_WAIT_SLEEP=0 \
    "$SCRIPT" "$@" >"$WORK/out" 2>&1
  echo $?
}
kills() { [ -f "$WORK/kills" ] && wc -l < "$WORK/kills" | tr -d ' ' || echo 0; }

check() { # $1 label, $2 want_rc, $3 want_kills, $4 got_rc
  local k; k=$(kills)
  if [ "$4" = "$2" ] && [ "$k" = "$3" ]; then
    echo "  PASS $1 (rc=$4, kills=$k)"; pass=$((pass+1))
  else
    echo "  FAIL $1 -- wanted rc=$2 kills=$3, got rc=$4 kills=$k"; sed 's/^/        /' "$WORK/out"; fail=$((fail+1))
  fi
}

echo "1. all properties present -> accepted, nothing killed"
rc=$(run good L -DUSER_COUNT=400 -DPUSH=on -DSYNC_MODE=realistic); check "accepted" 0 0 "$rc"

echo "2. a property missing -> killed"
rc=$(run missing L -DUSER_COUNT=400 -DPUSH=on -DSYNC_MODE=realistic); check "killed-on-missing" 1 1 "$rc"

echo "3. THE BUG: probe never answers -> must NOT kill"
rc=$(run silent L -DUSER_COUNT=400 -DPUSH=on -DSYNC_MODE=realistic); check "no-kill-on-silence" 3 0 "$rc"

echo "4. derived rate wrong though inputs present -> killed"
rc=$(AVNI_EXPECT_RATE="1600 syncs/hour" run missing L -DUSER_COUNT=400); check "killed-on-rate" 1 1 "$rc"

echo "5. newline in the property list -> refused before launching"
rc=$(run good L "$(printf -- '-DA=1\n-DB=2')"); check "refuse-newline" 2 0 "$rc"

echo "6. THE 12 OCT INCIDENT: the probe hangs -> bounded, and must NOT kill"
t0=$(date +%s)
rc=$(PROBE_T=2 run hang L -DUSER_COUNT=400 -DPUSH=on -DSYNC_MODE=realistic)
el=$(( $(date +%s) - t0 ))
check "no-kill-on-hang" 3 0 "$rc"
if [ "$el" -lt 20 ]; then
  echo "  PASS bounded-in-${el}s (unbounded, the stub sleeps 60s per call)"; pass=$((pass+1))
else
  echo "  FAIL took ${el}s -- the probe was not bounded"; fail=$((fail+1))
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
