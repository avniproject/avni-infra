#!/usr/bin/env bash
#
# One-time backfill of the cost-allocation tag Client=tanuh onto every existing
# Tanuh-dedicated AWS resource in the avni account (region ap-south-1).
#
# Going forward, aws_setup.sh and aws_alb_setup.sh stamp Client=tanuh at
# creation time; this script only exists to tag the resources that were
# provisioned before that tag was introduced.
#
# Tagged here:
#   - EC2 instance tanuh-metabase + its EBS volume(s)  (volumes don't inherit
#     instance tags, so they're tagged explicitly)
#   - Security group tanuh-metabase-sg
#   - ECR repository avniproject/tanuh-metabase
#   - ACM certs for tanuh-reporting.avniproject.org and tanuh.avniproject.org
#   - ALB target groups tanuh-metabase / tanuh-webapp + their listener rules
#   - IAM roles tanuh-metabase-ec2-role / tanuh-metabase-gha-role
#
# Idempotent: re-tagging an already-tagged resource is a no-op. Resources that
# don't exist yet (e.g. the webapp TG/cert if the webapp half isn't deployed)
# are skipped with a warning rather than failing the run.
#
# Prerequisites:
#   - aws CLI v2 configured with tagging permissions in the avni account.
#
# Usage:
#   bash aws_tag_client.sh
#
set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
REGION=${REGION:-ap-south-1}
TAG_KEY=${TAG_KEY:-Client}
TAG_VALUE=${TAG_VALUE:-tanuh}

INSTANCE_NAME=tanuh-metabase
SG_NAME=tanuh-metabase-sg
ECR_REPO_NAME=avniproject/tanuh-metabase
ALB_NAME=${ALB_NAME:-reporting-alb}
CERT_DOMAINS=(tanuh-reporting.avniproject.org tanuh.avniproject.org)
TG_NAMES=(tanuh-metabase tanuh-webapp)
IAM_ROLES=(tanuh-metabase-ec2-role tanuh-metabase-gha-role)

log()  { echo "[aws_tag_client] $*"; }
warn() { echo "[aws_tag_client] WARN: $*" >&2; }

# --------------------------------------------------------------------------
# 1. EC2 instance + its EBS volumes + security group
# --------------------------------------------------------------------------
log "Tagging EC2 instance $INSTANCE_NAME and its volumes..."
INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
  warn "instance $INSTANCE_NAME not found — skipping instance + volumes"
else
  VOLUME_IDS=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
    --query 'Volumes[].VolumeId' --output text)
  # shellcheck disable=SC2086  # word-splitting $VOLUME_IDS is intentional
  aws ec2 create-tags --region "$REGION" \
    --resources "$INSTANCE_ID" $VOLUME_IDS \
    --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  log "  tagged instance $INSTANCE_ID and volumes: ${VOLUME_IDS:-<none>}"
fi

log "Tagging security group $SG_NAME..."
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  warn "security group $SG_NAME not found — skipping"
else
  aws ec2 create-tags --region "$REGION" --resources "$SG_ID" \
    --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  log "  tagged $SG_ID"
fi

# --------------------------------------------------------------------------
# 2. ECR repository
# --------------------------------------------------------------------------
log "Tagging ECR repository $ECR_REPO_NAME..."
ECR_ARN=$(aws ecr describe-repositories --region "$REGION" \
  --repository-names "$ECR_REPO_NAME" \
  --query 'repositories[0].repositoryArn' --output text 2>/dev/null || true)
if [[ -z "$ECR_ARN" || "$ECR_ARN" == "None" ]]; then
  warn "ECR repo $ECR_REPO_NAME not found — skipping"
else
  aws ecr tag-resource --region "$REGION" --resource-arn "$ECR_ARN" \
    --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  log "  tagged $ECR_ARN"
fi

# --------------------------------------------------------------------------
# 3. ACM certificates
# --------------------------------------------------------------------------
for d in "${CERT_DOMAINS[@]}"; do
  log "Tagging ACM cert for $d..."
  CERT_ARN=$(aws acm list-certificates --region "$REGION" \
    --query "CertificateSummaryList[?DomainName=='$d'].CertificateArn | [0]" \
    --output text)
  if [[ "$CERT_ARN" == "None" || -z "$CERT_ARN" ]]; then
    warn "no ACM cert for $d — skipping"
  else
    aws acm add-tags-to-certificate --region "$REGION" \
      --certificate-arn "$CERT_ARN" \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
    log "  tagged $CERT_ARN"
  fi
done

# --------------------------------------------------------------------------
# 4. ALB target groups + their listener rules (on the shared reporting-alb)
# --------------------------------------------------------------------------
# Collect the Tanuh target-group ARNs first, then tag both the TGs and the
# 443-listener rules that forward to them.
TANUH_TG_ARNS=()
for tg in "${TG_NAMES[@]}"; do
  log "Tagging target group $tg..."
  TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --names "$tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
  if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
    warn "target group $tg not found — skipping"
    continue
  fi
  aws elbv2 add-tags --region "$REGION" --resource-arns "$TG_ARN" \
    --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  TANUH_TG_ARNS+=("$TG_ARN")
  log "  tagged $TG_ARN"
done

if [[ ${#TANUH_TG_ARNS[@]} -gt 0 ]]; then
  log "Tagging listener rules forwarding to the Tanuh target groups..."
  ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
  if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
    warn "ALB $ALB_NAME not found — skipping listener rules"
  else
    LISTENER_443=$(aws elbv2 describe-listeners --region "$REGION" \
      --load-balancer-arn "$ALB_ARN" \
      --query 'Listeners[?Port==`443`].ListenerArn | [0]' --output text)
    # For each Tanuh TG, find the rule(s) forwarding to it and tag them.
    for tg_arn in "${TANUH_TG_ARNS[@]}"; do
      RULE_ARNS=$(aws elbv2 describe-rules --region "$REGION" \
        --listener-arn "$LISTENER_443" \
        --query "Rules[?Actions[?TargetGroupArn=='$tg_arn']].RuleArn" --output text)
      if [[ -z "$RULE_ARNS" ]]; then
        warn "no listener rule forwards to $tg_arn — skipping"
        continue
      fi
      for rule_arn in $RULE_ARNS; do
        aws elbv2 add-tags --region "$REGION" --resource-arns "$rule_arn" \
          --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
        log "  tagged rule $rule_arn"
      done
    done
  fi
fi

# --------------------------------------------------------------------------
# 5. IAM roles (no cost, tagged for inventory/consistency; IAM tags are global)
# --------------------------------------------------------------------------
for role in "${IAM_ROLES[@]}"; do
  log "Tagging IAM role $role..."
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam tag-role --role-name "$role" \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
    log "  tagged $role"
  else
    warn "IAM role $role not found — skipping"
  fi
done

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------
log ""
log "Done. Resources now carrying $TAG_KEY=$TAG_VALUE in $REGION:"
aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=$TAG_KEY,Values=$TAG_VALUE" \
  --query 'ResourceTagMappingList[].ResourceARN' --output table

log ""
log "Note: IAM roles are global and won't appear in the ap-south-1 listing above."
log "Next: activate the cost-allocation tag (once) so it shows in Cost Explorer:"
log "  aws ce update-cost-allocation-tags-status \\"
log "    --cost-allocation-tags-status TagKey=$TAG_KEY,Status=Active"
