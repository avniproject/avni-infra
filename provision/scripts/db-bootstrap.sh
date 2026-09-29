#!/usr/bin/env bash
# Apply scripts/db-bootstrap.sql to the load-test database. Run once, before
# the first deploy; safe to re-run.
#
# WHY A SCRIPT RATHER THAN A psql ONE-LINER
#   The database has no public endpoint and lives in a private subnet, so
#   nothing outside the VPC can reach it directly. This opens a local port
#   forward through the app host -- itself reached by the Instance Connect
#   tunnel, since that host has no public IP either -- runs the SQL against
#   localhost, and tears the forward down again.
#
#   Two hops, neither of which needs an inbound rule anywhere.
#
# IT DOES NOT PRINT THE PASSWORD
#   The master password is read from the extra-vars file the Makefile already
#   generates (mode 600) or from Secrets Manager, and passed to psql through
#   PGPASSWORD rather than on the command line, where ps would expose it.
set -euo pipefail

TOFU_DIR="${AVNI_TOFU_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../tofu/envs/loadtest" && pwd)}"
SQL_FILE="${AVNI_DB_SQL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/db-bootstrap.sql}"
PROXY="${AVNI_EICE_PROXY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../configure/scripts" && pwd)/eice-ssh-proxy.sh}"
LOCAL_PORT="${AVNI_DB_LOCAL_PORT:-15432}"
DB_USER="${AVNI_DB_USER:-openchs}"
DB_NAME="${AVNI_DB_NAME:-openchs}"

[ -n "${AWS_ACCESS_KEY_ID:-}" ] || {
  echo "No AWS credentials in the environment." >&2
  echo "  . provision/scripts/aws-session.sh" >&2
  exit 1
}

DB_ENDPOINT=$(tofu -chdir="$TOFU_DIR" output -raw db_endpoint)
DB_HOST=${DB_ENDPOINT%%:*}
SECRET_ARN=$(tofu -chdir="$TOFU_DIR" output -raw db_master_secret_arn)

# The app host is the only thing that can reach the database, so the forward
# goes through it. Discovered by tag rather than hardcoded: instance IDs change
# on every rebuild.
APP_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Environment,Values=loadtest" "Name=tag:Role,Values=avni-server" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "$APP_ID" ] && [ "$APP_ID" != "None" ] || { echo "no running avni-server host found" >&2; exit 1; }

PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --query SecretString --output text | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
export PGPASSWORD

echo "database: $DB_HOST"
echo "via:      $APP_ID  (local port $LOCAL_PORT)"

ssh -f -N -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ExitOnForwardFailure=yes \
    -o ProxyCommand="$PROXY %h" \
    -L "${LOCAL_PORT}:${DB_HOST}:5432" "ubuntu@${APP_ID}"

# The forward is a backgrounded ssh with no command; find it by the exact
# forward spec so a stray ssh to something else is never killed.
TUNNEL_PID=$(pgrep -f "ssh -f -N .*${LOCAL_PORT}:${DB_HOST}:5432" | head -1)
cleanup() { [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null || true; }
trap cleanup EXIT

psql -h localhost -p "$LOCAL_PORT" -U "$DB_USER" -d "$DB_NAME" \
     -v ON_ERROR_STOP=1 -f "$SQL_FILE"

echo
echo "Applied. Restart the server so Flyway retries the migration it failed on:"
echo "  ssh ... 'sudo systemctl restart avni_server_appserver'"
