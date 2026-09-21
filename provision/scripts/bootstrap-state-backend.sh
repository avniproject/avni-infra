#!/usr/bin/env bash
# Wave 3: create the OpenTofu state backend for the load-test environment.
# Plan tasks 0.3-0.5 (issue #103). Run once, before the first `tofu init`.
#
# CREATES EXACTLY TWO THINGS, both new:
#   1. a KMS key (alias/avni-tofu-state) for state and plan encryption
#   2. an S3 bucket for state — versioned, SSE-KMS, TLS-only, no public access
#
# Task 0.4 needs nothing: OpenTofu 1.12 locks natively in S3 (use_lockfile),
# so there is no DynamoDB table.
#
# Safe to re-run. An existing key or bucket is detected and reused, and the
# settings are re-applied idempotently.
set -euo pipefail

PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
REGION="${AVNI_AWS_REGION:-ap-south-1}"
CLIENT="${AVNI_CLIENT:-Tanuh}"
PROD_ACCOUNT=118388513628
ALIAS="alias/avni-tofu-state"

# A function rather than an unquoted variable of flags: zsh does not word-split
# unquoted parameter expansions the way bash does, and a script that behaves
# differently under `zsh script.sh` than `./script.sh` is a trap.
aws_() { aws "$@" --profile "$PROFILE" --region "$REGION"; }
awsg_() { aws "$@" --profile "$PROFILE"; }   # global services: s3api, iam, sts

# ---------------------------------------------------- verify, and guard hard
CALLER=$(awsg_ sts get-caller-identity --output json)
ACCOUNT=$(printf '%s' "$CALLER" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Account"])')
echo "profile: $PROFILE"
echo "account: $ACCOUNT"
echo "caller:  $(printf '%s' "$CALLER" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Arn"])')"

if [ "$ACCOUNT" = "$PROD_ACCOUNT" ]; then
  echo >&2
  echo "REFUSING TO CONTINUE: this profile resolves to PRODUCTION ($PROD_ACCOUNT)." >&2
  exit 1
fi
echo "guard ok — not the production account"
echo

# ------------------------------------------------ account inventory, ADVISORY
# Deliberately non-fatal. Earlier versions ran this first under `set -o
# pipefail` and aborted the whole script when EC2 returned OptInRequired on a
# still-activating account — even though KMS and S3, which is all this script
# actually needs, were available the whole time. Informational checks must not
# block the work.
echo "=== account inventory (advisory; failures here do not stop the bootstrap) ==="
aws_ ec2 describe-vpcs --query 'Vpcs[].{id:VpcId,cidr:CidrBlock,default:IsDefault}' \
  --output table 2>&1 | head -8 || true
for q in "ec2:L-1216C47A:on-demand vCPUs" "rds:L-7B6409FD:RDS instances" \
         "vpc:L-F678F1CE:VPCs per region" "ec2:L-0263D0A3:Elastic IPs"; do
  SVC=${q%%:*}; REST=${q#*:}; CODE=${REST%%:*}; DESC=${REST#*:}
  VAL=$(aws_ service-quotas get-service-quota --service-code "$SVC" \
          --quota-code "$CODE" --query 'Quota.Value' --output text 2>/dev/null || echo "?")
  printf "  %-24s %s\n" "$DESC" "$VAL"
done
echo

# -------------------------------------------------------------------- KMS key
if aws_ kms describe-key --key-id "$ALIAS" >/dev/null 2>&1; then
  echo "KMS: $ALIAS exists, reusing"
else
  KEY_ID=$(aws_ kms create-key \
    --description "OpenTofu state and plan encryption - Avni load-test" \
    --key-usage ENCRYPT_DECRYPT --key-spec SYMMETRIC_DEFAULT \
    --tags "TagKey=Client,TagValue=$CLIENT" \
           "TagKey=Environment,TagValue=loadtest" \
           "TagKey=ManagedBy,TagValue=manual-bootstrap" \
    --query 'KeyMetadata.KeyId' --output text)
  aws_ kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY_ID"
  aws_ kms enable-key-rotation --key-id "$KEY_ID"
  echo "KMS: created $KEY_ID"
fi
KEY_ARN=$(aws_ kms describe-key --key-id "$ALIAS" --query 'KeyMetadata.Arn' --output text)

# --------------------------------------------------------------- state bucket
BUCKET="avni-tofu-state-${ACCOUNT}"   # S3 names are global; change if taken

if awsg_ s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "S3: $BUCKET exists, reusing"
else
  aws_ s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  echo "S3: created $BUCKET"
fi

awsg_ s3api put-bucket-tagging --bucket "$BUCKET" --tagging \
  "TagSet=[{Key=Client,Value=$CLIENT},{Key=Environment,Value=loadtest},{Key=ManagedBy,Value=manual-bootstrap}]"
awsg_ s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
awsg_ s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
awsg_ s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration "{
    \"Rules\": [{
      \"ApplyServerSideEncryptionByDefault\": {
        \"SSEAlgorithm\": \"aws:kms\", \"KMSMasterKeyID\": \"$KEY_ARN\"
      },
      \"BucketKeyEnabled\": true
    }]
  }"
awsg_ s3api put-bucket-policy --bucket "$BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"DenyInsecureTransport\", \"Effect\": \"Deny\", \"Principal\": \"*\",
    \"Action\": \"s3:*\",
    \"Resource\": [\"arn:aws:s3:::$BUCKET\", \"arn:aws:s3:::$BUCKET/*\"],
    \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}
  }]
}"
# Versioning is the state recovery path, but unbounded it just accumulates.
awsg_ s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-noncurrent-state-versions", "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }]
  }'
echo "S3: tagging, versioning, SSE-KMS, public-access-block, TLS-only policy and lifecycle applied"
echo
echo "Wire these into provision/tofu/envs/loadtest/versions.tf:"
echo "  bucket  = $BUCKET"
echo "  kms_arn = $KEY_ARN"
echo "  region  = $REGION"
