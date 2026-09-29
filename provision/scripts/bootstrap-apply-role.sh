#!/usr/bin/env bash
# Put a guardrail on the OpenTofu apply role. Plan task 0.6 (issue #103).
#
# WHAT THIS IS NOT
#   It is not an allow-list. Task 0.6 was written as "an apply role scoped to
#   this environment, not account-wide admin" -- before the environment got its
#   own AWS account. The plan's own opening says the rest: "a broad apply role
#   inside a dedicated account is safe in a way the same role in the production
#   account never would be, because the account IS the scope."
#
#   Enumerating allows for everything the module touches -- VPC, RDS, IAM, WAF,
#   ACM, Route53, S3, KMS, EC2, CloudWatch -- is a large, brittle list that
#   breaks on every module change and gets bypassed the first time it does.
#   That version of this task costs a week and buys a second account boundary
#   inside an account that already is one.
#
# WHAT THE ACTUAL GAP IS
#   Four things live OUTSIDE OpenTofu so that `tofu destroy` cannot take them:
#   the state bucket, the state KMS key, the public hosted zone, and the
#   baseline snapshot. That design protects them from a destroy and from
#   nothing else. The apply role can still delete any of them with one CLI
#   call -- and the zone takes the NS delegation with it, while the baseline
#   takes days of dataset generation.
#
#   So this attaches an explicit DENY. Denies beat allows in IAM, so it holds
#   whatever the allow side grants, now or later.
#
# A GUARDRAIL AGAINST ACCIDENTS, NOT AGAINST INTENT
#   Deliberately absent: any statement stopping the role from editing its own
#   policies. Two reasons. It would be theatre -- a role that can PutRolePolicy
#   on itself can overwrite this guardrail, and denying PutRolePolicy while
#   allowing nothing else to manage the role locks you out of updating it,
#   including by re-running this script. And the threat being defended against
#   is a careless `delete-hosted-zone`, a cleanup script with a glob, or a
#   destroy pointed at the wrong root -- not a hostile administrator, who in a
#   dedicated account always has a way round.
#
# OBJECT-LEVEL S3 IS ALSO DELIBERATELY ABSENT
#   Denying s3:DeleteObject on the state bucket would break OpenTofu's S3-native
#   locking, which creates and deletes a .tflock object per operation. Bucket
#   versioning (90-day non-current retention, set by bootstrap-state-backend.sh)
#   is the recovery path for a deleted state file instead.
set -euo pipefail

CMD="${1:-apply}"
PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
REGION="${AVNI_AWS_REGION:-ap-south-1}"
ROLE="${AVNI_APPLY_ROLE:-avni-loadtest-admin}"
ZONE_NAME="${AVNI_ZONE_NAME:-loadtest.avniproject.org}"
POLICY_NAME="${ROLE}-durable-prerequisites"
EXPECT_ACCOUNT=936573213727
PROD_ACCOUNT=118388513628

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  aws_() { aws "$@" --region "$REGION"; }
  awsg_() { aws "$@"; }
else
  aws_() { aws "$@" --profile "$PROFILE" --region "$REGION"; }
  awsg_() { aws "$@" --profile "$PROFILE"; }
fi

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") {apply|verify|show}

  apply    attach or update the deny policy on $ROLE
  verify   prove it works, WITHOUT deleting anything -- see the note below
  show     print the policy currently attached

  Environment: AVNI_AWS_PROFILE AVNI_AWS_REGION AVNI_APPLY_ROLE AVNI_ZONE_NAME
USAGE
  exit 2
}

# Validate the argument BEFORE touching AWS. Resolving credentials first meant
# a typo'd subcommand sat waiting on an MFA prompt instead of printing usage --
# and with a cached-credential setup that prompt cannot always be answered.
case "$CMD" in
  apply|verify|show) ;;
  *) usage ;;
esac

ACCOUNT=$(awsg_ sts get-caller-identity --query Account --output text)
[ "$ACCOUNT" != "$PROD_ACCOUNT" ] || { echo "REFUSING: this is PRODUCTION." >&2; exit 1; }
[ "$ACCOUNT" = "$EXPECT_ACCOUNT" ] || { echo "REFUSING: account $ACCOUNT is not the load-test account." >&2; exit 1; }
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"

# Resolve the durable four by lookup rather than hardcoding. If one of these
# cannot be found the guardrail would be written against a wrong ARN and
# silently protect nothing, so each is fatal.
resolve() {
  BUCKET="avni-tofu-state-${ACCOUNT}"
  awsg_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 \
    || { echo "state bucket $BUCKET not found" >&2; exit 1; }

  KEY_ARN=$(aws_ kms describe-key --key-id alias/avni-tofu-state --query 'KeyMetadata.Arn' --output text) \
    || { echo "state KMS key not found" >&2; exit 1; }

  ZONE_ID=$(awsg_ route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
    --query "HostedZones[?Name=='${ZONE_NAME}.'&&!Config.PrivateZone].Id" --output text | sed 's|/hostedzone/||')
  [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ] || { echo "public hosted zone $ZONE_NAME not found" >&2; exit 1; }
}

case "$CMD" in
  apply)
    resolve
    echo "role:   $ROLE_ARN"
    echo "bucket: $BUCKET"
    echo "key:    $KEY_ARN"
    echo "zone:   $ZONE_ID"
    echo

    cat > /tmp/apply-role-deny.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProtectStateBucket",
      "Effect": "Deny",
      "Action": ["s3:DeleteBucket", "s3:PutBucketVersioning", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy"],
      "Resource": ["arn:aws:s3:::${BUCKET}"]
    },
    {
      "Sid": "ProtectStateKey",
      "Effect": "Deny",
      "Action": ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy", "kms:DeleteAlias"],
      "Resource": ["${KEY_ARN}"]
    },
    {
      "Sid": "ProtectHostedZone",
      "Effect": "Deny",
      "Action": ["route53:DeleteHostedZone"],
      "Resource": ["arn:aws:route53:::hostedzone/${ZONE_ID}"]
    },
    {
      "Sid": "ProtectTaggedSnapshots",
      "Effect": "Deny",
      "Action": ["rds:DeleteDBSnapshot", "rds:ModifyDBSnapshotAttribute"],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:ResourceTag/DoNotDelete": "true" }
      }
    }
  ]
}
JSON

    awsg_ iam put-role-policy --role-name "$ROLE" \
      --policy-name "$POLICY_NAME" \
      --policy-document file:///tmp/apply-role-deny.json
    rm -f /tmp/apply-role-deny.json
    echo "attached $POLICY_NAME to $ROLE"
    echo
    echo "Now prove it: $(basename "$0") verify"
    ;;

  show)
    awsg_ iam get-role-policy --role-name "$ROLE" --policy-name "$POLICY_NAME" \
      --query 'PolicyDocument' --output json
    ;;

  verify)
    # NOTHING IS DELETED HERE, and that is the whole design of this check.
    #
    # The obvious way to test a deny is to attempt the call and watch it fail.
    # That is catastrophic when the deny is MISSING -- which is precisely the
    # case the test exists to catch. `aws s3api delete-bucket` against an
    # unguarded state bucket does not report a bug, it causes one.
    #
    # iam simulate-principal-policy evaluates the role's policies against an
    # action and resource and returns the decision, without touching anything.
    resolve
    SNAP=$(aws_ rds describe-db-snapshots --snapshot-type manual \
            --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'avni-loadtest-baseline')]|[0].DBSnapshotArn" \
            --output text 2>/dev/null || echo "None")
    [ "$SNAP" != "None" ] && [ -n "$SNAP" ] \
      || SNAP="arn:aws:rds:${REGION}:${ACCOUNT}:snapshot:avni-loadtest-baseline-absent"

    FAIL=0
    # $1 label, $2 action, $3 resource, $4 expected decision, $5.. extra args
    check() {
      local label="$1" action="$2" resource="$3" want="$4"; shift 4
      local got
      got=$(awsg_ iam simulate-principal-policy \
              --policy-source-arn "$ROLE_ARN" \
              --action-names "$action" \
              --resource-arns "$resource" \
              "$@" \
              --query 'EvaluationResults[0].EvalDecision' --output text)
      if [ "$got" = "$want" ]; then
        printf '  ok    %-34s %s\n' "$label" "$got"
      else
        printf '  FAIL  %-34s got %s, wanted %s\n' "$label" "$got" "$want"
        FAIL=1
      fi
    }

    echo "Simulating against $ROLE_ARN (no resource is modified)"
    echo
    echo "must be denied:"
    check "delete state bucket"      s3:DeleteBucket          "arn:aws:s3:::${BUCKET}"                 explicitDeny
    check "schedule key deletion"    kms:ScheduleKeyDeletion  "$KEY_ARN"                               explicitDeny
    check "delete hosted zone"       route53:DeleteHostedZone "arn:aws:route53:::hostedzone/${ZONE_ID}" explicitDeny
    check "delete tagged snapshot"   rds:DeleteDBSnapshot     "$SNAP"                                  explicitDeny \
          --context-entries 'ContextKeyName=aws:ResourceTag/DoNotDelete,ContextKeyValues=true,ContextKeyType=string'

    echo
    echo "must still be allowed -- a guardrail that denies everything is not a guardrail:"
    check "build infrastructure"     ec2:CreateVpc            "*"                                      allowed
    check "prune an untagged final"  rds:DeleteDBSnapshot     "arn:aws:rds:${REGION}:${ACCOUNT}:snapshot:avni-loadtest-final-example" allowed

    echo
    [ "$FAIL" -eq 0 ] && echo "OK" || { echo "GUARDRAIL NOT INTACT" >&2; exit 1; }
    ;;

  *) usage ;;
esac
