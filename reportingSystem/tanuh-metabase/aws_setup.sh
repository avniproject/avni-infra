#!/usr/bin/env bash
#
# One-time AWS setup for the Tanuh Metabase stack.
#
# Provisions: ECR repo, EC2 IAM role/instance-profile, GitHub Actions IAM role
# (+ OIDC provider), security group, EC2 instance, Route53 A records.
#
# Not idempotent. A second accidental run will abort on "already exists"
# instead of producing duplicates. Use aws_teardown.sh to roll back.
#
# Prerequisites:
#   - aws CLI v2 configured with admin-equivalent permissions in the avni
#     AWS account, region ap-south-1.
#   - jq, envsubst installed locally.
#   - The reporting VPC (CIDR 172.10.0.0/16) and reportingsubneta subnet exist.
#   - Set TEAM_SSH_CIDR (the egress CIDR for SSH ingress).
#
# Usage:
#   TEAM_SSH_CIDR=1.2.3.4/32 bash aws_setup.sh
#
set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
REGION=${REGION:-ap-south-1}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO_NAME=avniproject/tanuh-metabase
EC2_ROLE_NAME=tanuh-metabase-ec2-role
EC2_POLICY_NAME=tanuh-ecr-pull
GHA_ROLE_NAME=tanuh-metabase-gha-role
GHA_POLICY_NAME=tanuh-ecr-push
SG_NAME=tanuh-metabase-sg
INSTANCE_NAME=tanuh-metabase
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.medium}
KEY_NAME=${KEY_NAME:-openchs-infra}
ROOT_VOLUME_GB=${ROOT_VOLUME_GB:-30}
ROUTE53_ZONE_NAME=${ROUTE53_ZONE_NAME:-avniproject.org.}
HOSTNAME_APP=tanuh-reporting.${ROUTE53_ZONE_NAME%.}
HOSTNAME_SSH=ssh.tanuh-reporting.${ROUTE53_ZONE_NAME%.}
REPORTING_VPC_CIDR=172.10.0.0/16
# The reporting public subnet's Name tag is "Reporting Subnet A" (with spaces),
# created historically by provision/reporting/networking.tf as "reportingsubneta"
# but tagged with the prettier name.
REPORTING_SUBNET_TAG="Reporting Subnet A"

: "${TEAM_SSH_CIDR:?Set TEAM_SSH_CIDR (e.g. 1.2.3.4/32) before running}"

export ACCOUNT_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { echo "[aws_setup] $*"; }

# --------------------------------------------------------------------------
# Discover existing infra (no hardcoded ARNs/IDs)
# --------------------------------------------------------------------------
log "Discovering reporting VPC, subnet, hosted zone, latest Ubuntu 22.04 AMI..."

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=cidr,Values=$REPORTING_VPC_CIDR" \
  --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && { echo "Reporting VPC not found"; exit 1; }

SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$REPORTING_SUBNET_TAG" \
  --query 'Subnets[0].SubnetId' --output text)
[[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] && { echo "Subnet $REPORTING_SUBNET_TAG not found"; exit 1; }

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$ROUTE53_ZONE_NAME" \
  --query "HostedZones[?Name=='$ROUTE53_ZONE_NAME'].Id | [0]" --output text)
[[ "$ZONE_ID" == "None" || -z "$ZONE_ID" ]] && { echo "Hosted zone $ROUTE53_ZONE_NAME not found"; exit 1; }
ZONE_ID=${ZONE_ID#/hostedzone/}

UBUNTU_AMI=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
  --query 'Parameter.Value' --output text)

log "  VPC:    $VPC_ID"
log "  Subnet: $SUBNET_ID"
log "  Zone:   $ZONE_ID"
log "  AMI:    $UBUNTU_AMI"

# --------------------------------------------------------------------------
# 1. ECR repository
# --------------------------------------------------------------------------
log "Creating ECR repository $ECR_REPO_NAME..."
ECR_ARN=$(aws ecr create-repository --region "$REGION" \
  --repository-name "$ECR_REPO_NAME" \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability MUTABLE \
  --query 'repository.repositoryArn' --output text)
log "  ECR repo: $ECR_ARN"

# --------------------------------------------------------------------------
# 2. EC2 IAM role + instance profile
# --------------------------------------------------------------------------
log "Creating EC2 IAM role $EC2_ROLE_NAME..."
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json \
  --tags Key=Project,Value=tanuh-metabase Key=ManagedBy,Value=aws_setup.sh \
  --output text > /dev/null

log "Attaching scoped ECR pull policy..."
envsubst < ecr-pull-policy.json > /tmp/tanuh-ecr-pull.json
aws iam put-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-name "$EC2_POLICY_NAME" \
  --policy-document file:///tmp/tanuh-ecr-pull.json
rm -f /tmp/tanuh-ecr-pull.json

log "Attaching AmazonSSMManagedInstanceCore (for Session Manager fallback)..."
aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

log "Creating instance profile..."
aws iam create-instance-profile --instance-profile-name "$EC2_ROLE_NAME" \
  --output text > /dev/null
aws iam add-role-to-instance-profile \
  --instance-profile-name "$EC2_ROLE_NAME" \
  --role-name "$EC2_ROLE_NAME"

# --------------------------------------------------------------------------
# 3. GitHub Actions OIDC provider + role
# --------------------------------------------------------------------------
log "Ensuring GitHub OIDC identity provider exists..."
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" \
  --output text)
if [[ "$OIDC_ARN" == "None" || -z "$OIDC_ARN" ]]; then
  log "  Creating OIDC provider..."
  OIDC_ARN=$(aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
    --query 'OpenIDConnectProviderArn' --output text)
fi
log "  OIDC provider: $OIDC_ARN"

log "Creating GitHub Actions IAM role $GHA_ROLE_NAME..."
envsubst < gha-trust-policy.json > /tmp/gha-trust.json
aws iam create-role \
  --role-name "$GHA_ROLE_NAME" \
  --assume-role-policy-document file:///tmp/gha-trust.json \
  --tags Key=Project,Value=tanuh-metabase Key=ManagedBy,Value=aws_setup.sh \
  --output text > /dev/null
rm -f /tmp/gha-trust.json

envsubst < gha-ecr-policy.json > /tmp/gha-ecr.json
aws iam put-role-policy \
  --role-name "$GHA_ROLE_NAME" \
  --policy-name "$GHA_POLICY_NAME" \
  --policy-document file:///tmp/gha-ecr.json
rm -f /tmp/gha-ecr.json

GHA_ROLE_ARN=$(aws iam get-role --role-name "$GHA_ROLE_NAME" \
  --query 'Role.Arn' --output text)
log "  GHA role: $GHA_ROLE_ARN"
log "  -> Add this ARN to .github/workflows/build-tanuh-metabase.yml (role-to-assume)."

# --------------------------------------------------------------------------
# 4. Security group
# --------------------------------------------------------------------------
log "Creating security group $SG_NAME..."
SG_ID=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "$SG_NAME" \
  --description "Tanuh Metabase (managed by aws_setup.sh)" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

aws ec2 create-tags --region "$REGION" \
  --resources "$SG_ID" \
  --tags Key=Name,Value=$SG_NAME Key=Project,Value=tanuh-metabase Key=ManagedBy,Value=aws_setup.sh

log "  Adding ingress: 22/tcp from $TEAM_SSH_CIDR"
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$TEAM_SSH_CIDR" > /dev/null

log "  Adding ingress: 3000/tcp from $REPORTING_VPC_CIDR (no public 3000)"
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp --port 3000 --cidr "$REPORTING_VPC_CIDR" > /dev/null

log "  SG: $SG_ID"

# --------------------------------------------------------------------------
# 5. EC2 instance
# --------------------------------------------------------------------------
log "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$UBUNTU_AMI" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile Name="$EC2_ROLE_NAME" \
  --key-name "$KEY_NAME" \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOLUME_GB,VolumeType=gp3,DeleteOnTermination=true}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=tanuh-metabase},{Key=ManagedBy,Value=aws_setup.sh}]" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --query 'Instances[0].InstanceId' --output text)

log "  Instance: $INSTANCE_ID"
log "  Waiting for status-ok..."
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "  Public IP: $PUBLIC_IP"

# --------------------------------------------------------------------------
# 6. Route53 A records
# --------------------------------------------------------------------------
log "Upserting Route53 records..."
cat > /tmp/r53-batch.json <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$HOSTNAME_APP",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "$PUBLIC_IP"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$HOSTNAME_SSH",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "$PUBLIC_IP"}]
      }
    }
  ]
}
EOF
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/r53-batch.json > /dev/null
rm -f /tmp/r53-batch.json
log "  $HOSTNAME_APP -> $PUBLIC_IP"
log "  $HOSTNAME_SSH -> $PUBLIC_IP"

# --------------------------------------------------------------------------
# 7. Reachability checks
# --------------------------------------------------------------------------
log "Waiting 30s for DNS propagation..."
sleep 30

log "Verifying SSH reachability..."
ssh -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
    -i "${HOME}/.ssh/${KEY_NAME}.pem" \
    "ubuntu@$HOSTNAME_SSH" 'true' && log "  SSH OK"

log "Verifying IAM instance role from the EC2..."
ssh -i "${HOME}/.ssh/${KEY_NAME}.pem" "ubuntu@$HOSTNAME_SSH" \
  'curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)" http://169.254.169.254/latest/meta-data/iam/security-credentials/' \
  | head -1

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
log ""
log "Setup complete."
log "Next steps:"
log "  1. Add the GHA role ARN ($GHA_ROLE_ARN) to .github/workflows/build-tanuh-metabase.yml."
log "  2. Push a tag tanuh-metabase-vX to trigger the image build, OR run make build-image push-image locally."
log "  3. Bootstrap tanuh_reporting_db on the prod RDS — see DB_BOOTSTRAP.md."
log "  4. From configure/, run: make tanuh-metabase-prod -- --skip-tags metabase_db_trigger"
