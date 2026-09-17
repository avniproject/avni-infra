#!/usr/bin/env bash
# Create the OIDC provider and role CircleCI needs to deploy to the load-test
# account. Run ONCE, with credentials for the load-test account.
#
# WHY OIDC RATHER THAN AN ACCESS KEY
#   CircleCI mints a short-lived token per job and exchanges it for temporary
#   AWS credentials. Nothing long-lived is stored in CircleCI, so there is no
#   key to leak or rotate. The account already uses this pattern twice —
#   avni_circleci_instance_connect in production, and the GitHub Actions role
#   that reportingSystem/tanuh-metabase/aws_setup.sh creates.
#
#   It is also the only workable option here: the human profile for this
#   account is MFA-gated, and a CI job cannot present a second factor.
#
# WHAT YOU NEED FIRST
#   CIRCLECI_ORG_ID      CircleCI → Organization Settings → Overview
#   CIRCLECI_PROJECT_ID  CircleCI → Project Settings → Overview
set -euo pipefail

PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
ORG_ID="${CIRCLECI_ORG_ID:-}"
PROJECT_ID="${CIRCLECI_PROJECT_ID:-}"
ROLE="${AVNI_CI_ROLE:-avni-loadtest-circleci}"

[ -n "$ORG_ID" ] || { echo "CIRCLECI_ORG_ID is unset — see the header" >&2; exit 2; }
[ -n "$PROJECT_ID" ] || { echo "CIRCLECI_PROJECT_ID is unset — see the header" >&2; exit 2; }

ISSUER="oidc.circleci.com/org/${ORG_ID}"

# AWS no longer verifies thumbprints for providers behind well-known CAs, but
# the API still requires the parameter.
aws iam create-open-id-connect-provider --profile "$PROFILE" \
  --url "https://${ISSUER}" \
  --client-id-list "$ORG_ID" \
  --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" \
  2>/dev/null || echo "OIDC provider already exists, reusing"

ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)

cat > /tmp/ci-trust.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/${ISSUER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "${ISSUER}:aud": "${ORG_ID}" },
      "StringLike": {
        "${ISSUER}:sub": "org/${ORG_ID}/project/${PROJECT_ID}/user/*"
      }
    }
  }]
}
JSON

aws iam create-role --profile "$PROFILE" \
  --role-name "$ROLE" \
  --description "CircleCI deploys to the Avni load-test environment" \
  --max-session-duration 3600 \
  --assume-role-policy-document file:///tmp/ci-trust.json

# Narrower than the human role deliberately. CI only deploys: it pushes an
# ephemeral key through Instance Connect, opens a tunnel, and reads the jar
# from the environment bucket. It has no reason to create infrastructure —
# that stays with a human running OpenTofu.
cat > /tmp/ci-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DiscoverHostsByTag",
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
      "Resource": "*"
    },
    {
      "Sid": "TunnelToTaggedHosts",
      "Effect": "Allow",
      "Action": [
        "ec2-instance-connect:SendSSHPublicKey",
        "ec2-instance-connect:OpenTunnel"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:ResourceTag/Environment": "loadtest" }
      }
    },
    {
      "Sid": "ReadDeployables",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::avni-loadtest-${ACCOUNT}",
        "arn:aws:s3:::avni-loadtest-${ACCOUNT}/deployables/*"
      ]
    }
  ]
}
JSON

aws iam put-role-policy --profile "$PROFILE" \
  --role-name "$ROLE" \
  --policy-name "${ROLE}-deploy" \
  --policy-document file:///tmp/ci-policy.json

rm -f /tmp/ci-trust.json /tmp/ci-policy.json
echo
echo "role: arn:aws:iam::${ACCOUNT}:role/${ROLE}"
echo "Put that ARN in the LOADTEST_deploy job (see ci-circleci-job.yml)."
