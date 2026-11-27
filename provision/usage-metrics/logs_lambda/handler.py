"""avni-usage-metrics-logs: reads one IST day of the prod web firewall log and hands per-org counts
to avni-usage-metrics-db, which writes them to public_metrics.usage_daily.

Runs OUTSIDE the prod VPC (it needs CloudWatch Logs, Lambda and CloudWatch metrics, and the prod
subnets have no route to them). It never touches the database.

What it counts (avniproject/avni-product-ops#331, spec "Which source answers what"):
  * web saves of subjects, enrolments and visits  -- these carry the `user-name` header
  * images opened on the web, records voided on the web -- these carry only AUTH-TOKEN until the
    web app sends `user-name` on axios calls; the token payload is decoded IN MEMORY for the
    username's suffix, and the token is dropped.

It never logs, returns or stores a username, a token or a path with a record id. The only identity
that leaves this function is the organisation suffix (the text after '@').

Event: {"day": "YYYY-MM-DD"} (optional; default = yesterday in Asia/Kolkata), {"dry_run": true}
to skip the database write and return the counts.
"""
import base64
import datetime as dt
import json
import os
import time
from collections import Counter

import boto3

LOG_GROUP = os.environ.get("WAF_LOG_GROUP", "aws-waf-logs-ddos-blocked")
LB_MATCH = os.environ.get("LB_MATCH", "prod-openchs-load-balancer")
DB_FUNCTION = os.environ.get("DB_FUNCTION", "avni-usage-metrics-db")
METRIC_NS = "AvniUsageMetrics"
IST = dt.timezone(dt.timedelta(hours=5, minutes=30))
MAX_ROWS = 10000

logs = boto3.client("logs")
lam = boto3.client("lambda")
cw = boto3.client("cloudwatch")

BASE = f'''fields httpRequest.uri as uri, httpRequest.httpMethod as method
| filter httpSourceId like /{LB_MATCH}/ and action = "ALLOW"'''

# Web saves: fetchJson path, carries user-name. Only the suffix is parsed.
WEB_SAVES = BASE + '''
| filter method = "POST" and uri in ["/web/individuals", "/web/programEnrolments", "/web/programEncounters", "/web/encounters"]
| parse @message /(?i)"name":"user-name","value":"[^"]*@(?<suffix>[^"@]+)"/
| stats count(*) as n by suffix, uri'''

SAVE_MEASURE = {
    "/web/individuals": "Subjects saved on the web",
    "/web/programEnrolments": "Enrolments saved on the web",
    "/web/programEncounters": "Visits saved on the web",
    "/web/encounters": "Visits saved on the web",
}

# Media views and voids: axios path. Header if present, else token, grouped so each distinct
# token appears once per window.
IDENTITY = '''
| parse @message /(?i)"name":"user-name","value":"[^"]*@(?<suffix>[^"@]+)"/
| parse @message /(?i)"name":"auth-token","value":"(?<tok>[^"]+)"/
| stats count(*) as n by suffix, tok'''

MEDIA_VIEWS = BASE + '''
| filter (method = "GET" and uri = "/media/signedUrl") or (method = "POST" and uri = "/media/signedUrls")''' + IDENTITY

VOIDS = BASE + r'''
| filter method = "DELETE" and uri like /^\/web\/(subject|encounter|programEnrolment|programEncounter)\/[0-9a-fA-F-]+$/''' + IDENTITY


def day_window(day):
    start = int(dt.datetime.combine(day, dt.time(), IST).timestamp())
    return start, start + 86400


def run_query(query, start, end):
    qid = logs.start_query(logGroupName=LOG_GROUP, startTime=start, endTime=end,
                           queryString=query, limit=MAX_ROWS)["queryId"]
    while True:
        r = logs.get_query_results(queryId=qid)
        if r["status"] in ("Complete", "Failed", "Cancelled", "Timeout", "Unknown"):
            break
        time.sleep(2)
    if r["status"] != "Complete":
        raise RuntimeError(f"Logs Insights query {r['status']}")
    return [{c["field"]: c["value"] for c in row} for row in r["results"]]


def run_split(query, start, end):
    """Run over [start, end); halve the window whenever a result could have been truncated."""
    rows = run_query(query, start, end)
    if len(rows) < MAX_ROWS or end - start <= 900:
        if len(rows) >= MAX_ROWS:
            raise RuntimeError("more than 10,000 groups in a 15-minute window")
        return rows
    mid = start + (end - start) // 2
    return run_split(query, start, mid) + run_split(query, mid, end)


def suffix_from_token(tok):
    """Username suffix from a JWT payload, decoded in memory without verification. Never logged."""
    try:
        payload = tok.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        username = (claims.get("cognito:username") or claims.get("username")
                    or claims.get("preferred_username") or "")
        return username.rsplit("@", 1)[1] if "@" in username else None
    except Exception:
        return None


def identity_counts(rows):
    by_suffix, no_identity = Counter(), 0
    for row in rows:
        n = int(row.get("n", 0))
        suffix = row.get("suffix") or (suffix_from_token(row["tok"]) if row.get("tok") else None)
        if suffix:
            by_suffix[suffix.lower()] += n
        else:
            no_identity += n
    return by_suffix, no_identity


def handler(event, context):
    event = event or {}
    day = (dt.date.fromisoformat(event["day"]) if event.get("day")
           else dt.datetime.now(IST).date() - dt.timedelta(days=1))
    start, end = day_window(day)

    counts = Counter()
    no_identity = Counter()

    for row in run_query(WEB_SAVES, start, end):
        measure = SAVE_MEASURE.get(row.get("uri"))
        n = int(row.get("n", 0))
        if not measure:
            continue
        if row.get("suffix"):
            counts[(row["suffix"].lower(), "Data entry app against the phone", measure)] += n
        else:
            no_identity["web_saves"] += n

    for feature, measure, query in (("Media", "Images opened on the web", MEDIA_VIEWS),
                                    ("Voids", "Records voided on the web", VOIDS)):
        by_suffix, missing = identity_counts(run_split(query, start, end))
        for suffix, n in by_suffix.items():
            counts[(suffix, feature, measure)] += n
        no_identity[feature] += missing

    payload = {
        "day": day.isoformat(),
        "dry_run": bool(event.get("dry_run")),
        "counts": [{"suffix": s, "feature": f, "measure": m, "value": v} for (s, f, m), v in counts.items()],
    }
    if payload["dry_run"]:
        return {"day": payload["day"], "rows": len(payload["counts"]), "no_identity": dict(no_identity)}

    resp = lam.invoke(FunctionName=DB_FUNCTION, InvocationType="RequestResponse",
                      Payload=json.dumps(payload).encode())
    result = json.loads(resp["Payload"].read())
    if resp.get("FunctionError"):
        raise RuntimeError(f"db function failed: {result.get('errorMessage', 'unknown')}")

    total = sum(counts.values()) + sum(no_identity.values())
    unmatched = result.get("unmatched_value", 0) + sum(no_identity.values())
    web_saves = sum(v for (s, f, m), v in counts.items() if f == "Data entry app against the phone")
    cw.put_metric_data(Namespace=METRIC_NS, MetricData=[
        {"MetricName": "WebSaves", "Value": web_saves, "Unit": "Count"},
        {"MetricName": "UnmatchedPercent", "Value": (100.0 * unmatched / total) if total else 0.0, "Unit": "Percent"},
    ])
    return {"day": payload["day"], "web_saves": web_saves, "no_identity": dict(no_identity), **result}
