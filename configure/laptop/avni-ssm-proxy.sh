#!/bin/sh
# SSH ProxyCommand: avni-ssm-proxy.sh <aws profile> <instance id> <os user>
# Pushes this laptop's key to the server for 60 seconds, then carries SSH over
# Session Manager. stdout is the SSH stream: everything else goes to stderr.
set -eu
PROFILE=$1; ID=$2; OSUSER=${3:-ubuntu}; REGION=ap-south-1; KEY="$HOME/.ssh/avni-ssm"
[ -f "$KEY.pub" ] || { echo "avni: no key at $KEY. Run: ssh-keygen -t ed25519 -N '' -f $KEY" >&2; exit 1; }
aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1 || aws sso login --profile "$PROFILE" >&2
aws ec2-instance-connect send-ssh-public-key --profile "$PROFILE" --region "$REGION" \
  --instance-id "$ID" --instance-os-user "$OSUSER" --ssh-public-key "file://$KEY.pub" >/dev/null
exec aws ssm start-session --profile "$PROFILE" --region "$REGION" --target "$ID" \
  --document-name AWS-StartSSHSession --parameters portNumber=22
