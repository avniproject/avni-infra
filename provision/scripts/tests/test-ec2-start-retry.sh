#!/usr/bin/env bash
# Exercise ec2_start_retrying against a stubbed aws_, so the branch that only
# fires during a real capacity shortage can be tested on demand.
set -uo pipefail
ENVIRONMENT=loadtest
EC2_RETRY_SECONDS=3
EC2_RETRY_INTERVAL=1

# Pull the two functions out of the real script so the test cannot drift from it.
eval "$(sed -n '/^ec2_pending_ids()/,/^}/p;/^ec2_start_retrying()/,/^}/p' \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env-teardown.sh")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS $1 (rc=$2)"; pass=$((pass+1));
          else echo "  FAIL $1: got rc=$2 want $3"; fail=$((fail+1)); fi; }

echo "1. nothing stopped -> returns 0 without calling start"
ec2_pending_ids() { echo -n ""; }
aws_() { echo "START SHOULD NOT BE CALLED" >&2; return 1; }
out=$(ec2_start_retrying 2>&1); check "no-op" $? 0
echo "$out" | grep -q "already running or pending" && echo "    said so" || echo "    MISSING message"

echo "2. succeeds first attempt"
ec2_pending_ids() { echo "i-aaa i-bbb"; }
aws_() { echo "| i-aaa | pending |"; return 0; }
ec2_start_retrying >/dev/null 2>&1; check "first-try" $? 0

echo "3. capacity failure, then success -> retries and returns 0"
# The counter is a FILE, not a variable: ec2_start_retrying calls aws_ inside
# $( ), which is a subshell, so a variable increment is discarded.
CNT=$(mktemp); echo 0 > "$CNT"
ec2_pending_ids() { echo "i-aaa"; }
aws_() { n=$(( $(cat "$CNT") + 1 )); echo $n > "$CNT"
         if [ $n -lt 2 ]; then echo "An error occurred (InsufficientInstanceCapacity) when calling the StartInstances operation" >&2; return 255; fi
         echo "| i-aaa | pending |"; return 0; }
out=$(ec2_start_retrying 2>&1); check "retry-then-ok" $? 0
echo "$out" | grep -q "no capacity in the AZ (attempt 1)" && echo "    logged the retry" || echo "    MISSING retry log"

echo "4. capacity failure throughout -> gives up non-zero with guidance"
ec2_pending_ids() { echo "i-aaa"; }
aws_() { echo "An error occurred (InsufficientInstanceCapacity) when calling the StartInstances operation" >&2; return 255; }
out=$(ec2_start_retrying 2>&1); check "gave-up" $? 1
echo "$out" | grep -q "gave up after" && echo "    reported giving up" || echo "    MISSING give-up message"
echo "$out" | grep -q "Still stopped" && echo "    listed what is still stopped" || echo "    MISSING list"

echo "5. a DIFFERENT error -> fails immediately, no retry"
CNT=$(mktemp); echo 0 > "$CNT"
ec2_pending_ids() { echo "i-aaa"; }
aws_() { echo $(( $(cat "$CNT") + 1 )) > "$CNT"; echo "An error occurred (UnauthorizedOperation) when calling the StartInstances operation" >&2; return 255; }
out=$(ec2_start_retrying 2>&1); rc=$?; check "other-error" $rc 1
[ "$(cat "$CNT")" = "1" ] && echo "    called once, did not retry" || echo "    RETRIED a non-capacity error ($(cat "$CNT") calls)"
echo "$out" | grep -q "UnauthorizedOperation" && echo "    surfaced the real error" || echo "    SWALLOWED the error"

echo; echo "passed $pass, failed $fail"; [ "$fail" = "0" ]
