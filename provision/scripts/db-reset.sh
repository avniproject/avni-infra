#!/usr/bin/env bash
# Per-run database reset for the load-test environment.
#
# WHY THIS EXISTS
#   Insert-then-delete cycles do not return a database to its prior state.
#   DELETE leaves dead tuples; VACUUM marks index pages reusable but does not
#   shrink the index; only REINDEX does. So repeated run/teardown cycles bloat
#   indexes, degrade cache hit ratio and shift query plans until runs stop being
#   comparable to each other. The answer is never to delete: let a run dirty the
#   database, then discard it and restore.
#
# WHERE IT RUNS
#   Inside the VPC. The database has no public endpoint, so this cannot be run
#   from a laptop — put it on the loader host, or any host in the private
#   subnets. That is a property of the environment, not an inconvenience.
#
# WHICH MECHANISM
#   Three are viable and the choice is meant to come from measurement, not
#   argument. Storage no longer decides it: at a ~70 GB dataset all three fit
#   inside the allocation, well under the 400 GiB threshold where RDS restripes
#   and hands out four times production's IOPS.
#
#     template   fast page-level copy; needs ~2x the dataset on the instance
#     restore    pg_restore from a dump in S3; ~1x; full index rebuild, GIN worst
#     regenerate re-run the generator's bulk COPY; ~1x, no stored artefact
#
#   Run each once with --time and pick on the number. Reset duration is the
#   floor on run turnaround, and at 125 MiB/s that is the price of IO parity.
set -euo pipefail

MECHANISM="${1:-}"
WORKING_DB="${AVNI_WORKING_DB:-avni_perf}"
TEMPLATE_DB="${AVNI_TEMPLATE_DB:-avni_perf_template}"
DUMP_URI="${AVNI_DUMP_URI:-}"          # s3://bucket/deployables/… for `restore`
GENERATOR="${AVNI_GENERATOR_CMD:-}"    # command for `regenerate`
JOBS="${AVNI_RESTORE_JOBS:-4}"

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") {template|restore|regenerate} [--time]

  PGHOST/PGUSER/PGPASSWORD (or ~/.pgpass) must reach the RDS instance.
  Run from inside the VPC — the database has no public endpoint.

  template     AVNI_TEMPLATE_DB (default: $TEMPLATE_DB)
  restore      AVNI_DUMP_URI, e.g. s3://avni-loadtest-<acct>/deployables/dataset.dump
  regenerate   AVNI_GENERATOR_CMD
USAGE
  exit 2
}

[ -n "$MECHANISM" ] || usage
command -v psql >/dev/null || { echo "psql not found" >&2; exit 1; }

# Terminate anything still connected, or DROP DATABASE blocks. A run that
# crashed can leave connections behind, and this is the usual reason a reset
# appears to hang.
disconnect() {
  psql -v ON_ERROR_STOP=1 -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE datname = '$1' AND pid <> pg_backend_pid();" >/dev/null
}

START=$(date +%s)

case "$MECHANISM" in
  template)
    # STRATEGY = FILE_COPY is explicit and load-bearing: since PG15 the default
    # is WAL_LOG, which writes the whole copy through WAL and is slow for a
    # large template.
    disconnect "$WORKING_DB"; disconnect "$TEMPLATE_DB"
    psql -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS $WORKING_DB;"
    psql -v ON_ERROR_STOP=1 -d postgres -c \
      "CREATE DATABASE $WORKING_DB TEMPLATE $TEMPLATE_DB STRATEGY = FILE_COPY;"
    ;;

  restore)
    [ -n "$DUMP_URI" ] || { echo "AVNI_DUMP_URI is unset" >&2; usage; }
    disconnect "$WORKING_DB"
    # DROP first so the restore lands in the freed space — this is what keeps
    # peak storage at ~1x rather than 2x.
    psql -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS $WORKING_DB;"
    psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE $WORKING_DB;"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    aws s3 cp "$DUMP_URI" "$TMP/dataset.dump"
    pg_restore --dbname="$WORKING_DB" --jobs="$JOBS" --no-owner --no-privileges \
      "$TMP/dataset.dump"
    ;;

  regenerate)
    [ -n "$GENERATOR" ] || { echo "AVNI_GENERATOR_CMD is unset" >&2; usage; }
    disconnect "$WORKING_DB"
    psql -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS $WORKING_DB;"
    psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE $WORKING_DB;"
    AVNI_WORKING_DB="$WORKING_DB" sh -c "$GENERATOR"
    ;;

  *) usage ;;
esac

# ANALYZE regardless of mechanism. Without it the planner works from stale or
# absent statistics and the first run measures the wrong thing.
psql -v ON_ERROR_STOP=1 -d "$WORKING_DB" -c "ANALYZE;"

END=$(date +%s)
echo "reset: $MECHANISM completed in $((END-START))s"

# Reset per-run statistics so collected data covers this run only.
psql -v ON_ERROR_STOP=1 -d "$WORKING_DB" \
  -c "SELECT pg_stat_statements_reset();" >/dev/null 2>&1 ||
  echo "note: pg_stat_statements_reset() unavailable — is the extension created?" >&2
