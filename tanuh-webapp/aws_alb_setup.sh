#!/usr/bin/env bash
#
# One-time wiring of the Tanuh webapp (Vite SPA) behind the existing
# reporting-alb (Application Load Balancer) for HTTPS at
# https://tanuh.avniproject.org.
#
# Provisions: ACM cert (DNS-validated), target group, target registration,
# additional SNI cert on the existing 443 listener, listener rule
# (host-header=tanuh.avniproject.org -> tanuh-webapp TG),
# SG ingress (ALB -> EC2 port 8080), Route53 ALIAS -> ALB.
#
# The Tanuh EC2 itself, the reporting-alb, and the tanuh-metabase-sg are
# expected to already exist (provisioned by reportingSystem/tanuh-metabase/
# aws_setup.sh + aws_alb_setup.sh). This script only adds the second target
# group + listener rule + cert + Route53 record for the webapp hostname.
#
# Idempotency: not idempotent. Each step would fail on "already exists" if
# re-run. Use aws_alb_teardown.sh first to clean up.
#
# Prerequisites:
#   - reportingSystem/tanuh-metabase/aws_setup.sh has been run (Tanuh EC2 + SG
#     exist; the SG is reused for the webapp on a different port).
#   - reportingSystem/tanuh-metabase/aws_alb_setup.sh has been run (reporting-alb
#     fronts the EC2; its 443 listener exists).
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
WEBAPP_HOSTNAME=${WEBAPP_HOSTNAME:-tanuh.avniproject.org}
TG_NAME=${TG_NAME:-tanuh-webapp}
TG_PORT=${TG_PORT:-8080}
TANUH_INSTANCE_TAG=${TANUH_INSTANCE_TAG:-tanuh-metabase}
TANUH_SG_NAME=${TANUH_SG_NAME:-tanuh-metabase-sg}
ROUTE53_ZONE_NAME=${ROUTE53_ZONE_NAME:-avniproject.org.}
LISTENER_PRIORITY=${LISTENER_PRIORITY:-31}

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
log "Requesting ACM cert for $WEBAPP_HOSTNAME..."
CERT_ARN=$(aws acm request-certificate --region "$REGION" \
  --domain-name "$WEBAPP_HOSTNAME" \
  --validation-method DNS \
  --tags Key=Project,Value=tanuh-webapp Key=ManagedBy,Value=aws_alb_setup.sh \
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
log "  Cert ISSUED"

# --------------------------------------------------------------------------
# 2. Create target group + register the Tanuh EC2
# --------------------------------------------------------------------------
log "Creating target group $TG_NAME..."
TG_ARN=$(aws elbv2 create-target-group --region "$REGION" \
  --name "$TG_NAME" \
  --protocol HTTP --port "$TG_PORT" \
  --target-type instance \
  --vpc-id "$ALB_VPC" \
  --health-check-protocol HTTP --health-check-path / \
  --health-check-interval-seconds 30 --health-check-timeout-seconds 10 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --tags Key=Project,Value=tanuh-webapp Key=ManagedBy,Value=aws_alb_setup.sh \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
log "  TG: $TG_ARN"

log "  Registering EC2 $INSTANCE_ID..."
aws elbv2 register-targets --region "$REGION" --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=$TG_PORT"

# --------------------------------------------------------------------------
# 3. SG: allow ALB -> EC2:8080
# --------------------------------------------------------------------------
log "Allowing ingress on $TANUH_SG: tcp/$TG_PORT from $ALB_SG..."
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$TANUH_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=$TG_PORT,ToPort=$TG_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG,Description=From $ALB_NAME (tanuh-webapp)}]" \
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
log "Adding listener rule (priority=$LISTENER_PRIORITY): Host=$WEBAPP_HOSTNAME -> $TG_NAME..."
RULE_ARN=$(aws elbv2 create-rule --region "$REGION" \
  --listener-arn "$LISTENER_443" \
  --priority "$LISTENER_PRIORITY" \
  --conditions "Field=host-header,Values=$WEBAPP_HOSTNAME" \
  --actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --tags Key=Project,Value=tanuh-webapp Key=ManagedBy,Value=aws_alb_setup.sh \
  --query 'Rules[0].RuleArn' --output text)
log "  Rule: $RULE_ARN"

# --------------------------------------------------------------------------
# 6. Route53: create ALIAS tanuh.avniproject.org -> ALB. Fresh hostname,
#    so UPSERT is sufficient (no prior A->IP record to delete).
# --------------------------------------------------------------------------
log "Creating Route53 ALIAS $WEBAPP_HOSTNAME -> $ALB_NAME..."
cat > /tmp/r53-tanuh-webapp.json <<EOF
{
  "Changes": [
    {"Action": "UPSERT", "ResourceRecordSet": {
      "Name": "$WEBAPP_HOSTNAME.", "Type": "A",
      "AliasTarget": {"HostedZoneId": "$ALB_HZ", "DNSName": "$ALB_DNS", "EvaluateTargetHealth": false}
    }}
  ]
}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/r53-tanuh-webapp.json > /dev/null
rm /tmp/r53-tanuh-webapp.json

# --------------------------------------------------------------------------
# 7. Wait for target healthy. Health check requires the webapp to be deployed
#    on the EC2 first (port 8080 responding 200 on `/`). If you ran this
#    BEFORE deploying the webapp, expect an unhealthy state — that's fine,
#    re-check after `make tanuh-webapp-prod`.
# --------------------------------------------------------------------------
log "Note: target will be unhealthy until 'make tanuh-webapp-prod' has run"
log "      and nginx is serving the SPA on EC2:$TG_PORT."

log ""
log "ALB wiring complete."
log "Next: from configure/, run 'VAULT_PASSWORD_FILE=~/.ssh/infra-valut-pwd-file make tanuh-webapp-prod'"
log "Test: curl -sI https://$WEBAPP_HOSTNAME/  (expect HTTP/2 200 after deploy)"
log ""
log "Resources created (for aws_alb_teardown.sh):"
log "  Cert:     $CERT_ARN"
log "  TG:       $TG_ARN"
log "  Rule:     $RULE_ARN"
log "  SG rule:  ingress $TG_PORT on $TANUH_SG from $ALB_SG"
log "  Route53:  $WEBAPP_HOSTNAME ALIAS -> $ALB_DNS"
