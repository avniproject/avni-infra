"""avni-usage-metrics-db: writes one IST day of per-org counts to public_metrics.usage_daily.

Runs INSIDE the prod VPC (subnet B), reaching only the primary database on 5432. It has no route
to any AWS API and needs none: its password comes from its encrypted environment, and the counts
from the firewall log arrive in the invoking event from avni-usage-metrics-logs.

Signs in as avni_metrics_writer, which can read the four public_metrics views it needs and write
only usage_daily (avni-infra reportingSystem/public_metrics/feature_usage.sql).

Per run, in one transaction: delete the day's rows, insert the new ones. Re-running a day is safe.
"""
import datetime as dt
import os
import ssl
from collections import Counter

import pg8000.native

LIVE_ORGS = "select organisation_id, suffix from public_metrics.v_live_orgs"
DUPLICATES = "select suffix from public_metrics.v_duplicate_suffixes"
ALL_SUFFIXES = "select suffix from public_metrics.v_all_org_suffixes"
FOR_DAY_VIEWS = ("public_metrics.v_phone_pushes_for_day", "public_metrics.v_checklist_items_for_day")


def connect():
    # Amazon RDS CA bundle, packaged by deploy.sh. The host is the RDS endpoint name, which the
    # certificate carries; serverdb.avniproject.org is a CNAME and would fail hostname checks.
    ctx = ssl.create_default_context(cafile=os.path.join(os.path.dirname(__file__), "rds-global-bundle.pem"))
    return pg8000.native.Connection(
        user=os.environ["PGUSER"], password=os.environ["PGPASSWORD"],
        host=os.environ["PGHOST"], port=int(os.environ.get("PGPORT", "5432")),
        database=os.environ.get("PGDATABASE", "openchs"), ssl_context=ctx, timeout=60,
        application_name="avni-usage-metrics-db")


def handler(event, context):
    day = dt.date.fromisoformat(event["day"]).isoformat()
    con = connect()
    try:
        duplicates = {r[0].lower() for r in con.run(DUPLICATES) if r[0]}
        orgs = {}
        for org_id, suffix in con.run(LIVE_ORGS):
            if suffix and suffix.lower() not in duplicates:
                orgs[suffix.lower()] = org_id

        known = {r[0] for r in con.run(ALL_SUFFIXES)}
        rows = Counter()
        unmatched = Counter()
        not_live = 0
        for c in event.get("counts", []):
            org_id = orgs.get(c["suffix"].lower())
            if org_id is None:
                if c["suffix"].lower() in known and c["suffix"].lower() not in duplicates:
                    not_live += int(c["value"])  # UAT, trial, demo organisations: expected
                else:
                    unmatched[c["suffix"].lower()] += int(c["value"])
                continue
            rows[(org_id, c["feature"], c["measure"])] += int(c["value"])

        con.run("set avni.metrics_day = '" + day + "'")  # day is a validated ISO date
        for view in FOR_DAY_VIEWS:
            for org_id, feature, measure, value in con.run(
                    f"select organisation_id, feature, measure, value from {view}"):
                rows[(org_id, feature, measure)] += int(value)

        con.run("begin")
        con.run("delete from public_metrics.usage_daily where day = cast(:d as date)", d=day)
        for (org_id, feature, measure), value in rows.items():
            con.run("insert into public_metrics.usage_daily (day, organisation_id, feature, measure, value) "
                    "values (cast(:d as date), :o, :f, :m, :v)", d=day, o=org_id, f=feature, m=measure, v=value)
        con.run("commit")
    except Exception:
        try:
            con.run("rollback")
        except Exception:
            pass
        raise
    finally:
        con.close()

    # Suffixes are organisation identifiers, not people; reported so a mismatch can be fixed.
    return {"rows_written": len(rows), "unmatched_value": sum(unmatched.values()),
            "unmatched_suffixes": dict(unmatched.most_common(20)), "not_live_value": not_live,
            "duplicate_suffixes": len(duplicates)}
