#!/usr/bin/env bash
# Read-only human accounts on the load-test account, provisioned by CLI.
#
#   . provision/scripts/aws-session.sh
#   ./provision/scripts/readonly-users.sh <username> [<username>...]
#   ./provision/scripts/readonly-users.sh --show
#
# Usernames are arguments, never committed here: who has access is not a fact
# this repository should carry. --show reads the membership back from AWS,
# which is where it actually lives.
#
# WHY NOT OPENTOFU. These were briefly managed as code and then deliberately
# taken out of state (tofu state rm, 9 Oct 2026) so that people do not appear
# in the diff of every infrastructure change. The resources were not destroyed;
# only their state entries were removed.
#
# WHAT THAT COSTS, because it is a real trade. `tofu plan` no longer reports
# these accounts, so nothing detects a policy attached to the group by hand, a
# user added to it, or access keys minted. This script is the only record, and
# it is only true if it is re-run. --show prints what AWS actually has, which
# is the honest check.
#
# WHAT "READ ONLY" MEANS HERE. AWS's ReadOnlyAccess grants secretsmanager
# Describe*/GetResourcePolicy/List* but NOT GetSecretValue, and kms
# Describe*/Get*/List* but not Decrypt -- so s3:Get* reaches the tofu state
# bucket and returns ciphertext.
#
# THE SECOND POLICY IS NOT READ-ONLY. loadtest-read-db-master-secret grants
# GetSecretValue on the RDS master credential, which is the database superuser:
# read, write and drop on the load-test database. What still constrains it is
# the network -- the instance is PubliclyAccessible=false in private subnets --
# and that the data is synthetic. The group name understates this.
#
# NO CREDENTIALS ARE CREATED. Issue them out of band:
#   aws iam create-login-profile --user-name <u> --password '<...>' --password-reset-required
#   aws iam create-access-key    --user-name <u>
set -euo pipefail

GROUP=loadtest-readonly
SECRET_POLICY=loadtest-read-db-master-secret
READONLY_ARN=arn:aws:iam::aws:policy/ReadOnlyAccess
EXPECT_ACCOUNT=936573213727

account=$(aws sts get-caller-identity --query Account --output text)
[ "$account" = "$EXPECT_ACCOUNT" ] || { echo "wrong account: $account (want $EXPECT_ACCOUNT)" >&2; exit 1; }

if [ $# -eq 0 ]; then
  echo "usage: $(basename "$0") <username> [<username>...]   # create / converge" >&2
  echo "       $(basename "$0") --show                       # report what AWS has" >&2
  exit 2
fi

if [ "${1:-}" = "--show" ]; then
  echo "group $GROUP"
  aws iam list-attached-group-policies --group-name "$GROUP" \
    --query 'AttachedPolicies[].PolicyName' --output text | tr '\t' '\n' | sed 's/^/  policy /'
  aws iam get-group --group-name "$GROUP" --query 'Users[].UserName' --output text | tr '\t' '\n' | sed 's/^/  member /'
  for u in $(aws iam get-group --group-name "$GROUP" --query 'Users[].UserName' --output text); do
    n=$(aws iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)' --output text)
    p=$(aws iam get-login-profile --user-name "$u" >/dev/null 2>&1 && echo yes || echo no)
    echo "  $u: access keys $n, console password $p"
  done
  exit 0
fi

aws iam get-group --group-name "$GROUP" >/dev/null 2>&1 \
  || { aws iam create-group --group-name "$GROUP" >/dev/null; echo "created group $GROUP"; }

aws iam attach-group-policy --group-name "$GROUP" --policy-arn "$READONLY_ARN"
echo "attached ReadOnlyAccess"

SECRET_ARN=$(tofu -chdir=provision/tofu/envs/loadtest output -raw db_master_secret_arn)
POLICY_ARN="arn:aws:iam::${EXPECT_ACCOUNT}:policy/${SECRET_POLICY}"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "$SECRET_POLICY" \
    --description "Read the RDS master credential for the load-test database. This is superuser access to that database." \
    --policy-document "$(printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],"Resource":["%s"]}]}' "$SECRET_ARN")" >/dev/null
  echo "created $SECRET_POLICY"
fi
aws iam attach-group-policy --group-name "$GROUP" --policy-arn "$POLICY_ARN"
echo "attached $SECRET_POLICY"

for u in "$@"; do
  aws iam get-user --user-name "$u" >/dev/null 2>&1 \
    || { aws iam create-user --user-name "$u" \
           --tags Key=Environment,Value=loadtest Key=Access,Value=read-only Key=ManagedBy,Value=readonly-users.sh >/dev/null
         echo "created user $u"; }
  aws iam add-user-to-group --group-name "$GROUP" --user-name "$u"
  echo "  $u in $GROUP"
done
echo "done. Run with --show to see what AWS actually has."
