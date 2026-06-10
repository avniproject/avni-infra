#!/usr/bin/env bash
#
# One-time AWS setup to UNBLOCK CI for the public build repo avniproject/tanuh-superset.
#
# Provisions exactly two things:
#   1. ECR repository  avniproject/tanuh-superset  (scanOnPush)
#   2. GitHub Actions IAM role  tanuh-superset-gha-role  (OIDC trust + ECR-push only)
#
# The role holds NO credentials. At CI time, GitHub Actions presents an OIDC token;
# AWS STS verifies it against the role's trust policy and returns short-lived creds
# (~1h). Nothing long-lived is ever stored in GitHub.
#
# Mirrors reportingSystem/tanuh-metabase/{aws_setup.sh,gha-trust-policy.json,
# gha-ecr-policy.json} (steps 1 + 3), scoped to the tanuh-superset repo.
#
# NOT idempotent: a second run aborts on "already exists" instead of duplicating.
# Roll back with aws_ci_teardown.sh.
#
# Prereqs: aws CLI v2 with admin in the avni account (118388513628), region ap-south-1.
#
# Usage:   bash aws_ci_setup.sh
#
set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
REGION=${REGION:-ap-south-1}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO_NAME=avniproject/tanuh-superset
GHA_ROLE_NAME=tanuh-superset-gha-role
GHA_POLICY_NAME=tanuh-ecr-push
# The public build repo whose CI assumes the role:
GH_REPO=avniproject/tanuh-superset
# Default branch (workflow_dispatch runs) + release tags (push trigger):
GH_DEFAULT_BRANCH=main

export ACCOUNT_ID REGION

log() { echo "[ci_setup] $*"; }

# --------------------------------------------------------------------------
# 1. ECR repository
# --------------------------------------------------------------------------
log "Creating ECR repository $ECR_REPO_NAME..."
ECR_ARN=$(aws ecr create-repository --region "$REGION" \
  --repository-name "$ECR_REPO_NAME" \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability MUTABLE \
  --tags Key=Project,Value=tanuh-superset Key=Client,Value=tanuh Key=ManagedBy,Value=aws_ci_setup.sh \
  --query 'repository.repositoryArn' --output text)
log "  ECR repo: $ECR_ARN"

# --------------------------------------------------------------------------
# 2. GitHub OIDC provider (shared; create only if absent)
# --------------------------------------------------------------------------
log "Ensuring GitHub OIDC identity provider exists..."
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" \
  --output text)
if [[ "$OIDC_ARN" == "None" || -z "$OIDC_ARN" ]]; then
  log "  Creating OIDC provider..."
  OIDC_ARN=$(aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
    --query 'OpenIDConnectProviderArn' --output text)
fi
log "  OIDC provider: $OIDC_ARN"

# --------------------------------------------------------------------------
# 3. GitHub Actions IAM role (trust + ECR-push)
# --------------------------------------------------------------------------
log "Creating GitHub Actions IAM role $GHA_ROLE_NAME..."

# Trust policy: only the tanuh-superset repo, only release tags (v*) and the
# default branch (for manual workflow_dispatch). Tighter than the metabase role.
cat > /tmp/superset-gha-trust.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:${GH_REPO}:ref:refs/tags/v*",
            "repo:${GH_REPO}:ref:refs/heads/${GH_DEFAULT_BRANCH}"
          ]
        }
      }
    }
  ]
}
JSON

aws iam create-role \
  --role-name "$GHA_ROLE_NAME" \
  --assume-role-policy-document file:///tmp/superset-gha-trust.json \
  --tags Key=Project,Value=tanuh-superset Key=Client,Value=tanuh Key=ManagedBy,Value=aws_ci_setup.sh \
  --output text > /dev/null
rm -f /tmp/superset-gha-trust.json

# Push-only permissions, scoped to the one ECR repo (GetAuthorizationToken must be *).
cat > /tmp/superset-gha-ecr.json <<JSON
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
      "Sid": "EcrPushTanuhSuperset",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$GHA_ROLE_NAME" \
  --policy-name "$GHA_POLICY_NAME" \
  --policy-document file:///tmp/superset-gha-ecr.json
rm -f /tmp/superset-gha-ecr.json

GHA_ROLE_ARN=$(aws iam get-role --role-name "$GHA_ROLE_NAME" \
  --query 'Role.Arn' --output text)

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
cat <<DONE

[ci_setup] Done.
  ECR repo : ${ECR_ARN}
  GHA role : ${GHA_ROLE_ARN}

Next steps (in the public repo avniproject/tanuh-superset):
  1. Set AWS_ROLE_ARN in .github/workflows/build-and-push.yml to:
       ${GHA_ROLE_ARN}
  2. Uncomment the tag trigger:
       on:
         push:
           tags: ['v*']
  3. Bump VERSION + push tag v<VERSION> (e.g. v6.0.0-tanuh-1) to fire the build.

NOTE (separate, deploy-side — NOT done here): the deploy host pulls this image.
Extend the existing EC2 pull role 'tanuh-metabase-ec2-role' (inline policy
'tanuh-ecr-pull') to also allow pull on:
  arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}
That belongs to the tanuh_superset ansible/deploy task in avni-infra#94.
DONE
