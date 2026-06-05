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

## Monthly report

[`billing/tanuh_cost_report.py`](../../billing/tanuh_cost_report.py) queries
Cost Explorer (previous month + the month before, for a month-on-month delta),
filtered to `Client=tanuh` and grouped by service, then **emails the report
itself** via SES. It is driven by
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
  it). Permissions are `ce:GetCostAndUsage` plus `ses:SendEmail` gated by a
  `ses:FromAddress = noreply@avniproject.org` condition.
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

Verify the `avniproject.org` domain identity in **ap-south-1** and confirm SES
**production access** (out of the sandbox). Domain verification needs DKIM
CNAME records added to the `avniproject.org` Route53 zone — **those CNAME
values are kept in the private ops runbook, not in this public repo.** There is
deliberately **no SMTP / third-party-action fallback**; if SES is blocked, fix
SES (request production access).
