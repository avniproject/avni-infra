#!/usr/bin/env bash
# Deploys the feature usage nightly job (avniproject/avni-product-ops#331) to the prod account.
# Idempotent: re-running updates code and configuration in place.
#
#   avni-usage-metrics-logs  outside the VPC. Reads the web firewall log, decodes login tokens in
#                            memory where no user-name header exists, invokes the db function.
#   avni-usage-metrics-db    inside prod subnet B. Writes public_metrics.usage_daily as
#                            avni_metrics_writer. Reaches only the primary on 5432.
#
# Prod is not under OpenTofu (provision/OPENTOFU_LOADTEST_ENV_PLAN.md), so this is plain AWS CLI.
# The writer password is read from the operator's keychain and goes only into the db function's
# encrypted environment. Run as a person with IAM and Lambda rights in 118388513628:
#
#   ./deploy.sh
set -euo pipefail

REGION=ap-south-1
ACCOUNT=118388513628
VPC=vpc-2300a74b
SUBNET=subnet-9e3f23d3                      # prod Subnet B, same AZ as proddb02
DB_HOST=proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com   # endpoint name matches the RDS certificate
LOG_GROUP=aws-waf-logs-ddos-blocked
ALERT_TOPIC=arn:aws:sns:$REGION:$ACCOUNT:avni-infra-alerts
LOGS_FN=avni-usage-metrics-logs
DB_FN=avni-usage-metrics-db
TAGS="Project=feature-usage-dashboard,Card=avni-product-ops-331,Owner=samanvay-ops"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
aws() { command aws --region "$REGION" "$@"; }

[ "$(command aws sts get-caller-identity --query Account --output text)" = "$ACCOUNT" ] || { echo "not the prod account"; exit 1; }
WRITER_PW="$(security find-generic-password -s avni_metrics_writer -w)"

# ---- package -----------------------------------------------------------------------------
mkdir -p "$BUILD/logs" "$BUILD/db"
cp "$HERE/logs_lambda/handler.py" "$BUILD/logs/"
cp "$HERE/db_lambda/handler.py" "$BUILD/db/"
python3 -m pip install --quiet --target "$BUILD/db" "pg8000==1.31.6" "scramp==1.5.0" "asn1crypto==1.5.1"
curl -fsS https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$BUILD/db/rds-global-bundle.pem"
(cd "$BUILD/logs" && zip -qr ../logs.zip .)
(cd "$BUILD/db" && zip -qr ../db.zip .)

# ---- roles -------------------------------------------------------------------------------
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ensure_role() {
  command aws iam get-role --role-name "$1" >/dev/null 2>&1 || \
    command aws iam create-role --role-name "$1" --assume-role-policy-document "$TRUST" \
      --tags "Key=Project,Value=feature-usage-dashboard" >/dev/null
}
ensure_role "$LOGS_FN"
ensure_role "$DB_FN"

command aws iam put-role-policy --role-name "$LOGS_FN" --policy-name usage-metrics --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"logs:StartQuery","Resource":"arn:aws:logs:$REGION:$ACCOUNT:log-group:$LOG_GROUP:*"},
 {"Effect":"Allow","Action":["logs:GetQueryResults","logs:StopQuery"],"Resource":"*"},
 {"Effect":"Allow","Action":"lambda:InvokeFunction","Resource":"arn:aws:lambda:$REGION:$ACCOUNT:function:$DB_FN"},
 {"Effect":"Allow","Action":"cloudwatch:PutMetricData","Resource":"*","Condition":{"StringEquals":{"cloudwatch:namespace":"AvniUsageMetrics"}}},
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:$REGION:$ACCOUNT:log-group:/aws/lambda/$LOGS_FN:*"}
]}
EOF
)"
command aws iam attach-role-policy --role-name "$DB_FN" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole

# ---- network: the db function's own security group, egress to the primary only -----------
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$DB_FN Name=vpc-id,Values=$VPC --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = "None" ]; then
  SG=$(aws ec2 create-security-group --group-name "$DB_FN" --vpc-id "$VPC" \
        --description "avni-usage-metrics-db: egress to proddb02 on 5432 only" --query GroupId --output text)
  aws ec2 revoke-security-group-egress --group-id "$SG" --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null
  aws ec2 authorize-security-group-egress --group-id "$SG" --ip-permissions '[{"IpProtocol":"tcp","FromPort":5432,"ToPort":5432,"IpRanges":[{"CidrIp":"10.100.2.192/32","Description":"proddb02"}]}]' >/dev/null
  aws ec2 create-tags --resources "$SG" --tags Key=Project,Value=feature-usage-dashboard
fi
# proddb02's sg-1c2cd777 already allows 5432 from 10.100.0.0/16; nothing to change there.

sleep 10  # new IAM roles take a few seconds to be assumable

# ---- functions ---------------------------------------------------------------------------
DB_ENV="Variables={PGHOST=$DB_HOST,PGPORT=5432,PGDATABASE=openchs,PGUSER=avni_metrics_writer,PGPASSWORD=$WRITER_PW}"
if aws lambda get-function --function-name "$DB_FN" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$DB_FN" --zip-file "fileb://$BUILD/db.zip" >/dev/null
  aws lambda wait function-updated --function-name "$DB_FN"
  aws lambda update-function-configuration --function-name "$DB_FN" --environment "$DB_ENV" >/dev/null
else
  aws lambda create-function --function-name "$DB_FN" --runtime python3.13 --handler handler.handler \
    --role "arn:aws:iam::$ACCOUNT:role/$DB_FN" --zip-file "fileb://$BUILD/db.zip" --timeout 180 --memory-size 256 \
    --vpc-config "SubnetIds=$SUBNET,SecurityGroupIds=$SG" --environment "$DB_ENV" --tags "$TAGS" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "$DB_FN"
unset WRITER_PW DB_ENV

LOGS_ENV="Variables={WAF_LOG_GROUP=$LOG_GROUP,LB_MATCH=prod-openchs-load-balancer,DB_FUNCTION=$DB_FN}"
if aws lambda get-function --function-name "$LOGS_FN" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$LOGS_FN" --zip-file "fileb://$BUILD/logs.zip" >/dev/null
  aws lambda wait function-updated --function-name "$LOGS_FN"
  aws lambda update-function-configuration --function-name "$LOGS_FN" --environment "$LOGS_ENV" >/dev/null
else
  aws lambda create-function --function-name "$LOGS_FN" --runtime python3.13 --handler handler.handler \
    --role "arn:aws:iam::$ACCOUNT:role/$LOGS_FN" --zip-file "fileb://$BUILD/logs.zip" --timeout 900 --memory-size 256 \
    --environment "$LOGS_ENV" --tags "$TAGS" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "$LOGS_FN"
aws logs create-log-group --log-group-name "/aws/lambda/$LOGS_FN" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/aws/lambda/$LOGS_FN" --retention-in-days 90
aws logs create-log-group --log-group-name "/aws/lambda/$DB_FN" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/aws/lambda/$DB_FN" --retention-in-days 90

# ---- schedule: 03:00 IST, for the day before ----------------------------------------------
SCHED_ROLE=avni-usage-metrics-scheduler
command aws iam get-role --role-name "$SCHED_ROLE" >/dev/null 2>&1 || \
  command aws iam create-role --role-name "$SCHED_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
command aws iam put-role-policy --role-name "$SCHED_ROLE" --policy-name invoke --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"arn:aws:lambda:$REGION:$ACCOUNT:function:$LOGS_FN\"}]}"
sleep 10
SCHED_ARGS=(--name avni-usage-metrics-nightly --schedule-expression "cron(0 3 * * ? *)"
  --schedule-expression-timezone Asia/Kolkata --flexible-time-window Mode=OFF
  --target "Arn=arn:aws:lambda:$REGION:$ACCOUNT:function:$LOGS_FN,RoleArn=arn:aws:iam::$ACCOUNT:role/$SCHED_ROLE,RetryPolicy={MaximumRetryAttempts=2}")
aws scheduler get-schedule --name avni-usage-metrics-nightly >/dev/null 2>&1 \
  && aws scheduler update-schedule "${SCHED_ARGS[@]}" >/dev/null \
  || aws scheduler create-schedule "${SCHED_ARGS[@]}" >/dev/null

# ---- alarms --------------------------------------------------------------------------------
aws cloudwatch put-metric-alarm --alarm-name avni-usage-metrics-failed \
  --alarm-description "Feature usage nightly job failed (avni-product-ops#331)" \
  --namespace AWS/Lambda --metric-name Errors --dimensions Name=FunctionName,Value=$LOGS_FN \
  --statistic Sum --period 86400 --evaluation-periods 1 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
  --alarm-actions "$ALERT_TOPIC"
aws cloudwatch put-metric-alarm --alarm-name avni-usage-metrics-no-web-saves \
  --alarm-description "Feature usage job wrote no web saves for a day: header lost, or job not running (avni-product-ops#331)" \
  --namespace AvniUsageMetrics --metric-name WebSaves \
  --statistic Sum --period 86400 --evaluation-periods 1 --threshold 1 \
  --comparison-operator LessThanThreshold --treat-missing-data breaching \
  --alarm-actions "$ALERT_TOPIC"
aws cloudwatch put-metric-alarm --alarm-name avni-usage-metrics-unmatched \
  --alarm-description "More than 5% of firewall-log requests matched no live organisation (avni-product-ops#331)" \
  --namespace AvniUsageMetrics --metric-name UnmatchedPercent \
  --statistic Maximum --period 86400 --evaluation-periods 1 --threshold 5 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "$ALERT_TOPIC"

echo "deployed: $LOGS_FN, $DB_FN (sg $SG), schedule avni-usage-metrics-nightly, 3 alarms"
echo "try one day:  aws lambda invoke --function-name $LOGS_FN --cli-binary-format raw-in-base64-out --payload '{\"day\":\"YYYY-MM-DD\",\"dry_run\":true}' /dev/stdout"
