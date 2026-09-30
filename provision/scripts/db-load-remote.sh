#!/usr/bin/env bash
# Load a generated dataset into the load-test database FROM THE APP HOST.
#
#   ./db-load-remote.sh /tmp/states-day-180/state-1
#
# WHY NOT JUST RUN db-bootstrap.sh WITH load.sql
#   That runs psql on the laptop through an ssh port forward, and `\copy` is a
#   CLIENT-side command: every byte of every TSV would cross the EC2 Instance
#   Connect tunnel. EICE is a control-plane path sized for interactive shells,
#   not for moving gigabytes. A day-180 state dataset is ~1.7 GB of TSV.
#
#   So: ship the dataset to S3 (gzipped, ~4x smaller), pull it down on the app
#   host through the VPC gateway endpoint, and run psql there. The \copy stream
#   then never leaves the VPC and goes host -> RDS over the private subnet.
#
# WHY A PRESIGNED URL RATHER THAN THE AWS CLI ON THE HOST
#   The host has neither awscli nor psql. psql it must have -- nothing else can
#   run the load -- but awscli would be a second package installed outside
#   Ansible purely to fetch one file. A presigned URL needs only curl, which the
#   base role already installs.
#
# THE ABSOLUTE PATHS MATTER
#   load.sql is generated with absolute \copy paths (/tmp/<set>/<tenant>/x.tsv),
#   so the dataset has to land at the same absolute path on the host. The tar is
#   made relative to /tmp and extracted there for exactly that reason.
#
# IT DOES NOT PRINT OR ARGV THE PASSWORD
#   Written to a mode-600 PGPASSFILE on the host over ssh stdin, and removed on
#   exit. Never in `ps`, never in the log.
set -euo pipefail

SRC="${1:-}"
[ -n "$SRC" ] && [ -f "$SRC/load.sql" ] || {
  echo "usage: $(basename "$0") <dataset-dir containing load.sql>" >&2
  exit 1
}
SRC="$(cd "$SRC" && pwd)"
case "$SRC" in
  /tmp/*) ;;
  *) echo "dataset must live under /tmp: load.sql's \\copy paths are absolute" >&2; exit 1 ;;
esac
REL="${SRC#/tmp/}"                      # e.g. states-day-180/state-1
TAG="$(echo "$REL" | tr '/' '-')"

TOFU_DIR="${AVNI_TOFU_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../tofu/envs/loadtest" && pwd)}"
PROXY="${AVNI_EICE_PROXY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../configure/scripts" && pwd)/eice-ssh-proxy.sh}"
DB_USER="${AVNI_DB_USER:-openchs}"
DB_NAME="${AVNI_DB_NAME:-openchs}"

[ -n "${AWS_ACCESS_KEY_ID:-}" ] || {
  echo "No AWS credentials in the environment." >&2
  echo "  . provision/scripts/aws-session.sh" >&2
  exit 1
}

DB_HOST=$(tofu -chdir="$TOFU_DIR" output -raw db_endpoint); DB_HOST=${DB_HOST%%:*}
SECRET_ARN=$(tofu -chdir="$TOFU_DIR" output -raw db_master_secret_arn)
BUCKET=$(tofu -chdir="$TOFU_DIR" output -raw bucket)

APP_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Environment,Values=loadtest" "Name=tag:Role,Values=avni-server" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "$APP_ID" ] && [ "$APP_ID" != "None" ] || { echo "no running avni-server host found" >&2; exit 1; }

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ServerAliveInterval=30 -o ProxyCommand="$PROXY %h" "ubuntu@$APP_ID")

echo "dataset:  $SRC  ($(du -sh "$SRC" | cut -f1))"
echo "host:     $APP_ID"
echo "database: $DB_HOST"
echo

# --- ship -----------------------------------------------------------------
ARCHIVE="/tmp/${TAG}.tar.gz"
echo "[$(date -u +%H:%M:%S)] packing"
tar -C /tmp -czf "$ARCHIVE" "$REL"
echo "[$(date -u +%H:%M:%S)] uploading $(du -h "$ARCHIVE" | cut -f1) to s3://$BUCKET/datasets/"
aws s3 cp --only-show-errors "$ARCHIVE" "s3://$BUCKET/datasets/${TAG}.tar.gz"
URL=$(aws s3 presign "s3://$BUCKET/datasets/${TAG}.tar.gz" --expires-in 7200)

# --- prepare the host -----------------------------------------------------
echo "[$(date -u +%H:%M:%S)] preparing host"
"${SSH[@]}" bash -s <<HOSTPREP
set -euo pipefail
command -v psql >/dev/null || {
  echo "  installing postgresql-client"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client >/dev/null
}
psql --version
rm -rf "/tmp/$REL"
mkdir -p "/tmp/$(dirname "$REL")"
curl -sSf -o /tmp/${TAG}.tar.gz "$URL"
tar -C /tmp -xzf /tmp/${TAG}.tar.gz
rm -f /tmp/${TAG}.tar.gz
echo "  extracted \$(du -sh /tmp/$REL | cut -f1) to /tmp/$REL"
HOSTPREP

# --- credentials ----------------------------------------------------------
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --query SecretString --output text \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])' \
  | "${SSH[@]}" "umask 077; cat > /tmp/.pgpass_$TAG.raw; \
       printf '%s:5432:%s:%s:%s' '$DB_HOST' '$DB_NAME' '$DB_USER' \"\$(cat /tmp/.pgpass_$TAG.raw)\" > /tmp/.pgpass_$TAG; \
       rm -f /tmp/.pgpass_$TAG.raw; chmod 600 /tmp/.pgpass_$TAG"

cleanup() {
  "${SSH[@]}" "rm -f /tmp/.pgpass_$TAG" 2>/dev/null || true
}
trap cleanup EXIT

# --- load -----------------------------------------------------------------
# nohup + poll rather than holding the ssh session open: a dropped connection
# partway through a multi-hour COPY would kill psql and roll the whole thing
# back. \timing gives a per-\copy breakdown, which is what says whether a slow
# load is the encounter table or everything.
LOG="/tmp/${TAG}.load.log"
echo "[$(date -u +%H:%M:%S)] starting load, logging to $LOG on the host"
START=$(date +%s)
"${SSH[@]}" bash -s <<HOSTLOAD
set -euo pipefail
printf '\\\\timing on\n\\\\i /tmp/$REL/load.sql\n' > /tmp/${TAG}.run.sql
PGPASSFILE=/tmp/.pgpass_$TAG nohup psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -f /tmp/${TAG}.run.sql > "$LOG" 2>&1 &
echo \$! > /tmp/${TAG}.pid
echo "  pid \$(cat /tmp/${TAG}.pid)"
HOSTLOAD

while "${SSH[@]}" "kill -0 \$(cat /tmp/${TAG}.pid) 2>/dev/null"; do
  LAST=$("${SSH[@]}" "tail -1 $LOG" 2>/dev/null || true)
  echo "  [$(( $(date +%s) - START ))s] $LAST"
  sleep 60
done

END=$(date +%s)
echo
echo "[$(date -u +%H:%M:%S)] finished in $(( (END-START)/60 ))m $(( (END-START)%60 ))s"
echo "--- per-statement timing ---"
"${SSH[@]}" "grep -E 'loading|Time:|COPY|ERROR|ROLLBACK|COMMIT' $LOG | tail -60"
