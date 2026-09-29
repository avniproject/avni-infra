#!/usr/bin/env bash
# Create the public hosted zone for the load-test environment. Run once, before
# the first `tofu apply`, and never again.
#
# WHY THIS IS NOT IN THE OPENTOFU MODULE
#   The zone used to be a module resource, which meant `tofu destroy` took it.
#   That is wrong in a way that only shows up on the REBUILD: a new zone gets
#   NEW name servers, the NS delegation sitting in the production account still
#   points at the old four, the name resolves nowhere, and
#   aws_acm_certificate_validation then hangs for ~75 minutes before failing.
#   The environment would look broken; the cause would be two accounts apart.
#
#   So the zone joins the state bucket, the KMS key and the baseline snapshot as
#   a thing that OUTLIVES the environment. The module reads it with a data
#   source and never owns it. Destroy and rebuild as often as you like; the
#   delegation stays valid because the name servers never change.
#
# THE DELEGATION IS MANUAL AND LIVES IN ANOTHER ACCOUNT
#   avniproject.org is in the production account (118388513628); this zone is in
#   the load-test account. Nothing here can write that NS record. This script
#   prints exactly what to add, once.
set -euo pipefail

PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
ZONE="${AVNI_ZONE_NAME:-loadtest.avniproject.org}"
EXPECT_ACCOUNT=936573213727
PROD_ACCOUNT=118388513628

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  aws_() { aws "$@"; }
else
  aws_() { aws "$@" --profile "$PROFILE"; }
fi

ACCOUNT=$(aws_ sts get-caller-identity --query Account --output text)
echo "account: $ACCOUNT"
if [ "$ACCOUNT" = "$PROD_ACCOUNT" ]; then
  echo "REFUSING: this resolves to PRODUCTION ($PROD_ACCOUNT)." >&2
  echo "The zone belongs in the load-test account; the DELEGATION goes in production." >&2
  exit 1
fi
[ "$ACCOUNT" = "$EXPECT_ACCOUNT" ] || { echo "REFUSING: not the load-test account." >&2; exit 1; }

# Idempotent. A second zone with the same name is legal in Route53 and would be
# a disaster -- two zones, two sets of name servers, one delegation, and
# resolution that depends on which one the delegation happens to point at.
# The public/private split is filtered in the shell, not in JMESPath. The
# obvious `HostedZones[?Name=='x.'&&!Config.PrivateZone]` returns NOTHING
# against a public zone whose Config.PrivateZone is False -- the CLI's JMESPath
# does not negate it the way it reads, verified against the live account.
#
# That bug is far worse HERE than anywhere else: an empty result reads as "no
# zone exists", and this script would then have created a SECOND zone with the
# same name -- exactly the duplicate the comment below warns about, caused by
# the guard meant to prevent it.
ID=$(aws_ route53 list-hosted-zones-by-name --dns-name "$ZONE" \
      --query "HostedZones[?Name=='${ZONE}.'].[Id,Config.PrivateZone]" --output text \
      | awk '$2=="False"{print $1; exit}')

if [ -n "$ID" ] && [ "$ID" != "None" ]; then
  echo "zone exists: $ID (reusing; NOT creating a second one)"
else
  echo "creating public zone $ZONE"
  ID=$(aws_ route53 create-hosted-zone --name "$ZONE" \
        --caller-reference "avni-loadtest-$(date -u +%s)" \
        --hosted-zone-config "Comment=Public zone for avni-loadtest; outlives the environment,PrivateZone=false" \
        --query 'HostedZone.Id' --output text)
  echo "created: $ID"
fi

echo
echo "Delegate it. In the PRODUCTION account (${PROD_ACCOUNT}), add an NS record"
echo "set for ${ZONE} in the avniproject.org zone, with these values:"
echo
aws_ route53 get-hosted-zone --id "$ID" --query 'DelegationSet.NameServers' --output text | tr '\t' '\n' | sed 's/^/  /'
echo
echo "Until that exists the name resolves nowhere and the ACM certificate stays"
echo "pending -- an apply will time out rather than fail fast. Verify with:"
echo "  dig +short NS ${ZONE}"
