#!/usr/bin/env python3
"""
Build and email the monthly Tanuh AWS pass-through bill.

Tanuh's reporting stack runs in Avni's shared AWS account. Tanuh is billed for
its dedicated resources at AWS **on-demand list price**, computed from instance
and volume **metadata** — NOT from cost-allocation tags.

Why metadata + list price instead of tag-filtered Cost Explorer:
  * The tanuh-metabase EC2 instance is covered by a **Reserved Instance** in the
    shared account, so its compute shows $0 UnblendedCost and the RI charge that
    actually pays for it carries no resource tag. A tag-filtered report would
    bill ~$0.50/mo and miss the ~$33/mo of compute entirely.
  * In-use **public IPv4** charges are not tagged to the instance either.
  * Pricing from list rates is transparent and independently verifiable by the
    client against AWS's public price list, and lets Avni keep the benefit of
    its RI commitment (a fair pass-through: Tanuh pays what it would pay to run
    the box itself).

So the headline figure = compute + public IPv4 + EBS, each priced from metadata
against the RATE CARD below, plus a small **variable tail** (data transfer, ECR
storage, VPC peering) read from Cost Explorer for the Client=tanuh tag. The tail
deliberately excludes any usage type already priced from metadata, so nothing is
double-counted. For pre-tag months (before the tag existed) the tail is ~$0,
which is immaterial.

Security notes (this runs in a PUBLIC-repo GitHub Actions workflow, so its
stdout is world-readable):
  * The report body — which contains confidential client cost figures — is
    NEVER written to stdout. Only a non-sensitive status line is printed.
  * Recipients come from the env var TANUH_COST_REPORT_RECIPIENTS and are
    rejected unless their domain is in ALLOWED_RECIPIENT_DOMAINS.
  * The --month override is validated (YYYY-MM, not in the future) before any
    AWS call.

Shared services (RDS, reporting-alb, the S3 media bucket, avni-etl compute,
Cognito) are shared across workloads and listed as explicit exclusions, not
apportioned.

Env vars:
  TANUH_COST_REPORT_RECIPIENTS  comma-separated recipient addresses (required
                                unless DRY_RUN)
  COST_REPORT_SENDER            From address (default avni@samanvayfoundation.org;
                                must be an SES-verified identity and match the
                                ses:FromAddress IAM condition for the role)
  ALLOWED_RECIPIENT_DOMAINS     comma-separated allowlist (default
                                samanvayfoundation.org,avniproject.org)
  SES_REGION                    SES region (default ap-south-1)
  RESOURCE_REGION               region the Tanuh resources live in (default
                                ap-south-1) — used for metadata lookups
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

# SES sender. avni@samanvayfoundation.org is verified in us-east-1, which is out
# of the SES sandbox; that is the address the ses:FromAddress IAM condition on
# tanuh-cost-report-gha-role allows.
DEFAULT_SENDER = "avni@samanvayfoundation.org"
DEFAULT_ALLOWED_DOMAINS = ["samanvayfoundation.org", "avniproject.org"]

# ---------------------------------------------------------------------------
# On-demand LIST-price rate card — ap-south-1 (Mumbai).
# Source: AWS public pricing pages. Verified 2026-06-10; re-check ~annually or
# if a Tanuh instance is resized / a new instance type or volume type appears
# (the script fails loudly on an unknown type rather than mis-billing).
# ---------------------------------------------------------------------------
HOURS_PER_MONTH = 730  # AWS convention for monthly (per-GB-month) proration

EC2_ONDEMAND_USD_PER_HOUR = {
    "t3.medium": 0.0448,
}
EBS_USD_PER_GB_MONTH = {
    "gp3": 0.0912,
    "gp2": 0.1140,
}
PUBLIC_IPV4_USD_PER_HOUR = 0.005  # in-use public IPv4, charged by AWS since Feb 2024

# Usage-type substrings already priced from metadata above. The Cost Explorer
# "variable tail" excludes these so they are never double-counted.
METADATA_PRICED_USAGE = ("BoxUsage", "SpotUsage", "EBS:VolumeUsage", "PublicIPv4")

# Shared, untagged resources whose cost is NOT attributable to Tanuh. Listed
# verbatim in every report so the reader knows what's excluded.
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
        sys.exit(
            "error: recipient(s) outside the allowed domains "
            f"{sorted(allowed)}: {rejected}"
        )
    if not recipients:
        sys.exit("error: no valid recipients after domain allowlist filtering")
    return recipients


# ---------------------------------------------------------------------------
# Metadata discovery + list pricing
# ---------------------------------------------------------------------------

def _month_dt_bounds(target_first: dt.date):
    end_first = add_month(target_first)
    start = dt.datetime(target_first.year, target_first.month, 1, tzinfo=dt.timezone.utc)
    end = dt.datetime(end_first.year, end_first.month, 1, tzinfo=dt.timezone.utc)
    return start, end


def _hours_overlap(res_start: dt.datetime, m_start: dt.datetime,
                   m_end: dt.datetime, now: dt.datetime) -> float:
    """Hours a resource existed within [m_start, m_end).

    Assumes the resource ran continuously from res_start until now — true for an
    always-on stack like tanuh-metabase. A stopped instance still incurs EBS but
    not compute; that nuance is out of scope for this steady-state biller.
    """
    start = max(res_start, m_start)
    end = min(m_end, now)
    if end <= start:
        return 0.0
    return (end - start).total_seconds() / 3600.0


def discover_resources(tag_key: str, tag_value: str, region: str):
    ec2 = boto3.client("ec2", region_name=region)
    instances = []
    for page in ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": f"tag:{tag_key}", "Values": [tag_value]}]
    ):
        for r in page["Reservations"]:
            instances.extend(r["Instances"])
    volumes = []
    for page in ec2.get_paginator("describe_volumes").paginate(
        Filters=[{"Name": f"tag:{tag_key}", "Values": [tag_value]}]
    ):
        volumes.extend(page["Volumes"])
    return instances, volumes


def price_from_metadata(instances, volumes, target_first: dt.date, now: dt.datetime):
    """Return (line_items, total) where line_items is [(label, detail, amount)]."""
    m_start, m_end = _month_dt_bounds(target_first)
    items: list[tuple[str, str, float]] = []

    for inst in instances:
        itype = inst["InstanceType"]
        hrs = _hours_overlap(inst["LaunchTime"], m_start, m_end, now)
        if hrs <= 0:
            continue
        rate = EC2_ONDEMAND_USD_PER_HOUR.get(itype)
        if rate is None:
            sys.exit(
                f"error: no rate-card entry for instance type {itype!r}; "
                "add it to EC2_ONDEMAND_USD_PER_HOUR (ap-south-1 on-demand list)"
            )
        items.append((f"EC2 {itype} compute", f"{hrs:.1f} h × ${rate}/h", hrs * rate))
        # In-use public IPv4: charged whenever the instance has a public address.
        # Current presence is used as a proxy for the whole month (always-on).
        if inst.get("PublicIpAddress"):
            items.append(
                ("Public IPv4", f"{hrs:.1f} h × ${PUBLIC_IPV4_USD_PER_HOUR}/h",
                 hrs * PUBLIC_IPV4_USD_PER_HOUR)
            )

    for vol in volumes:
        vtype = vol["VolumeType"]
        size = vol["Size"]
        vhrs = _hours_overlap(vol["CreateTime"], m_start, m_end, now)
        if vhrs <= 0:
            continue
        rate = EBS_USD_PER_GB_MONTH.get(vtype)
        if rate is None:
            sys.exit(
                f"error: no rate-card entry for volume type {vtype!r}; "
                "add it to EBS_USD_PER_GB_MONTH"
            )
        amount = size * rate * (vhrs / HOURS_PER_MONTH)
        items.append(
            (f"EBS {vtype} {size} GB", f"${rate}/GB-mo, {vhrs / 24:.1f} days", amount)
        )

    total = sum(a for _, _, a in items)
    return items, total


def variable_tail(tag_key: str, tag_value: str, target_first: dt.date) -> float:
    """Sum tagged usage NOT already priced from metadata (data transfer, ECR
    storage, VPC peering). Returns ~0 for months before the tag existed."""
    ce = boto3.client("ce", region_name=CE_REGION)
    end = add_month(target_first)
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": target_first.isoformat(), "End": end.isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        Filter={
            "Tags": {"Key": tag_key, "Values": [tag_value], "MatchOptions": ["EQUALS"]}
        },
        GroupBy=[{"Type": "DIMENSION", "Key": "USAGE_TYPE"}],
    )
    buckets = resp.get("ResultsByTime", [])
    if not buckets:
        return 0.0
    total = 0.0
    for g in buckets[0].get("Groups", []):
        usage_type = g["Keys"][0]
        if any(sub in usage_type for sub in METADATA_PRICED_USAGE):
            continue
        total += float(g["Metrics"]["UnblendedCost"]["Amount"])
    return total


# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------

def build_report(target_first, items, tail, total, prev_total, tag_kv):
    month_label = target_first.strftime("%B %Y")
    unit = "USD"
    delta = total - prev_total
    delta_pct = f"{delta / prev_total * 100:+.1f}%" if prev_total > 0 else "n/a (no prior-month data)"
    subject = f"Tanuh AWS bill — {month_label}"

    rows_txt = [f"{label[:34]:34} {detail[:24]:24} {amt:>10.2f}" for label, detail, amt in items]
    if tail > 0:
        rows_txt.append(f"{'Data transfer / ECR / peering':34} {'from Client=tanuh tags':24} {tail:>10.2f}")

    lines = [
        f"Tanuh AWS bill — {month_label}",
        "Basis: AWS on-demand LIST price for Tanuh's dedicated resources,",
        "priced from instance/volume metadata (ap-south-1).",
        "",
        f"{'Line item':34} {'Basis':24} {'USD':>10}",
        f"{'-' * 34} {'-' * 24} {'-' * 10}",
        *rows_txt,
        f"{'-' * 34} {'-' * 24} {'-' * 10}",
        f"{'TOTAL':59} {total:>10.2f} {unit}",
        "",
        f"Previous month: {prev_total:.2f} {unit}",
        f"Month on month: {delta:+.2f} {unit} ({delta_pct})",
        "",
        "Note: the tanuh-metabase instance is Reserved-Instance-covered in the",
        "shared account, so its compute is invisible to cost-allocation tags.",
        "It is billed here at on-demand list price (what Tanuh would pay to run",
        "the box itself); Avni retains the benefit of its RI commitment.",
        "",
        "Excluded shared services (not billed here):",
        *[f"  - {s}" for s in EXCLUDED_SHARED_SERVICES],
    ]
    text = "\n".join(lines)

    item_rows = "".join(
        f"<tr><td>{label}</td><td style='color:#666'>{detail}</td>"
        f"<td style='text-align:right'>{amt:.2f}</td></tr>"
        for label, detail, amt in items
    )
    if tail > 0:
        item_rows += (
            "<tr><td>Data transfer / ECR / peering</td>"
            "<td style='color:#666'>from <code>Client=tanuh</code> tags</td>"
            f"<td style='text-align:right'>{tail:.2f}</td></tr>"
        )
    excl = "".join(f"<li>{s}</li>" for s in EXCLUDED_SHARED_SERVICES)
    html = f"""<html><body style="font-family:sans-serif">
<h2>Tanuh AWS bill — {month_label}</h2>
<p style="color:#666">Basis: AWS on-demand <strong>list price</strong> for Tanuh's
dedicated resources, priced from instance/volume metadata (ap-south-1).</p>
<table cellpadding="6" style="border-collapse:collapse">
<thead><tr><th style="text-align:left">Line item</th>
<th style="text-align:left">Basis</th>
<th style="text-align:right">USD</th></tr></thead>
<tbody>{item_rows}</tbody>
<tfoot><tr style="font-weight:bold;border-top:2px solid #333">
<td colspan="2">TOTAL</td><td style="text-align:right">{total:.2f} {unit}</td></tr></tfoot>
</table>
<p>Previous month: {prev_total:.2f} {unit}<br>
Month on month: <strong>{delta:+.2f} {unit} ({delta_pct})</strong></p>
<p style="color:#666;font-size:90%">The tanuh-metabase instance is
Reserved-Instance-covered in the shared account, so its compute is invisible to
cost-allocation tags. It is billed here at on-demand list price (what Tanuh would
pay to run the box itself); Avni retains the benefit of its RI commitment.</p>
<h4>Excluded shared services (not billed here)</h4>
<ul>{excl}</ul>
</body></html>"""
    return subject, text, html


def main() -> int:
    parser = argparse.ArgumentParser(description="Email the monthly Tanuh AWS pass-through bill.")
    parser.add_argument("--month", help="Month to report (YYYY-MM); default = previous month")
    args = parser.parse_args()

    tag_key = os.environ.get("COST_TAG_KEY", "Client")
    tag_value = os.environ.get("COST_TAG_VALUE", "tanuh")
    sender = os.environ.get("COST_REPORT_SENDER", DEFAULT_SENDER)
    region = os.environ.get("RESOURCE_REGION", "ap-south-1")
    dry_run = bool(os.environ.get("DRY_RUN"))

    today = dt.date.today()
    target_first = resolve_month(args.month, today)
    month_iso = target_first.strftime("%Y-%m")

    # Resolve/validate recipients up front (skipped in dry-run) so we fail before
    # any AWS work if the config is wrong.
    recipients = [] if dry_run else resolve_recipients()

    now = dt.datetime.now(dt.timezone.utc)
    instances, volumes = discover_resources(tag_key, tag_value, region)
    items, meta_total = price_from_metadata(instances, volumes, target_first, now)
    tail = variable_tail(tag_key, tag_value, target_first)
    total = meta_total + tail

    prev_first = first_of_month(target_first - dt.timedelta(days=1))
    _, prev_meta = price_from_metadata(instances, volumes, prev_first, now)
    prev_total = prev_meta + variable_tail(tag_key, tag_value, prev_first)

    subject, text, html = build_report(
        target_first, items, tail, total, prev_total, f"{tag_key}={tag_value}"
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
    print(f"sent {month_iso} Tanuh bill to {len(recipients)} recipient(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
