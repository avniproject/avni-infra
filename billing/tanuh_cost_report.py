#!/usr/bin/env python3
"""
Build and email the monthly Tanuh AWS cost report.

Pulls the previous calendar month's spend (plus the month before, for a
month-on-month delta) for resources tagged ``Client=tanuh``, grouped by AWS
service, and emails a plain-text + HTML report via SES.

Security notes (this runs in a PUBLIC-repo GitHub Actions workflow, so its
stdout is world-readable):
  * The report body — which contains confidential client cost figures — is
    NEVER written to stdout. Only a non-sensitive status line is printed.
  * Recipients come from the env var TANUH_COST_REPORT_RECIPIENTS and are
    rejected unless their domain is in ALLOWED_RECIPIENT_DOMAINS.
  * The --month override is validated (YYYY-MM, not in the future) before any
    AWS call.

Only direct, tag-attributable costs are reported. Shared services (RDS,
reporting-alb, the S3 media bucket, avni-etl compute, Cognito) carry no
Client tag and are listed as explicit exclusions, not apportioned.

Env vars:
  TANUH_COST_REPORT_RECIPIENTS  comma-separated recipient addresses (required
                                unless DRY_RUN)
  COST_REPORT_SENDER            From address (default noreply@avniproject.org;
                                must match the ses:FromAddress IAM condition)
  ALLOWED_RECIPIENT_DOMAINS     comma-separated allowlist (default
                                samanvayfoundation.org,avniproject.org)
  SES_REGION                    SES region (default ap-south-1)
  COST_TAG_KEY / COST_TAG_VALUE cost-allocation tag (default Client / tanuh)
  DRY_RUN                       if set, skip SES; write the report to
                                REPORT_OUT instead of emailing
  REPORT_OUT                    dry-run output path (default
                                /tmp/tanuh_cost_report.html)

Usage:
  python3 tanuh_cost_report.py                 # previous calendar month
  python3 tanuh_cost_report.py --month 2026-05 # explicit month (re-run)
"""

import argparse
import datetime as dt
import os
import re
import sys

import boto3

# Cost Explorer is a global service reachable only via the us-east-1 endpoint,
# regardless of where the tagged resources actually live (ap-south-1 here).
CE_REGION = "us-east-1"

DEFAULT_SENDER = "noreply@avniproject.org"
DEFAULT_ALLOWED_DOMAINS = ["samanvayfoundation.org", "avniproject.org"]

# Shared, untagged resources whose cost is NOT attributable to Tanuh by tag.
# Listed verbatim in every report so the reader knows what's excluded.
EXCLUDED_SHARED_SERVICES = [
    "RDS proddb02 (the tanuh_reporting_db database on the shared instance)",
    "reporting-alb (Application Load Balancer, shared with Avni Metabase)",
    "S3 media bucket (Tanuh media lives under a per-org prefix in the shared bucket)",
    "avni-etl compute (de-identified ETL runs on shared Avni infrastructure)",
    "Cognito (shared user pool / IDP)",
]

MONTH_RE = re.compile(r"\d{4}-\d{2}")


def first_of_month(d: dt.date) -> dt.date:
    return d.replace(day=1)


def add_month(d: dt.date) -> dt.date:
    """First day of the month after the month containing d."""
    if d.month == 12:
        return dt.date(d.year + 1, 1, 1)
    return dt.date(d.year, d.month + 1, 1)


def resolve_month(arg_month: str | None, today: dt.date) -> dt.date:
    """Return the first-of-month date for the month to report on.

    Defaults to the previous calendar month. An explicit --month must be
    YYYY-MM and must not be in the future (current/past months only).
    """
    current_first = first_of_month(today)
    if arg_month is None:
        # previous month = day before the 1st of this month, normalised to its 1st
        return first_of_month(current_first - dt.timedelta(days=1))

    if not MONTH_RE.fullmatch(arg_month):
        sys.exit(f"error: --month must be YYYY-MM, got {arg_month!r}")
    year, month = int(arg_month[:4]), int(arg_month[5:7])
    if not 1 <= month <= 12:
        sys.exit(f"error: --month has an invalid month component: {arg_month!r}")
    target_first = dt.date(year, month, 1)
    if target_first > current_first:
        sys.exit(f"error: --month {arg_month} is in the future")
    return target_first


def resolve_recipients() -> list[str]:
    raw = os.environ.get("TANUH_COST_REPORT_RECIPIENTS", "").strip()
    if not raw:
        sys.exit("error: TANUH_COST_REPORT_RECIPIENTS is empty")
    allowed = {
        d.strip().lower()
        for d in os.environ.get(
            "ALLOWED_RECIPIENT_DOMAINS", ",".join(DEFAULT_ALLOWED_DOMAINS)
        ).split(",")
        if d.strip()
    }
    recipients, rejected = [], []
    for addr in (a.strip() for a in raw.split(",") if a.strip()):
        domain = addr.rsplit("@", 1)[-1].lower() if "@" in addr else ""
        if domain in allowed:
            recipients.append(addr)
        else:
            rejected.append(addr)
    if rejected:
        # Names only name domains, not the full report — safe to surface.
        sys.exit(
            "error: recipient(s) outside the allowed domains "
            f"{sorted(allowed)}: {rejected}"
        )
    if not recipients:
        sys.exit("error: no valid recipients after domain allowlist filtering")
    return recipients


def query_costs(tag_key: str, tag_value: str, target_first: dt.date):
    """Return (services, target_total, prev_total, unit).

    services: list of (service_name, amount) for the target month, descending.
    A single CE call spans the previous month + the target month so we get the
    month-on-month comparison without a second round-trip.
    """
    ce = boto3.client("ce", region_name=CE_REGION)
    prev_first = first_of_month(target_first - dt.timedelta(days=1))
    end_exclusive = add_month(target_first)

    resp = ce.get_cost_and_usage(
        TimePeriod={
            "Start": prev_first.isoformat(),
            "End": end_exclusive.isoformat(),
        },
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        Filter={
            "Tags": {
                "Key": tag_key,
                "Values": [tag_value],
                "MatchOptions": ["EQUALS"],
            }
        },
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    buckets = resp.get("ResultsByTime", [])

    def bucket_for(month_first: dt.date):
        key = month_first.isoformat()
        for b in buckets:
            if b["TimePeriod"]["Start"] == key:
                return b
        return None

    target_bucket = bucket_for(target_first)
    prev_bucket = bucket_for(prev_first)

    unit = "USD"
    services = []
    target_total = 0.0
    if target_bucket:
        for g in target_bucket.get("Groups", []):
            amount = float(g["Metrics"]["UnblendedCost"]["Amount"])
            unit = g["Metrics"]["UnblendedCost"].get("Unit", unit)
            services.append((g["Keys"][0], amount))
            target_total += amount
    services.sort(key=lambda s: s[1], reverse=True)

    prev_total = 0.0
    if prev_bucket:
        for g in prev_bucket.get("Groups", []):
            prev_total += float(g["Metrics"]["UnblendedCost"]["Amount"])

    return services, target_total, prev_total, unit


def build_report(target_first, services, target_total, prev_total, unit, tag_kv):
    month_label = target_first.strftime("%B %Y")
    delta = target_total - prev_total
    if prev_total > 0:
        delta_pct = f"{delta / prev_total * 100:+.1f}%"
    else:
        delta_pct = "n/a (no prior-month data)"

    subject = f"Tanuh AWS cost report — {month_label}"

    # ---- plain text ----
    lines = [
        f"Tanuh AWS cost report — {month_label}",
        f"(direct costs tagged {tag_kv}, ap-south-1)",
        "",
        f"{'Service':40} {'Cost':>14}",
        f"{'-' * 40} {'-' * 14}",
    ]
    if services:
        for name, amount in services:
            lines.append(f"{name[:40]:40} {amount:>11.2f} {unit}")
    else:
        lines.append("(no tagged cost for this month — see note below)")
    lines += [
        f"{'-' * 40} {'-' * 14}",
        f"{'TOTAL':40} {target_total:>11.2f} {unit}",
        "",
        f"Previous month: {prev_total:.2f} {unit}",
        f"Month on month: {delta:+.2f} {unit} ({delta_pct})",
        "",
        "Excluded shared services (not tag-attributable; not billed here):",
    ]
    lines += [f"  - {s}" for s in EXCLUDED_SHARED_SERVICES]
    lines += [
        "",
        "Cost-allocation tags are not retroactive: spend is attributable only",
        "from the date the tag was activated. See COST_TRACKING.md.",
    ]
    text = "\n".join(lines)

    # ---- HTML ----
    rows = "".join(
        f"<tr><td>{name}</td><td style='text-align:right'>"
        f"{amount:.2f} {unit}</td></tr>"
        for name, amount in services
    ) or (
        "<tr><td colspan='2'><em>no tagged cost for this month</em></td></tr>"
    )
    excl = "".join(f"<li>{s}</li>" for s in EXCLUDED_SHARED_SERVICES)
    html = f"""<html><body style="font-family:sans-serif">
<h2>Tanuh AWS cost report — {month_label}</h2>
<p style="color:#666">Direct costs tagged <code>{tag_kv}</code>, ap-south-1.</p>
<table cellpadding="6" style="border-collapse:collapse">
<thead><tr><th style="text-align:left">Service</th>
<th style="text-align:right">Cost</th></tr></thead>
<tbody>{rows}</tbody>
<tfoot><tr style="font-weight:bold;border-top:2px solid #333">
<td>TOTAL</td><td style="text-align:right">{target_total:.2f} {unit}</td></tr></tfoot>
</table>
<p>Previous month: {prev_total:.2f} {unit}<br>
Month on month: <strong>{delta:+.2f} {unit} ({delta_pct})</strong></p>
<h4>Excluded shared services (not tag-attributable; not billed here)</h4>
<ul>{excl}</ul>
<p style="color:#666;font-size:90%">Cost-allocation tags are not retroactive:
spend is attributable only from the date the tag was activated.
See <code>COST_TRACKING.md</code>.</p>
</body></html>"""

    return subject, text, html


def main() -> int:
    parser = argparse.ArgumentParser(description="Email the monthly Tanuh AWS cost report.")
    parser.add_argument("--month", help="Month to report (YYYY-MM); default = previous month")
    args = parser.parse_args()

    tag_key = os.environ.get("COST_TAG_KEY", "Client")
    tag_value = os.environ.get("COST_TAG_VALUE", "tanuh")
    sender = os.environ.get("COST_REPORT_SENDER", DEFAULT_SENDER)
    dry_run = bool(os.environ.get("DRY_RUN"))

    today = dt.date.today()
    target_first = resolve_month(args.month, today)
    month_iso = target_first.strftime("%Y-%m")

    # Resolve/validate recipients up front (skipped in dry-run) so we fail
    # before doing any AWS work if the config is wrong.
    recipients = [] if dry_run else resolve_recipients()

    services, target_total, prev_total, unit = query_costs(tag_key, tag_value, target_first)
    subject, text, html = build_report(
        target_first, services, target_total, prev_total, unit, f"{tag_key}={tag_value}"
    )

    if dry_run:
        out = os.environ.get("REPORT_OUT", "/tmp/tanuh_cost_report.html")
        with open(out, "w") as fh:
            fh.write(html)
        # Deliberately do NOT print the report or the total to stdout.
        print(f"DRY_RUN: wrote {month_iso} report to {out} (not emailed)")
        return 0

    ses = boto3.client("ses", region_name=os.environ.get("SES_REGION", "ap-south-1"))
    ses.send_email(
        Source=sender,
        Destination={"ToAddresses": recipients},
        Message={
            "Subject": {"Data": subject},
            "Body": {"Text": {"Data": text}, "Html": {"Data": html}},
        },
    )
    # Status line only — no cost figures (public Actions log).
    print(f"sent {month_iso} Tanuh cost report to {len(recipients)} recipient(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
