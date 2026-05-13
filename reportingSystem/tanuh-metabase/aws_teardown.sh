#!/usr/bin/env bash
#
# Teardown for the Tanuh Metabase stack.
#
# Mirrors aws_setup.sh in reverse order. Each delete-* swallows "not found"
# so a partial-state teardown can complete.
#
# Does NOT delete the GitHub OIDC provider (shared with other workloads).
#
# Usage:
#   bash aws_teardown.sh                  # interactive confirmation
#   FORCE=1 bash aws_teardown.sh          # non-interactive
#
set -uo pipefail

REGION=${REGION:-ap-south-1}
ECR_REPO_NAME=avniproject/tanuh-metabase
EC2_ROLE_NAME=tanuh-metabase-ec2-role
EC2_POLICY_NAME=tanuh-ecr-pull
GHA_ROLE_NAME=tanuh-metabase-gha-role
GHA_POLICY_NAME=tanuh-ecr-push
SG_NAME=tanuh-metabase-sg
INSTANCE_NAME=tanuh-metabase
ROUTE53_ZONE_NAME=${ROUTE53_ZONE_NAME:-avniproject.org.}
HOSTNAME_APP=tanuh-reporting.${ROUTE53_ZONE_NAME%.}
HOSTNAME_SSH=ssh.tanuh-reporting.${ROUTE53_ZONE_NAME%.}
REPORTING_VPC_CIDR=172.10.0.0/16

log() { echo "[aws_teardown] $*"; }

if [[ "${FORCE:-0}" != "1" ]]; then
  read -r -p "This will DELETE the Tanuh Metabase AWS resources. Type 'yes' to continue: " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

# --------------------------------------------------------------------------
# 1. Route53 A records
# --------------------------------------------------------------------------
log "Deleting Route53 records..."
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$ROUTE53_ZONE_NAME" \
  --query "HostedZones[?Name=='$ROUTE53_ZONE_NAME'].Id | [0]" --output text 2>/dev/null || echo "")
ZONE_ID=${ZONE_ID#/hostedzone/}

for host in "$HOSTNAME_APP" "$HOSTNAME_SSH"; do
  RR=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='$host.' && Type=='A'] | [0]" \
    --output json 2>/dev/null || echo "")
  if [[ -n "$RR" && "$RR" != "null" ]]; then
    cat > /tmp/r53-del.json <<EOF
{"Changes": [{"Action": "DELETE", "ResourceRecordSet": $RR}]}
EOF
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --change-batch file:///tmp/r53-del.json > /dev/null 2>&1 \
      && log "  Deleted $host" \
      || log "  Skipped $host (already absent or error)"
    rm -f /tmp/r53-del.json
  else
    log "  Skipped $host (not present)"
  fi
done

# --------------------------------------------------------------------------
# 2. EC2 instance
# --------------------------------------------------------------------------
log "Terminating EC2 instance(s) tagged Name=$INSTANCE_NAME..."
INSTANCE_IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n "$INSTANCE_IDS" ]]; then
  aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS > /dev/null
  log "  Waiting for termination..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
  log "  Terminated: $INSTANCE_IDS"
else
  log "  No live instance(s) found"
fi

# --------------------------------------------------------------------------
# 3. Security group
# --------------------------------------------------------------------------
log "Deleting security group $SG_NAME..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=cidr,Values=$REPORTING_VPC_CIDR" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
if [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
  SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
  if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" \
      && log "  Deleted $SG_ID" \
      || log "  Failed to delete $SG_ID (still in use?)"
  else
    log "  SG $SG_NAME not found"
  fi
fi

# --------------------------------------------------------------------------
# 4. EC2 IAM role + instance profile
# --------------------------------------------------------------------------
log "Removing EC2 instance profile and role..."
aws iam remove-role-from-instance-profile --instance-profile-name "$EC2_ROLE_NAME" --role-name "$EC2_ROLE_NAME" 2>/dev/null \
  && log "  Removed role from instance profile" || log "  (already removed)"
aws iam delete-instance-profile --instance-profile-name "$EC2_ROLE_NAME" 2>/dev/null \
  && log "  Deleted instance profile" || log "  (already absent)"
aws iam delete-role-policy --role-name "$EC2_ROLE_NAME" --policy-name "$EC2_POLICY_NAME" 2>/dev/null \
  && log "  Deleted inline policy" || log "  (already absent)"
aws iam detach-role-policy --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null \
  && log "  Detached SSM policy" || log "  (already detached)"
aws iam delete-role --role-name "$EC2_ROLE_NAME" 2>/dev/null \
  && log "  Deleted role $EC2_ROLE_NAME" || log "  (already absent)"

# --------------------------------------------------------------------------
# 5. GitHub Actions IAM role (OIDC provider left intact)
# --------------------------------------------------------------------------
log "Removing GHA role..."
aws iam delete-role-policy --role-name "$GHA_ROLE_NAME" --policy-name "$GHA_POLICY_NAME" 2>/dev/null \
  && log "  Deleted inline policy" || log "  (already absent)"
aws iam delete-role --role-name "$GHA_ROLE_NAME" 2>/dev/null \
  && log "  Deleted role $GHA_ROLE_NAME" || log "  (already absent)"

# --------------------------------------------------------------------------
# 6. ECR repository (with --force to remove images)
# --------------------------------------------------------------------------
log "Deleting ECR repository $ECR_REPO_NAME..."
aws ecr delete-repository --region "$REGION" \
  --repository-name "$ECR_REPO_NAME" --force 2>/dev/null \
  && log "  Deleted ECR repo" || log "  (already absent)"

log ""
log "Teardown complete."
log "Note: GitHub OIDC provider was NOT deleted (shared with other workloads)."
