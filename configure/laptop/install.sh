#!/bin/sh
# One-time laptop setup: reach Avni servers and databases through AWS Session Manager with your own sign-in.
# Safe to run again. Mac and Linux (Windows: use WSL, or the browser shell and the database steps in the guide).
#   sh install.sh            set up
#   sh install.sh --check    only report what is missing
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CHECK=${1:-}
say() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { say "MISSING: $1. $2"; MISS=1; }; }
MISS=0
need aws "Install the AWS command line: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
need session-manager-plugin "Install the Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
need ssh "Install OpenSSH."
[ "$MISS" = 0 ] || { say "Install the missing tools, then run this again."; exit 1; }

# 1. AWS sign-in profiles: one sign-in covers every tile you have.
CFG="$HOME/.aws/config"; mkdir -p "$HOME/.aws"; touch "$CFG"
add_block() { grep -q "^\[$1\]" "$CFG" || { [ -n "$CHECK" ] && say "would add [$1] to $CFG" || { printf '\n[%s]\n%s\n' "$1" "$2" >> "$CFG"; say "added [$1] to $CFG"; }; }; }
add_block "sso-session samanvay" "sso_start_url = https://samanvay.awsapps.com/start
sso_region = ap-south-1
sso_registration_scopes = sso:account:access"
for p in "avni-nonprod AvniServersNonProd" "avni-prod AvniServersProd" "avni-readcopy AvniReadCopyTunnel"; do
  set -- $p
  add_block "profile $1" "sso_session = samanvay
sso_account_id = 118388513628
sso_role_name = $2
region = ap-south-1"
done

# 2. A laptop key used only for this. It is pushed to a server for 60 seconds on each connection; nothing is stored there.
[ -f "$HOME/.ssh/avni-ssm" ] || { [ -n "$CHECK" ] && say "would create ~/.ssh/avni-ssm" || { mkdir -p "$HOME/.ssh"; ssh-keygen -q -t ed25519 -N '' -C "avni-ssm $(whoami)" -f "$HOME/.ssh/avni-ssm"; say "created ~/.ssh/avni-ssm"; }; }

# 3. SSH config: the usual names (avni-staging, ssh.prod.avniproject.org, ...) go through Session Manager.
if [ -z "$CHECK" ]; then
  install -m 0644 "$HERE/avni.conf" "$HOME/.ssh/avni.conf"
  install -m 0755 "$HERE/avni-ssm-proxy.sh" "$HOME/.ssh/avni-ssm-proxy.sh"
  touch "$HOME/.ssh/config"
  if ! head -1 "$HOME/.ssh/config" | grep -q '^Include avni.conf'; then
    cp "$HOME/.ssh/config" "$HOME/.ssh/config.before-avni"
    { echo "Include avni.conf"; cat "$HOME/.ssh/config.before-avni"; } > "$HOME/.ssh/config"
    say "added 'Include avni.conf' to the top of ~/.ssh/config (old copy: ~/.ssh/config.before-avni)"
  fi
fi
if grep -nE '^[[:space:]]*Host .*(avni-(staging|prerelease|prod)|integration-(staging|prerelease|prod)|(ssh|int)[.-](staging|prerelease|prod))' "$HOME/.ssh/config" 2>/dev/null | grep -v avni.conf; then
  say "NOTE: the lines above are old entries for the same servers. avni.conf takes precedence; delete them when convenient."
fi

# 4. The database command.
BIN="$HOME/.local/bin"
if [ -z "$CHECK" ]; then mkdir -p "$BIN"; install -m 0755 "$HERE/avni-db" "$BIN/avni-db"; fi
case ":$PATH:" in *":$BIN:"*) ;; *) say "Add $BIN to your PATH to use avni-db (e.g. echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc)";; esac

say ""
say "Done. Daily:"
say "  ssh avni-staging                    (a browser tab opens to sign in when needed)"
say "  avni-db up readcopy                 (production read copy on localhost:15432)"
say "  avni-db status | avni-db down"
