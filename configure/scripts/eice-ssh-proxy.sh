#!/usr/bin/env bash
# SSH ProxyCommand for hosts with no public IP and no inbound rule.
#
# Two AWS calls, both required: send-ssh-public-key authorises a key on the
# instance for sixty seconds, and open-tunnel carries the session over the AWS
# API. Neither needs a route to the instance, which is the point — authorisation
# is IAM, not network position, so this works from a laptop or from CI without
# either being inside the VPC.
#
# Invoked by ansible_ssh_common_args with %h, which is the instance ID because
# the dynamic inventory sets hostnames: - instance-id.
set -euo pipefail

INSTANCE_ID="$1"
PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
REGION="${AVNI_AWS_REGION:-ap-south-1}"

# Name the profile ONLY when nothing is already in the environment. Passing
# --profile overrides exported credentials and sends the CLI back down the
# assume-role path that needs an MFA code it cannot ask for -- and this runs as
# an SSH ProxyCommand, where there is no terminal to ask on. Same rule as
# provision/scripts/aws-session.sh and its siblings.
# Positional args rather than a wrapper function: the last call below is
# exec'd, and exec cannot invoke a shell function -- it replaces the process
# with an external command. INSTANCE_ID is captured above before `set --`
# overwrites the positional parameters.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  set -- --region "$REGION"
else
  set -- --profile "$PROFILE" --region "$REGION"
fi
OS_USER="${AVNI_SSH_USER:-ubuntu}"
PUBKEY="${AVNI_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

if [ ! -f "$PUBKEY" ]; then
  echo "eice-ssh-proxy: no public key at $PUBKEY" >&2
  echo "  generate one (ssh-keygen -t ed25519) or set AVNI_SSH_PUBKEY" >&2
  exit 1
fi

AZ=$(aws ec2 describe-instances "$@" \
       --instance-ids "$INSTANCE_ID" \
       --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
       --output text)

aws ec2-instance-connect send-ssh-public-key "$@" \
  --instance-id "$INSTANCE_ID" \
  --instance-os-user "$OS_USER" \
  --availability-zone "$AZ" \
  --ssh-public-key "file://$PUBKEY" >/dev/null

exec aws ec2-instance-connect open-tunnel "$@" \
  --instance-id "$INSTANCE_ID"
