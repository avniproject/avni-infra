#!/usr/bin/env bash
#
# Let the existing Tanuh EC2 instance role pull the tanuh-superset image.
#
# The host pulls images via the amazon-ecr-credential-helper using its instance
# role (tanuh-metabase-ec2-role). That role's existing `tanuh-ecr-pull` inline
# policy is scoped to the tanuh-metabase repo only. Rather than edit it, we add a
# SECOND inline policy `tanuh-superset-ecr-pull` scoped to the superset repo, so
# the Metabase pull policy is left untouched.
#
# Idempotent: put-role-policy overwrites the named policy if it already exists.
#
# Usage:  bash aws_ec2_pull_grant.sh
#
set -euo pipefail

REGION=${REGION:-ap-south-1}
EC2_ROLE_NAME=${EC2_ROLE_NAME:-tanuh-metabase-ec2-role}
POLICY_NAME=${POLICY_NAME:-tanuh-superset-ecr-pull}
ECR_REPO_NAME=avniproject/tanuh-superset
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log() { echo "[ec2_pull_grant] $*"; }

cat > /tmp/superset-ec2-pull.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuthorize",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPullTanuhSuperset",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
    }
  ]
}
JSON

log "Attaching inline policy $POLICY_NAME to $EC2_ROLE_NAME..."
aws iam put-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file:///tmp/superset-ec2-pull.json
rm -f /tmp/superset-ec2-pull.json

log "Done. The Tanuh EC2 can now pull ${ECR_REPO_NAME}."
log "Rollback: aws iam delete-role-policy --role-name $EC2_ROLE_NAME --policy-name $POLICY_NAME"
