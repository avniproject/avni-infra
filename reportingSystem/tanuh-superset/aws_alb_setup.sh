#!/usr/bin/env bash
#
# One-time wiring of Tanuh Superset behind the existing reporting-alb for HTTPS
# at https://tanuh-reporting-superset.avniproject.org.
#
# Superset runs as a second container on the SAME Tanuh EC2 as Metabase (port
# 8088). This is additive to the Metabase ALB wiring (aws_alb_setup.sh in
# ../tanuh-metabase): new ACM cert, new target group (:8088, health /health),
# new SNI cert on the shared 443 listener, new host-header listener rule, a
# new SG ingress (ALB -> EC2:8088), and a NEW Route53 alias record. It does not
# touch the Metabase target group, rule, cert, or DNS.
#
# Unlike the Metabase script there is no Route53 A->IP swap: this hostname is
# brand new, so we just create an ALIAS straight to the ALB. SSH is unchanged
# (still ssh.tanuh-reporting.avniproject.org on the Metabase host).
#
# NOT idempotent. Use aws_alb_teardown.sh to roll back, then re-run.
#
# Prerequisites:
#   - The Tanuh EC2 (tag Name=tanuh-metabase), tanuh-metabase-sg, and the
#     reporting-alb already exist (provisioned by ../tanuh-metabase/aws_setup.sh
#     + aws_alb_setup.sh).
#   - The Superset container is (or will be) running on :8088 (make
#     tanuh-superset-prod) — the target only goes healthy once it serves /health.
#   - aws CLI v2 with admin in the avni account.
#
# Usage:  bash aws_alb_setup.sh
#
set -euo pipefail

REGION=${REGION:-ap-south-1}
ALB_NAME=${ALB_NAME:-reporting-alb}
SITE_HOST=${SITE_HOST:-tanuh-reporting-superset.avniproject.org}
TG_NAME=${TG_NAME:-tanuh-superset}
TG_PORT=${TG_PORT:-8088}
HEALTH_PATH=${HEALTH_PATH:-/health}
TANUH_INSTANCE_TAG=${TANUH_INSTANCE_TAG:-tanuh-metabase}
TANUH_SG_NAME=${TANUH_SG_NAME:-tanuh-metabase-sg}
ROUTE53_ZONE_NAME=${ROUTE53_ZONE_NAME:-avniproject.org.}
# Must be unused on the 443 listener. Metabase uses 30; pick a free slot.
LISTENER_PRIORITY=${LISTENER_PRIORITY:-40}

log() { echo "[aws_alb_setup] $*"; }

# --- Discover existing resources ---
log "Discovering ALB, Tanuh EC2, Tanuh SG, hosted zone..."
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

ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$ROUTE53_ZONE_NAME" \
  --query "HostedZones[?Name=='$ROUTE53_ZONE_NAME'].Id|[0]" --output text)
ZONE_ID=${ZONE_ID#/hostedzone/}

# Guard: don't clobber the priority Metabase (or another rule) already uses.
EXISTING_AT_PRIO=$(aws elbv2 describe-rules --region "$REGION" --listener-arn "$LISTENER_443" \
  --query "Rules[?Priority=='$LISTENER_PRIORITY'].RuleArn|[0]" --output text)
if [[ -n "$EXISTING_AT_PRIO" && "$EXISTING_AT_PRIO" != "None" ]]; then
  log "ERROR: listener priority $LISTENER_PRIORITY already in use ($EXISTING_AT_PRIO)."
  log "       Re-run with LISTENER_PRIORITY=<free slot>."
  exit 1
fi

log "  ALB: $ALB_ARN"
log "  Tanuh EC2: $INSTANCE_ID   Tanuh SG: $TANUH_SG   Zone: $ZONE_ID"

# --- 1. ACM cert (DNS-validated) ---
log "Requesting ACM cert for $SITE_HOST..."
CERT_ARN=$(aws acm request-certificate --region "$REGION" \
  --domain-name "$SITE_HOST" \
  --validation-method DNS \
  --tags Key=Project,Value=tanuh-superset Key=Client,Value=tanuh Key=ManagedBy,Value=aws_alb_setup.sh \
  --query CertificateArn --output text)
log "  Cert ARN: $CERT_ARN ; sleeping 10s for validation record..."
sleep 10
VAL_NAME=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text)
VAL_VALUE=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text)
cat > /tmp/r53-superset-acm.json <<EOF
{"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
  "Name": "$VAL_NAME", "Type": "CNAME", "TTL": 300,
  "ResourceRecords": [{"Value": "$VAL_VALUE"}]}}]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/r53-superset-acm.json > /dev/null
rm -f /tmp/r53-superset-acm.json
log "  Waiting for cert ISSUED..."
aws acm wait certificate-validated --region "$REGION" --certificate-arn "$CERT_ARN"
log "  Cert ISSUED."

# --- 2. Target group + register EC2 ---
log "Creating target group $TG_NAME (HTTP/$TG_PORT, health $HEALTH_PATH)..."
TG_ARN=$(aws elbv2 create-target-group --region "$REGION" \
  --name "$TG_NAME" \
  --protocol HTTP --port "$TG_PORT" \
  --target-type instance \
  --vpc-id "$ALB_VPC" \
  --health-check-protocol HTTP --health-check-path "$HEALTH_PATH" \
  --health-check-interval-seconds 30 --health-check-timeout-seconds 10 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --tags Key=Project,Value=tanuh-superset Key=Client,Value=tanuh Key=ManagedBy,Value=aws_alb_setup.sh \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --region "$REGION" --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=$TG_PORT"
log "  TG: $TG_ARN (EC2 $INSTANCE_ID registered)"

# --- 3. SG: allow ALB -> EC2:8088 (keeps 8088 off the public internet) ---
log "Allowing ingress on $TANUH_SG: tcp/$TG_PORT from $ALB_SG..."
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$TANUH_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=$TG_PORT,ToPort=$TG_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG,Description=From $ALB_NAME (superset)}]" \
  > /dev/null

# --- 4. SNI cert on the shared 443 listener (additive) ---
log "Attaching cert to listener via SNI..."
aws elbv2 add-listener-certificates --region "$REGION" \
  --listener-arn "$LISTENER_443" --certificates "CertificateArn=$CERT_ARN" > /dev/null

# --- 5. Listener rule: Host -> TG ---
log "Adding listener rule (priority=$LISTENER_PRIORITY): Host=$SITE_HOST -> $TG_NAME..."
RULE_ARN=$(aws elbv2 create-rule --region "$REGION" \
  --listener-arn "$LISTENER_443" \
  --priority "$LISTENER_PRIORITY" \
  --conditions "Field=host-header,Values=$SITE_HOST" \
  --actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --tags Key=Project,Value=tanuh-superset Key=Client,Value=tanuh Key=ManagedBy,Value=aws_alb_setup.sh \
  --query 'Rules[0].RuleArn' --output text)
log "  Rule: $RULE_ARN"

# --- 6. Route53: create ALIAS -> ALB (new hostname; no swap) ---
log "Creating Route53 ALIAS $SITE_HOST -> $ALB_NAME..."
cat > /tmp/r53-superset-alias.json <<EOF
{"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
  "Name": "$SITE_HOST.", "Type": "A",
  "AliasTarget": {"HostedZoneId": "$ALB_HZ", "DNSName": "$ALB_DNS", "EvaluateTargetHealth": false}}}]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/r53-superset-alias.json > /dev/null
rm -f /tmp/r53-superset-alias.json

# --- 7. Wait for target healthy ---
log "Waiting for target to become healthy (needs Superset serving $HEALTH_PATH)..."
aws elbv2 wait target-in-service --region "$REGION" --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=$TG_PORT" || \
  log "  (not healthy yet — check the container is up and initialised)"

log ""
log "ALB wiring complete."
log "Test: curl -sI https://$SITE_HOST$HEALTH_PATH   (expect HTTP/2 200)"
log ""
log "Resources created (for aws_alb_teardown.sh):"
log "  Cert:    $CERT_ARN"
log "  TG:      $TG_ARN"
log "  Rule:    $RULE_ARN  (priority $LISTENER_PRIORITY)"
log "  SG rule: ingress $TG_PORT on $TANUH_SG from $ALB_SG"
log "  Route53: $SITE_HOST ALIAS -> $ALB_NAME"
