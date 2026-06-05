#!/usr/bin/env bash
#
# One-time wiring of the Tanuh Metabase EC2 behind the existing reporting-alb
# (Application Load Balancer) for HTTPS at https://tanuh-reporting.avniproject.org.
#
# Provisions: ACM cert (DNS-validated), target group, target registration,
# additional SNI cert on the existing 443 listener, listener rule
# (host-header=tanuh-reporting.avniproject.org -> tanuh-metabase TG),
# SG ingress (ALB -> EC2 port 3000), Route53 swap from A->IP to ALIAS->ALB.
#
# Idempotency: not idempotent. Each step would fail on "already exists" if
# re-run. Use aws_alb_teardown.sh first to clean up.
#
# Prerequisites:
#   - aws_setup.sh has already been run (the Tanuh EC2, SG, ECR exist).
#   - The reporting-alb exists in ap-south-1 (provisioned long ago by
#     provision/reporting/elb.tf or click-ops).
#   - aws CLI v2 with admin-equivalent perms in the avni account.
#
# Usage:
#   bash aws_alb_setup.sh
#
set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
REGION=${REGION:-ap-south-1}
ALB_NAME=${ALB_NAME:-reporting-alb}
HOSTNAME=${HOSTNAME:-tanuh-reporting.avniproject.org}
TG_NAME=${TG_NAME:-tanuh-metabase}
TG_PORT=${TG_PORT:-3000}
TANUH_INSTANCE_TAG=${TANUH_INSTANCE_TAG:-tanuh-metabase}
TANUH_SG_NAME=${TANUH_SG_NAME:-tanuh-metabase-sg}
ROUTE53_ZONE_NAME=${ROUTE53_ZONE_NAME:-avniproject.org.}
LISTENER_PRIORITY=${LISTENER_PRIORITY:-30}

log() { echo "[aws_alb_setup] $*"; }

# --------------------------------------------------------------------------
# Discover existing resources
# --------------------------------------------------------------------------
log "Discovering existing ALB, EC2 instance, Tanuh SG, hosted zone..."
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)
ALB_HZ=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
ALB_SG=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
ALB_VPC=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].VpcId' --output text)
LISTENER_443=$(aws elbv2 describe-listeners --region "$REGION" --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`443`].ListenerArn|[0]' --output text)

INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$TANUH_INSTANCE_TAG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
TANUH_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$ALB_VPC" "Name=group-name,Values=$TANUH_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$ROUTE53_ZONE_NAME" \
  --query "HostedZones[?Name=='$ROUTE53_ZONE_NAME'].Id|[0]" --output text)
ZONE_ID=${ZONE_ID#/hostedzone/}

log "  ALB:        $ALB_ARN"
log "  ALB DNS:    $ALB_DNS"
log "  ALB SG:     $ALB_SG"
log "  443 listen: $LISTENER_443"
log "  Tanuh EC2:  $INSTANCE_ID"
log "  Tanuh SG:   $TANUH_SG"
log "  Zone:       $ZONE_ID"

# --------------------------------------------------------------------------
# 1. Request ACM cert (DNS-validated) and add validation CNAME
# --------------------------------------------------------------------------
log "Requesting ACM cert for $HOSTNAME..."
CERT_ARN=$(aws acm request-certificate --region "$REGION" \
  --domain-name "$HOSTNAME" \
  --validation-method DNS \
  --tags Key=Project,Value=tanuh-metabase Key=Client,Value=tanuh Key=ManagedBy,Value=aws_alb_setup.sh \
  --query CertificateArn --output text)
log "  Cert ARN: $CERT_ARN"

log "  Sleeping 10s for AWS to populate validation records..."
sleep 10
VAL_NAME=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text)
VAL_VALUE=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text)
log "  Validation record: $VAL_NAME"

cat > /tmp/r53-acm-validation.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$VAL_NAME",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "$VAL_VALUE"}]
    }
  }]
}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/r53-acm-validation.json > /dev/null
rm /tmp/r53-acm-validation.json

log "  Waiting for cert ISSUED..."
aws acm wait certificate-validated --region "$REGION" --certificate-arn "$CERT_ARN"
log "  Cert ISSUED ✓"

# --------------------------------------------------------------------------
# 2. Create target group + register the Tanuh EC2
# --------------------------------------------------------------------------
log "Creating target group $TG_NAME..."
TG_ARN=$(aws elbv2 create-target-group --region "$REGION" \
  --name "$TG_NAME" \
  --protocol HTTP --port "$TG_PORT" \
  --target-type instance \
  --vpc-id "$ALB_VPC" \
  --health-check-protocol HTTP --health-check-path /api/health \
  --health-check-interval-seconds 30 --health-check-timeout-seconds 10 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --tags Key=Project,Value=tanuh-metabase Key=Client,Value=tanuh Key=ManagedBy,Value=aws_alb_setup.sh \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
log "  TG: $TG_ARN"

log "  Registering EC2 $INSTANCE_ID..."
aws elbv2 register-targets --region "$REGION" --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=$TG_PORT"

# --------------------------------------------------------------------------
# 3. SG: allow ALB -> EC2:3000
# --------------------------------------------------------------------------
log "Allowing ingress on $TANUH_SG: tcp/$TG_PORT from $ALB_SG..."
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$TANUH_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=$TG_PORT,ToPort=$TG_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG,Description=From $ALB_NAME}]" \
  > /dev/null

# --------------------------------------------------------------------------
# 4. Attach SNI cert to existing 443 listener (additive — does NOT replace
#    the default cert serving the existing hostnames)
# --------------------------------------------------------------------------
log "Attaching cert to listener $LISTENER_443 via SNI..."
aws elbv2 add-listener-certificates --region "$REGION" \
  --listener-arn "$LISTENER_443" \
  --certificates "CertificateArn=$CERT_ARN" \
  > /dev/null

# --------------------------------------------------------------------------
# 5. Listener rule: Host header -> target group
# --------------------------------------------------------------------------
log "Adding listener rule (priority=$LISTENER_PRIORITY): Host=$HOSTNAME -> $TG_NAME..."
RULE_ARN=$(aws elbv2 create-rule --region "$REGION" \
  --listener-arn "$LISTENER_443" \
  --priority "$LISTENER_PRIORITY" \
  --conditions "Field=host-header,Values=$HOSTNAME" \
  --actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --tags Key=Project,Value=tanuh-metabase Key=Client,Value=tanuh Key=ManagedBy,Value=aws_alb_setup.sh \
  --query 'Rules[0].RuleArn' --output text)
log "  Rule: $RULE_ARN"

# --------------------------------------------------------------------------
# 6. Wait for target healthy
# --------------------------------------------------------------------------
log "Waiting for target to become healthy..."
aws elbv2 wait target-in-service --region "$REGION" --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=$TG_PORT"
log "  Target healthy ✓"

# --------------------------------------------------------------------------
# 7. Route53: swap A->IP for ALIAS->ALB. (ssh.tanuh-reporting stays as A->IP
#    so SSH still works via the EC2's public IP.)
# --------------------------------------------------------------------------
log "Swapping Route53 $HOSTNAME from A->IP to ALIAS->$ALB_NAME..."
# Find the existing A record (with literal IP)
EXISTING_IP=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='$HOSTNAME.' && Type=='A' && ResourceRecords].ResourceRecords[0].Value" \
  --output text)

if [[ -n "$EXISTING_IP" && "$EXISTING_IP" != "None" ]]; then
  log "  Deleting existing A record ($EXISTING_IP) and creating alias..."
  cat > /tmp/r53-swap.json <<EOF
{
  "Changes": [
    {"Action": "DELETE",  "ResourceRecordSet": {
      "Name": "$HOSTNAME.", "Type": "A", "TTL": 300,
      "ResourceRecords": [{"Value": "$EXISTING_IP"}]
    }},
    {"Action": "CREATE",  "ResourceRecordSet": {
      "Name": "$HOSTNAME.", "Type": "A",
      "AliasTarget": {"HostedZoneId": "$ALB_HZ", "DNSName": "$ALB_DNS", "EvaluateTargetHealth": false}
    }}
  ]
}
EOF
else
  log "  No existing A record found, creating alias..."
  cat > /tmp/r53-swap.json <<EOF
{
  "Changes": [
    {"Action": "UPSERT", "ResourceRecordSet": {
      "Name": "$HOSTNAME.", "Type": "A",
      "AliasTarget": {"HostedZoneId": "$ALB_HZ", "DNSName": "$ALB_DNS", "EvaluateTargetHealth": false}
    }}
  ]
}
EOF
fi
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/r53-swap.json > /dev/null
rm /tmp/r53-swap.json

log ""
log "ALB wiring complete."
log "Test: curl -sI https://$HOSTNAME/api/health  (expect HTTP/2 200)"
log "SSH unchanged: ssh ubuntu@ssh.$HOSTNAME"
log ""
log "Resources created (for aws_alb_teardown.sh):"
log "  Cert:     $CERT_ARN"
log "  TG:       $TG_ARN"
log "  Rule:     $RULE_ARN"
log "  SG rule:  ingress 3000 on $TANUH_SG from $ALB_SG"
log "  Route53:  $HOSTNAME swapped to ALIAS"
