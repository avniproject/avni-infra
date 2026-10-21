#!/usr/bin/env bash
# Create the environment bucket. Run once, before the first `tofu apply`, and
# never again.
#
# WHY IT IS NOT IN THE OPENTOFU MODULE
#   It was, with force_destroy = true and the note "test artefacts; the
#   environment is disposable by design". That conflated the bucket with its
#   contents and defeated both of its own purposes.
#
#   deployables/ exists so a deploy never depends on whoever runs it having a
#   jar locally. Destroying the bucket reinstates that dependency, and every
#   rebuild then needs a 112 MB re-upload from someone's laptop.
#
#   artefacts/ exists because the harness needs an outbound path for
#   simulation.log, reports and run metadata, which a closed environment
#   otherwise lacks. Destroying the bucket takes the run results with it --
#   the output of the whole exercise.
#
#   So the bucket is an input and an output, not part of the environment. It
#   joins the state bucket, the KMS key, the hosted zone and the baseline
#   snapshot as something a destroy must not take.
#
# Safe to re-run: an existing bucket is reused and its settings re-applied.
set -euo pipefail

PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
REGION="${AVNI_AWS_REGION:-ap-south-1}"
ENVIRONMENT="${AVNI_ENVIRONMENT:-loadtest}"
EXPECT_ACCOUNT=936573213727
PROD_ACCOUNT=118388513628

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  aws_() { command aws "$@"; }
else
  aws_() { command aws "$@" --profile "$PROFILE"; }
fi

ACCOUNT=$(aws_ sts get-caller-identity --query Account --output text)
[ "$ACCOUNT" != "$PROD_ACCOUNT" ] || { echo "REFUSING: this is PRODUCTION." >&2; exit 1; }
[ "$ACCOUNT" = "$EXPECT_ACCOUNT" ] || { echo "REFUSING: account $ACCOUNT is not the load-test account." >&2; exit 1; }

BUCKET="avni-${ENVIRONMENT}-${ACCOUNT}"
echo "account: $ACCOUNT"
echo "bucket:  $BUCKET"

if aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "exists; reusing and re-applying settings"
else
  aws_ s3api create-bucket --bucket "$BUCKET" \
    --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  echo "created"
fi

aws_ s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws_ s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# ARTEFACTS DO NOT EXPIRE, and that is deliberate.
#   They did, at 90 days, on the theory that a run is "interesting until
#   analysed". That theory is wrong. Analysis is not a single pass: a finding
#   from one run gets re-read against an older one months later, and a
#   measurement whose artefacts are gone cannot be re-checked, only re-run --
#   on an environment that by then differs. The whole campaign is 1.8 GB, so
#   the rule was deleting the output of the exercise to save about 5c a month.
#
# Deployables keep their 365-day expiry: they are large, reproducible from a
# tag, and their provenance already lives in each run's run-metadata.json.
aws_ s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [
    {"ID":"expire-old-deployables","Status":"Enabled","Filter":{"Prefix":"deployables/"},
     "Expiration":{"Days":365}},
    {"ID":"abort-incomplete-uploads","Status":"Enabled","Filter":{"Prefix":""},
     "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}
  ]
}'

aws_ s3api put-bucket-tagging --bucket "$BUCKET" --tagging \
  "TagSet=[{Key=Name,Value=avni-${ENVIRONMENT}},{Key=Environment,Value=${ENVIRONMENT}},{Key=Client,Value=${AVNI_CLIENT:-Tanuh}},{Key=ManagedBy,Value=bootstrap-script}]"

echo "public access blocked, AES256 encryption, lifecycle and tags applied"
echo
echo "It survives tofu destroy. Jars in deployables/ and results in artefacts/"
echo "persist across rebuilds, which is the point."
