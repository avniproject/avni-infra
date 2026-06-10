# Tanuh AWS Cost Tracking

Tanuh's interim hosting runs in the **shared Avni AWS account `118388513628`,
region `ap-south-1`**. To bill Tanuh for its share, every Tanuh-dedicated
resource carries the cost-allocation tag **`Client=tanuh`**, and a monthly
GitHub Actions workflow emails the previous month's tagged spend to the
operations team.

> **Attribution model: direct costs only.** Only resources that can carry a
> `Client=tanuh` tag are billed. Shared services (RDS, the ALB, the S3 media
> bucket, avni-etl compute, Cognito) are **not** apportioned — they're listed
> as explicit exclusions in every report.

## Tagging convention

`Client=<client>` on **every** resource dedicated to a single client. For
Tanuh that is:

| Resource | Identifier |
|---|---|
| EC2 instance + its EBS volume(s) | `tanuh-metabase` |
| Security group | `tanuh-metabase-sg` |
| ECR repository | `avniproject/tanuh-metabase` |
| ACM certificates | `tanuh-reporting.avniproject.org`, `tanuh.avniproject.org` |
| ALB target groups + listener rules | `tanuh-metabase`, `tanuh-webapp` (on shared `reporting-alb`) |
| IAM roles (no cost; tagged for inventory) | `tanuh-metabase-ec2-role`, `tanuh-metabase-gha-role` |

`aws_setup.sh` and `aws_alb_setup.sh` now stamp `Client=tanuh` at creation
time. The existing pre-tag resources were backfilled once with
[`aws_tag_client.sh`](./aws_tag_client.sh):

```bash
bash aws_tag_client.sh    # idempotent; skips anything not yet provisioned
```

> **Checklist:** any **new** Tanuh resource must get `Client=tanuh`. If you add
> a service that isn't taggable (or is genuinely shared), add it to the
> "Excluded shared services" list in `billing/tanuh_cost_report.py`.

## Activate the cost-allocation tag (one-time)

Tagging alone isn't enough — the key must be **activated** as a cost-allocation
tag before Cost Explorer can group by it:

```bash
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=Client,Status=Active
# verify:
aws ce list-cost-allocation-tags --tag-keys Client
```

Caveats:
- Takes **up to 24 h** to appear in Cost Explorer.
- **Not retroactive** — spend is attributable only from the activation date
  forward. The pre-activation period is back-billed once from a manual
  estimate (see the ops/finance note in `avni-product-ops`).

## Billing basis: on-demand list price (not tag-filtered Cost Explorer)

> **Important — why we do not bill straight off the `Client=tanuh` tag.** The
> tanuh-metabase EC2 instance is covered by a **Reserved Instance** in the
> shared account. RI-covered compute shows **$0 UnblendedCost**, and the RI
> charge that actually pays for it carries **no resource tag**. In-use **public
> IPv4** is likewise untagged. A tag-filtered report therefore bills only the
> disk + registry + transfer (~$0.50/mo) and silently drops the ~$33/mo of
> compute.

[`billing/tanuh_cost_report.py`](../../billing/tanuh_cost_report.py) instead
prices Tanuh's dedicated resources at **AWS on-demand list price**, computed
from **instance/volume metadata**:

- **EC2 compute** = instance running-hours in the month × the on-demand list
  rate for its type (from the rate card in the script, ap-south-1).
- **Public IPv4** = those hours × $0.005/h.
- **EBS** = volume GB × the gp3/gp2 list rate × (volume-hours / 730).
- **Variable tail** (data transfer, ECR storage, VPC peering) = read from the
  `Client=tanuh` Cost Explorer tag query, **excluding** any usage type already
  priced from metadata (so nothing is double-counted). This tail is ~$0 for
  months before the tag existed, which is immaterial.

This basis is RI-proof, partial-month-proof (proration by hours), and
**independently verifiable by the client** against AWS's public price list. Avni
keeps the benefit of its RI commitment — Tanuh pays what it would pay to run the
box itself. The rate card carries a `Verified <date>` comment; re-check it
~annually or whenever an instance is resized (the script fails loudly on an
unknown instance/volume type rather than mis-billing).

The cost-allocation tag is still activated and the resources still carry
`Client=tanuh` — it powers the variable-tail query and serves as a cross-check,
but it is **not** the headline figure. The script needs read-only
`ec2:DescribeInstances` / `ec2:DescribeVolumes` in addition to
`ce:GetCostAndUsage` (both in `cost-report-policy.json`).

The script **emails the bill itself** via SES. It is driven by
[`.github/workflows/tanuh-cost-report.yml`](../../.github/workflows/tanuh-cost-report.yml)
on the 2nd of each month (and `workflow_dispatch` for re-runs).

Local dry-run (no email; writes HTML to a file):

```bash
DRY_RUN=1 python3 billing/tanuh_cost_report.py --month 2026-05
# -> /tmp/tanuh_cost_report.html
```

### Security model (this repo is public)

- The report body has **confidential cost figures**, so the script **never
  prints it to stdout** — the public Actions log gets only a status line.
- IAM role `tanuh-cost-report-gha-role` trust is scoped to
  **`repo:avniproject/avni-infra:ref:refs/heads/master` exactly** (no
  `refs/heads/*` wildcard — that wildcard belongs to the build role, don't copy
  it). Permissions are `ce:GetCostAndUsage`, read-only
  `ec2:DescribeInstances` / `ec2:DescribeVolumes` (for list-price metadata), and
  `ses:SendEmail` gated by a `ses:FromAddress = avni@samanvayfoundation.org`
  condition.
- Recipients come from the repo **secret** `TANUH_COST_REPORT_RECIPIENTS`
  (not a world-readable variable); the script also rejects any recipient
  outside the `samanvayfoundation.org` / `avniproject.org` domains.
- The `workflow_dispatch` `month` input is regex-validated and passed via an
  env var, never inlined into a shell command.

### One-time IAM role setup

Reuses the GitHub OIDC provider already created by `aws_setup.sh`:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ACCOUNT_ID

envsubst < cost-report-trust-policy.json > /tmp/cr-trust.json
aws iam create-role \
  --role-name tanuh-cost-report-gha-role \
  --assume-role-policy-document file:///tmp/cr-trust.json \
  --tags Key=Project,Value=tanuh-metabase Key=Client,Value=tanuh Key=ManagedBy,Value=manual
rm -f /tmp/cr-trust.json

aws iam put-role-policy \
  --role-name tanuh-cost-report-gha-role \
  --policy-name tanuh-cost-report \
  --policy-document file://cost-report-policy.json
```

### SES prerequisite

The report is sent from **`avni@samanvayfoundation.org`, verified in
`us-east-1`**, which is already **out of the SES sandbox** (production access) —
so no new identity verification or DKIM setup is required. The workflow sets
`SES_REGION=us-east-1` and `COST_REPORT_SENDER=avni@samanvayfoundation.org`
accordingly; the `ses:FromAddress` IAM condition is pinned to the same address.

> ap-south-1 SES is intentionally **not** used here: at setup time it was in the
> sandbox with no verified identity. If the sender ever moves (e.g. to a
> dedicated `noreply@` identity), update three places together: the workflow
> env (`SES_REGION` / `COST_REPORT_SENDER`), the `ses:FromAddress` condition in
> `cost-report-policy.json`, and `DEFAULT_SENDER` in the script.

There is deliberately **no SMTP / third-party-action fallback**; if SES is
blocked, fix SES.
