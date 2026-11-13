#!/usr/bin/env bash
# Exercise configure/scripts/ssm-ssh-proxy.sh against stubbed aws, curl, dpkg and
# session-manager-plugin. Its stdout is the SSH stream, so every case also checks
# that nothing but the stream reaches stdout.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROXY="$ROOT/configure/scripts/ssm-ssh-proxy.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS $1"; pass=$((pass+1));
          else echo "  FAIL $1: got [$2] want [$3]"; fail=$((fail+1)); fi; }

# One sandbox per case: a stub bin dir, a call log, a scratch dir.
setup() {
  T=$(mktemp -d); mkdir -p "$T/bin" "$T/withplugin"
  LOG="$T/calls"; : > "$LOG"
  cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *"ec2 describe-instances"*) echo "ap-south-1a" ;;
  *"ssm start-session"*) echo "STREAM" ;;
  *"send-ssh-public-key"*) echo '{"Success": true}' ;;
esac
EOF
  cat > "$T/withplugin/session-manager-plugin" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  # curl and dpkg for the CircleCI bootstrap: dpkg -x lays down a fake plugin.
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$LOG"; out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done; : > "$out"
EOF
  cat > "$T/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
echo "dpkg $*" >> "$LOG"; d="$3/usr/local/sessionmanagerplugin/bin"; mkdir -p "$d"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/session-manager-plugin"; chmod +x "$d/session-manager-plugin"
EOF
  chmod +x "$T"/bin/* "$T/withplugin/session-manager-plugin"
  export LOG
  BASEPATH="$T/bin:/usr/bin:/bin"
}
run() { env -i HOME="$T" PATH="$1" LOG="$LOG" AVNI_SSMP_DIR="$T/ssmp" "${@:2}" bash "$PROXY" i-0123456789abcdef0; }

echo "1. laptop, no key file: one start-session through the SSH document, nothing else"
setup
out=$(run "$T/withplugin:$BASEPATH" AVNI_SSH_PUBKEY="$T/none.pub" 2>/dev/null); rc=$?
check "exit 0" "$rc" 0
check "stdout is only the stream" "$out" "STREAM"
check "no key push" "$(grep -c send-ssh-public-key "$LOG")" 0
check "SSH document on port 22" "$(grep -c 'ssm start-session --region ap-south-1 --target i-0123456789abcdef0 --document-name AWS-StartSSHSession --parameters portNumber=22' "$LOG")" 1

echo "2. key file present (CircleCI): key pushed for the right user and zone, then the session"
setup; echo "ssh-rsa AAAA test" > "$T/k.pub"
out=$(run "$T/withplugin:$BASEPATH" AVNI_SSH_PUBKEY="$T/k.pub" 2>/dev/null); rc=$?
check "exit 0" "$rc" 0
check "stdout is only the stream" "$out" "STREAM"
check "key pushed once" "$(grep -c send-ssh-public-key "$LOG")" 1
check "pushed to ubuntu in the instance's zone" "$(grep -c -- '--availability-zone ap-south-1a --instance-os-user ubuntu' "$LOG")" 1
check "push before session" "$(grep -n -e send-ssh -e start-session "$LOG" | cut -d: -f1 | tr '\n' ' ')" "2 3 "

echo "3. no plugin on a laptop: refuses, says why on stderr, stdout empty, no AWS call"
setup
out=$(run "$BASEPATH" 2>"$T/err"); rc=$?
check "exit non-zero" "$([ $rc -ne 0 ] && echo yes)" yes
check "stdout empty" "$out" ""
check "names the plugin" "$(grep -c session-manager-plugin "$T/err")" 1
check "no AWS call" "$(grep -c '^aws' "$LOG")" 0

echo "4. no plugin under CircleCI: fetched once, stdout still only the stream"
setup
out=$(run "$BASEPATH" CIRCLECI=true 2>/dev/null); rc=$?
check "exit 0" "$rc" 0
check "stdout is only the stream" "$out" "STREAM"
check "downloaded once" "$(grep -c '^curl' "$LOG")" 1
out=$(run "$BASEPATH" CIRCLECI=true 2>/dev/null)
check "second run reuses it" "$(grep -c '^curl' "$LOG")" 1

echo "5. a named profile is used only when no keys are exported"
setup
run "$T/withplugin:$BASEPATH" AVNI_AWS_PROFILE=ops >/dev/null 2>&1
check "profile passed" "$(grep -c -- '--profile ops' "$LOG")" 1
setup
run "$T/withplugin:$BASEPATH" AVNI_AWS_PROFILE=ops AWS_ACCESS_KEY_ID=x >/dev/null 2>&1
check "exported keys win" "$(grep -c -- '--profile' "$LOG")" 0

echo "6. no instance id: refuses"
setup
out=$(env -i HOME="$T" PATH="$T/withplugin:$BASEPATH" LOG="$LOG" bash "$PROXY" 2>/dev/null); rc=$?
check "exit non-zero" "$([ $rc -ne 0 ] && echo yes)" yes
check "no AWS call" "$(grep -c '^aws' "$LOG")" 0

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
