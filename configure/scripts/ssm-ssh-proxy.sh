#!/usr/bin/env bash
# SSH ProxyCommand that carries SSH over AWS Session Manager, so a server needs no
# inbound port 22 from the internet. Used by the staging, prerelease and prod
# inventories (ProxyCommand="... ssm-ssh-proxy.sh <instance id>"), from laptops
# and from CircleCI deploys.
#
# Authorisation is IAM: ssm:StartSession on the instance with AWS-StartSSHSession.
# The SSH key is then checked by the server as usual:
#   - laptops use the key in the inventory (the shared infra key, kept inside AWS);
#   - CircleCI makes a throwaway key and sets AVNI_SSH_PUBKEY; it is pushed with
#     EC2 Instance Connect on every connection, so its 60-second life never
#     runs out mid-play.
#
# stdout carries the SSH stream: nothing else may be written to it.
set -euo pipefail

INSTANCE_ID="${1:-}"
if [ -z "$INSTANCE_ID" ]; then
  echo "ssm-ssh-proxy: usage: ssm-ssh-proxy.sh <instance id>" >&2
  exit 2
fi
REGION="${AVNI_AWS_REGION:-ap-south-1}"
OS_USER="${AVNI_SSH_USER:-ubuntu}"
PUBKEY="${AVNI_SSH_PUBKEY:-/tmp/temp_rsa_key.pub}"
SSMP_DIR="${AVNI_SSMP_DIR:-/tmp/ssmp}"
SSMP_BIN="$SSMP_DIR/usr/local/sessionmanagerplugin/bin"
SSMP_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/1.2.896.0/ubuntu_64bit/session-manager-plugin.deb"

# Name a profile only when no keys are exported (same rule as eice-ssh-proxy.sh):
# --profile would override exported credentials, and a ProxyCommand has no
# terminal to answer an MFA prompt on.
if [ -n "${AVNI_AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  set -- --profile "$AVNI_AWS_PROFILE" --region "$REGION"
else
  set -- --region "$REGION"
fi

# The AWS CLI needs session-manager-plugin. On a laptop, install it once (see the
# staff guide). On CircleCI, fetch it into /tmp; parallel Ansible connections
# share one copy, guarded by a mkdir lock (portable, unlike flock).
if ! command -v session-manager-plugin >/dev/null 2>&1; then
  if [ -x "$SSMP_BIN/session-manager-plugin" ]; then
    :
  elif [ "${CIRCLECI:-}" = true ]; then
    until mkdir "$SSMP_DIR.lock" 2>/dev/null; do sleep 1; done
    trap 'rmdir "$SSMP_DIR.lock" 2>/dev/null || true' EXIT
    if [ ! -x "$SSMP_BIN/session-manager-plugin" ]; then
      curl -fsSL -o "$SSMP_DIR.deb" "$SSMP_URL" >&2
      dpkg -x "$SSMP_DIR.deb" "$SSMP_DIR" >&2
    fi
    rmdir "$SSMP_DIR.lock"; trap - EXIT
  else
    echo "ssm-ssh-proxy: session-manager-plugin is not installed; see 'How to reach AWS' in the staff guide" >&2
    exit 1
  fi
  export PATH="$SSMP_BIN:$PATH"
fi

if [ -f "$PUBKEY" ]; then
  AZ=$(aws ec2 describe-instances "$@" --instance-ids "$INSTANCE_ID" \
         --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
  aws ec2-instance-connect send-ssh-public-key "$@" --instance-id "$INSTANCE_ID" \
    --availability-zone "$AZ" --instance-os-user "$OS_USER" \
    --ssh-public-key "file://$PUBKEY" >/dev/null
fi

exec aws ssm start-session "$@" --target "$INSTANCE_ID" \
  --document-name AWS-StartSSHSession --parameters portNumber=22
