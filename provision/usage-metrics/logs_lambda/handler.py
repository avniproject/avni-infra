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
from botocore.exceptions import ClientError
from concurrent.futures import ThreadPoolExecutor

LOG_GROUP = os.environ.get("WAF_LOG_GROUP", "aws-waf-logs-ddos-blocked")
LB_MATCH = os.environ.get("LB_MATCH", "prod-openchs-load-balancer")
DB_FUNCTION = os.environ.get("DB_FUNCTION", "avni-usage-metrics-db")
MEDIA_BUCKET = os.environ.get("MEDIA_BUCKET", "prod-user-media")
INVENTORY_BUCKET = os.environ.get("INVENTORY_BUCKET", "avni-usage-metrics-inventory-118388513628")
INVENTORY_ID = os.environ.get("INVENTORY_ID", "usage-metrics")
METRIC_NS = "AvniUsageMetrics"
IST = dt.timezone(dt.timedelta(hours=5, minutes=30))
MAX_ROWS = 10000

logs = boto3.client("logs")
lam = boto3.client("lambda")
cw = boto3.client("cloudwatch")
s3 = boto3.client("s3")

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


def log_available(start, end):
    """False when the day is older than the firewall log holds (it starts on 5 Sep 2026)."""
    try:
        run_query(BASE + "\n| limit 1", start, end)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "MalformedQueryException" and "retention" in str(e):
            return False
        raise


def media_counts():
    """[(folder, files stored, {IST day: files added})] from the latest daily S3 Inventory of the
    media bucket. Reads only each key's first path segment (the org's media folder) and its
    LastModifiedDate. Returns [] until the first inventory has been delivered."""
    import csv, gzip, io
    from urllib.parse import unquote
    base = f"{MEDIA_BUCKET}/{INVENTORY_ID}/"
    dates = [p["Prefix"] for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=INVENTORY_BUCKET, Prefix=base, Delimiter="/") for p in page.get("CommonPrefixes", [])]
    dates = sorted(d for d in dates if d[len(base):len(base) + 2].isdigit())
    manifest = None
    for d in reversed(dates):
        try:
            manifest = json.loads(s3.get_object(Bucket=INVENTORY_BUCKET, Key=d + "manifest.json")["Body"].read())
            break
        except ClientError as e:
            if e.response["Error"]["Code"] != "NoSuchKey":
                raise
    if manifest is None:
        return []
    cols = [c.strip() for c in manifest["fileSchema"].split(",")]
    k_key, k_mod = cols.index("Key"), cols.index("LastModifiedDate")
    stored, added = Counter(), {}
    for f in manifest["files"]:
        raw = s3.get_object(Bucket=INVENTORY_BUCKET, Key=f["key"])["Body"]
        with gzip.GzipFile(fileobj=raw) as gz:
            for row in csv.reader(io.TextIOWrapper(gz, encoding="utf-8")):
                folder = unquote(row[k_key]).split("/", 1)[0]
                stored[folder] += 1
                day = dt.datetime.fromisoformat(row[k_mod].replace("Z", "+00:00")).astimezone(IST).date().isoformat()
                added.setdefault(folder, Counter())[day] += 1
    return [(folder, n, added[folder]) for folder, n in stored.items()]


def invoke_db(payload):
    resp = lam.invoke(FunctionName=DB_FUNCTION, InvocationType="RequestResponse",
                      Payload=json.dumps(payload).encode())
    result = json.loads(resp["Payload"].read())
    if resp.get("FunctionError"):
        raise RuntimeError(f"db function failed: {result.get('errorMessage', 'unknown')}")
    return result


def media_history(event):
    """One-off: files added per org folder per day, for every day before today, from upload dates.
    Writes only the Media / Files added rows of each day."""
    folders = media_counts()
    by_day = {}
    today = dt.datetime.now(IST).date().isoformat()
    for folder, _, added in folders:
        for day, n in added.items():
            if event.get("since", "2000-01-01") <= day < min(today, event.get("until", today)):
                by_day.setdefault(day, []).append(
                    {"media_directory": folder, "feature": "Media", "measure": "Files added", "value": n})
    written = 0
    for day in sorted(by_day):
        invoke_db({"day": day, "counts": by_day[day], "replace": [["Media", "Files added"]], "skip_day_views": True})
        written += 1
    return {"media_history_days": written, "folders": len(folders)}


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
    if event.get("media_history"):
        return media_history(event)
    day = (dt.date.fromisoformat(event["day"]) if event.get("day")
           else dt.datetime.now(IST).date() - dt.timedelta(days=1))
    start, end = day_window(day)

    counts = Counter()
    no_identity = Counter()
    have_log = log_available(start, end)

    for row in (run_query(WEB_SAVES, start, end) if have_log else []):
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
        if not have_log:
            break
        by_suffix, missing = identity_counts(run_split(query, start, end))
        for suffix, n in by_suffix.items():
            counts[(suffix, feature, measure)] += n
        no_identity[feature] += missing

    payload = {
        "day": day.isoformat(),
        "dry_run": bool(event.get("dry_run")),
        "counts": [{"suffix": s, "feature": f, "measure": m, "value": v} for (s, f, m), v in counts.items()],
    }
    # Media: files stored now (only for the nightly run of yesterday) and files added that day.
    if event.get("media", not event.get("day")):
        for folder, stored, added in media_counts():
            payload["counts"].append({"media_directory": folder, "feature": "Media", "measure": "Files stored", "value": stored})
            if added.get(day.isoformat()):
                payload["counts"].append({"media_directory": folder, "feature": "Media", "measure": "Files added",
                                          "value": added[day.isoformat()]})
    if payload["dry_run"]:
        return {"day": payload["day"], "rows": len(payload["counts"]), "no_identity": dict(no_identity)}

    if not have_log:
        # Keep any web, media-view and void rows written while the log still held this day.
        payload["replace"] = [["Data entry app against the phone", m] for m in (
            "Subjects sent from phones", "Enrolments sent from phones", "Visits sent from phones")] + \
            [["Checklists", "Checklist items completed"]]
    result = invoke_db(payload)

    total = sum(counts.values()) + sum(no_identity.values())
    unmatched = result.get("unmatched_value", 0) + sum(no_identity.values())
    web_saves = sum(v for (s, f, m), v in counts.items() if f == "Data entry app against the phone")
    if not have_log:
        return {"day": payload["day"], "log_available": False, **result}
    cw.put_metric_data(Namespace=METRIC_NS, MetricData=[
        {"MetricName": "WebSaves", "Value": web_saves, "Unit": "Count"},
        {"MetricName": "UnmatchedPercent", "Value": (100.0 * unmatched / total) if total else 0.0, "Unit": "Percent"},
    ])
    return {"day": payload["day"], "web_saves": web_saves, "no_identity": dict(no_identity), **result}
