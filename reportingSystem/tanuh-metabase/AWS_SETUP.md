# Tanuh Metabase — AWS one-time setup

`aws_setup.sh` provisions the AWS infrastructure for the Tanuh Metabase stack. It is the source of truth for what gets created, in what order, with what scoping.

## What gets created

### `aws_setup.sh` (run first — one-time)

1. **ECR repository** `avniproject/tanuh-metabase` (ap-south-1), with image scanning on push.
2. **EC2 IAM role** `tanuh-metabase-ec2-role` + instance profile. Inline policy `tanuh-ecr-pull` grants scoped pull on the Tanuh ECR repo. Attached managed policy `AmazonSSMManagedInstanceCore` for Session Manager fallback.
3. **GitHub OIDC provider** (only if it doesn't exist in the account).
4. **GitHub Actions IAM role** `tanuh-metabase-gha-role` trusted by the `avniproject/avni-infra` repo for tags matching `tanuh-metabase-v*`, branches, and `master`. Inline policy `tanuh-ecr-push` grants scoped push on the Tanuh ECR repo.
5. **Security group** `tanuh-metabase-sg` in the reporting VPC:
   - Ingress 22/tcp from `$TEAM_SSH_CIDR`.
   - Ingress 3000/tcp from `172.10.0.0/16` (reporting VPC only — no public 3000).
6. **EC2 instance** `tanuh-metabase`: latest Canonical Ubuntu 22.04 LTS, `t3.medium`, 30 GB gp3, public IP, IMDSv2 required, in `Reporting Subnet A`, attached to the SG and IAM instance profile.
7. **Route53 A records** `tanuh-reporting.<zone>` and `ssh.tanuh-reporting.<zone>` pointing at the EC2 public IP.

### `aws_alb_setup.sh` (run after `make tanuh-metabase-prod` succeeds)

Wires the Tanuh EC2 behind the existing `reporting-alb` (Application Load Balancer) for HTTPS. Additive only — does not modify the existing prod metabase target group, listener default action, or default cert.

1. **ACM certificate** for `tanuh-reporting.avniproject.org`, DNS-validated via a CNAME in Route53. Auto-renews.
2. **Target group** `tanuh-metabase` in the reporting VPC (HTTP/3000, health check `/api/health`).
3. **Target registration**: the Tanuh EC2 added to the new target group.
4. **SG ingress**: tanuh-metabase-sg accepts 3000/tcp from the ALB's SG (alongside the existing VPC-CIDR rule which can be removed later).
5. **SNI cert attachment**: the Tanuh cert is added to the existing 443 listener as an additional cert (does not replace any existing cert).
6. **Listener rule** (priority 30): `Host: tanuh-reporting.avniproject.org` → tanuh-metabase target group.
7. **Route53 swap**: `tanuh-reporting.avniproject.org` changes from `A → EC2 IP` to `A ALIAS → reporting-alb`. (`ssh.tanuh-reporting...` stays as `A → EC2 IP` so SSH still works against the EC2's public IP.)

## Prerequisites

- `aws` CLI v2 configured with admin-equivalent permissions in the avni AWS account.
- `jq`, `envsubst` (part of `gettext`) installed locally.
- The reporting VPC (CIDR `172.10.0.0/16`) and the `reportingsubneta` subnet already exist (provisioned by `provision/reporting/networking.tf` historically).
- The EC2 SSH key pair `openchs-infra` exists in `ap-south-1`, and the private key is at `~/.ssh/openchs-infra.pem`.

## Running

```bash
cd reportingSystem/tanuh-metabase
TEAM_SSH_CIDR=1.2.3.4/32 bash aws_setup.sh
```

The script is **not idempotent**. Failures on "already exists" abort the run so you can investigate. Use `aws_teardown.sh` to roll back to a clean state, then re-run.

## After `aws_setup.sh`

1. Capture the GHA role ARN printed at the end of the run. Add it to `.github/workflows/build-tanuh-metabase.yml` (`role-to-assume`). (If the account ID matches the placeholder `118388513628`, no edit is needed.)
2. Bootstrap `tanuh_reporting_db` on the prod openchs RDS — see `DB_BOOTSTRAP.md`.
3. Edit the ansible vault to add the four `tanuh_mb_db_*` keys.
4. Build and push the first image (or push a git tag `tanuh-metabase-v…` to trigger CI).
5. From `configure/`, deploy: `make tanuh-metabase-prod EXTRA_ARGS="--skip-tags metabase_db_trigger"`.
6. SSH-tunnel to `localhost:3000` and claim admin.
7. Re-run with `EXTRA_ARGS="--tags metabase_db_trigger"` to install the schedule-protection trigger.

## After `make tanuh-metabase-prod` (HTTPS via ALB)

1. Run `bash aws_alb_setup.sh`. End-state: `https://tanuh-reporting.avniproject.org` serves the Tanuh Metabase with a valid ACM cert, port 3000 no longer needed from the public internet.
2. Optional hardening: revoke the 3000/172.10.0.0/16 SG rule on `tanuh-metabase-sg` (`aws_setup.sh` step 3) — ALB is the only intended ingress path now. Keep it if you want direct VPC-internal access for debugging.

## Teardown

Always tear down in reverse order: ALB wiring first, then base infra.

```bash
cd reportingSystem/tanuh-metabase
bash aws_alb_teardown.sh   # undo ALB wiring; restores Route53 A->IP
bash aws_teardown.sh       # undo base infra (EC2, IAM, SG, ECR repo)
```

`FORCE=1 bash aws_*_teardown.sh` skips the interactive confirmation. The GitHub OIDC provider is intentionally **not** deleted because it may be shared with other workloads.

## Recovering from a mid-script abort

If `aws_setup.sh` aborts partway:

1. Note which step failed (the log line preceding the error).
2. Either:
   - Delete the half-created resources from that step manually via `aws iam delete-role`, `aws ec2 delete-security-group`, etc., then re-run the whole script; or
   - Run `aws_teardown.sh` to clean everything, then re-run the setup.

The script is designed so a second run aborts on the first "already exists" — there's no in-place reconciliation.

## Region

Hardcoded to `ap-south-1`. Override with `REGION=...` env var if needed, but note that the EC2 SSH key pair, VPC, and RDS all live in `ap-south-1`, so this should never be changed.
