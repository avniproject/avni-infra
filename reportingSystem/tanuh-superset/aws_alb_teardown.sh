#!/usr/bin/env bash
#
# Undo aws_alb_setup.sh (Superset). Removes: Route53 alias, listener rule, SNI
# cert + ACM cert + its validation CNAME, target group + targets, SG ingress
# (ALB -> EC2:8088). Does NOT touch the Metabase wiring, the reporting-alb, or
# the EC2 itself.
#
# Usage:  bash aws_alb_teardown.sh           # interactive confirm
#         FORCE=1 bash aws_alb_teardown.sh   # non-interactive
#
set -uo pipefail

REGION=${REGION:-ap-south-1}
ALB_NAME=${ALB_NAME:-reporting-alb}
SITE_HOST=${SITE_HOST:-tanuh-reporting-superset.avniproject.org}
TG_NAME=${TG_NAME:-tanuh-superset}
TG_PORT=${TG_PORT:-8088}
TANUH_SG_NAME=${TANUH_SG_NAME:-tanuh-metabase-sg}
ROUTE53_ZONE_NAME=${ROUTE53_ZONE_NAME:-avniproject.org.}

log() { echo "[aws_alb_teardown] $*"; }

if [[ "${FORCE:-0}" != "1" ]]; then
  read -r -p "UNDO the Tanuh Superset ALB wiring? Type 'yes' to continue: " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

# --- Discover ---
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$ROUTE53_ZONE_NAME" \
  --query "HostedZones[?Name=='$ROUTE53_ZONE_NAME'].Id|[0]" --output text 2>/dev/null)
ZONE_ID=${ZONE_ID#/hostedzone/}
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
ALB_VPC=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].VpcId' --output text 2>/dev/null || echo "")
ALB_SG=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text 2>/dev/null || echo "")
LISTENER_443=""
[[ -n "$ALB_ARN" ]] && LISTENER_443=$(aws elbv2 describe-listeners --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`443`].ListenerArn|[0]' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
TANUH_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$ALB_VPC" "Name=group-name,Values=$TANUH_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

# --- 1. Route53 alias ---
log "Deleting Route53 alias $SITE_HOST..."
ALIAS_RR=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='$SITE_HOST.' && Type=='A']|[0]" --output json 2>/dev/null || echo "null")
if [[ "$ALIAS_RR" != "null" && -n "$ALIAS_RR" ]]; then
  cat > /tmp/r53-superset-del.json <<EOF
{"Changes": [{"Action": "DELETE", "ResourceRecordSet": $ALIAS_RR}]}
EOF
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch file:///tmp/r53-superset-del.json > /dev/null 2>&1 \
    && log "  Deleted alias" || log "  (alias already gone)"
  rm -f /tmp/r53-superset-del.json
fi

# --- 2. Listener rule ---
if [[ -n "$LISTENER_443" && -n "$TG_ARN" ]]; then
  RULE_ARNS=$(aws elbv2 describe-rules --region "$REGION" --listener-arn "$LISTENER_443" \
    --query "Rules[?Actions[?TargetGroupArn=='$TG_ARN']].RuleArn" --output text 2>/dev/null || echo "")
  for r in $RULE_ARNS; do
    aws elbv2 delete-rule --region "$REGION" --rule-arn "$r" > /dev/null 2>&1 \
      && log "  Deleted rule $r" || log "  (rule $r gone)"
  done
fi

# --- 3. Detach SNI cert + delete cert (+ validation CNAME) ---
CERT_ARN=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?DomainName=='$SITE_HOST'].CertificateArn|[0]" --output text)
if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
  [[ -n "$LISTENER_443" ]] && aws elbv2 remove-listener-certificates --region "$REGION" \
    --listener-arn "$LISTENER_443" --certificates "CertificateArn=$CERT_ARN" > /dev/null 2>&1 \
    && log "  Detached cert from listener" || true
  VAL_NAME=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text 2>/dev/null)
  VAL_VALUE=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text 2>/dev/null)
  if [[ -n "$VAL_NAME" && "$VAL_NAME" != "None" ]]; then
    cat > /tmp/r53-superset-acm-del.json <<EOF
{"Changes": [{"Action": "DELETE", "ResourceRecordSet": {"Name": "$VAL_NAME","Type": "CNAME","TTL": 300,"ResourceRecords": [{"Value": "$VAL_VALUE"}]}}]}
EOF
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
      --change-batch file:///tmp/r53-superset-acm-del.json > /dev/null 2>&1 \
      && log "  Deleted ACM validation CNAME" || log "  (validation CNAME absent)"
    rm -f /tmp/r53-superset-acm-del.json
  fi
  aws acm delete-certificate --region "$REGION" --certificate-arn "$CERT_ARN" 2>/dev/null \
    && log "  Deleted cert $CERT_ARN" || log "  Cert delete failed (still attached?)"
fi

# --- 4. Target group ---
if [[ -n "$TG_ARN" ]]; then
  aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$TG_ARN" 2>/dev/null \
    && log "  Deleted TG $TG_NAME" || log "  TG delete failed"
fi

# --- 5. SG ingress (ALB -> EC2:8088) ---
if [[ -n "$TANUH_SG" && -n "$ALB_SG" && "$TANUH_SG" != "None" && "$ALB_SG" != "None" ]]; then
  aws ec2 revoke-security-group-ingress --region "$REGION" \
    --group-id "$TANUH_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=$TG_PORT,ToPort=$TG_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG}]" \
    > /dev/null 2>&1 && log "  Removed SG ingress" || log "  (SG rule absent)"
fi

log ""
log "Teardown complete. Metabase wiring untouched."
