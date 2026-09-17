#!/usr/bin/env bash
# Capture and guard the baseline snapshot for the load-test environment.
#
# THE BASELINE IS THE EXPENSIVE ARTEFACT
#   The dataset costs days to generate. The snapshot holding it is the thing
#   every rebuild restores from, and losing it means regenerating rather than
#   restoring. Two consequences shape this script.
#
#   It is a MANUAL snapshot, not an automated backup. Automated backups expire
#   with the retention window; a manual one persists until explicitly deleted.
#
#   It is NOT managed by OpenTofu, deliberately. A `tofu destroy` must not be
#   able to take it — the environment is disposable precisely because this is
#   not. `verify` below asserts that property rather than assuming it.
#
# ORDER MATTERS
#   Capture AFTER the dataset, the perf users and their catchments exist.
#   Restoring to a snapshot taken before them would destroy them every rebuild.
set -euo pipefail

CMD="${1:-}"
PROFILE="${AVNI_AWS_PROFILE:-avni-load-test}"
REGION="${AVNI_AWS_REGION:-ap-south-1}"
INSTANCE="${AVNI_DB_INSTANCE:-avni-loadtest}"
PREFIX="${AVNI_BASELINE_PREFIX:-avni-loadtest-baseline}"

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") {capture|list|verify}

  capture   take a manual snapshot of $INSTANCE, tagged against deletion
  list      show baseline snapshots and what produced each
  verify    assert the newest baseline is manual, available, and not owned
            by OpenTofu — run this after a destroy/rebuild cycle

  Version the snapshot with what produced it, via the environment:
    AVNI_GENERATOR_SHA   generator commit
    AVNI_ORG_CONFIG_REV  org config revision
  A dataset changes when the generator changes, and results either side of
  that are not comparable. Recording it here is what makes the discontinuity
  visible later rather than mysterious.
USAGE
  exit 2
}

aws_() { aws "$@" --profile "$PROFILE" --region "$REGION"; }

case "$CMD" in
  capture)
    ID="${PREFIX}-$(date -u +%Y%m%d-%H%M%S)"
    aws_ rds create-db-snapshot \
      --db-instance-identifier "$INSTANCE" \
      --db-snapshot-identifier "$ID" \
      --tags "Key=Role,Value=baseline" \
             "Key=DoNotDelete,Value=true" \
             "Key=GeneratorSha,Value=${AVNI_GENERATOR_SHA:-unknown}" \
             "Key=OrgConfigRev,Value=${AVNI_ORG_CONFIG_REV:-unknown}" \
      --output table
    echo
    echo "Waiting for $ID to become available (this is not quick)..."
    aws_ rds wait db-snapshot-available --db-snapshot-identifier "$ID"
    echo "baseline captured: $ID"
    echo "restore with: tofu apply -var restore_from_snapshot=$ID"
    ;;

  list)
    aws_ rds describe-db-snapshots --snapshot-type manual \
      --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'${PREFIX}')].{
                 id:DBSnapshotIdentifier,status:Status,created:SnapshotCreateTime,
                 gb:AllocatedStorage}" \
      --output table
    ;;

  verify)
    ID=$(aws_ rds describe-db-snapshots --snapshot-type manual \
          --query "sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier,'${PREFIX}')],
                   &SnapshotCreateTime)[-1].DBSnapshotIdentifier" --output text)
    [ "$ID" != "None" ] && [ -n "$ID" ] || {
      echo "FAIL: no baseline snapshot found with prefix '${PREFIX}'" >&2; exit 1; }

    TYPE=$(aws_ rds describe-db-snapshots --db-snapshot-identifier "$ID" \
            --query 'DBSnapshots[0].SnapshotType' --output text)
    STATUS=$(aws_ rds describe-db-snapshots --db-snapshot-identifier "$ID" \
            --query 'DBSnapshots[0].Status' --output text)

    echo "baseline: $ID"
    echo "  type:   $TYPE    (must be 'manual' — automated snapshots expire)"
    echo "  status: $STATUS"
    [ "$TYPE" = "manual" ] || { echo "FAIL: not a manual snapshot" >&2; exit 1; }
    [ "$STATUS" = "available" ] || { echo "FAIL: not available" >&2; exit 1; }

    # The property that actually matters: a destroy must not be able to take it.
    if grep -rqs "$ID" "$(dirname "$0")/../tofu" 2>/dev/null; then
      echo "FAIL: $ID is referenced in the OpenTofu roots — a destroy could take it" >&2
      exit 1
    fi
    echo "  not referenced by any OpenTofu resource — survives tofu destroy"
    echo "OK"
    ;;

  *) usage ;;
esac
