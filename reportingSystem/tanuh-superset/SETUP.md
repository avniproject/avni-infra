# Tanuh Superset — deploy runbook (avni-infra side)

Superset runs as a **second reporting container on the existing Tanuh EC2**
(the `[tanuh_metabase_server]` host), alongside Metabase, on port 8088, behind
the shared `reporting-alb` at `https://tanuh-reporting-superset.avniproject.org`.

The **image build** lives in the public repo `avniproject/tanuh-superset`
(Apache-2.0, consultant-facing). This repo only holds the **deploy glue** and
consumes the published ECR image tag.

> All resources are tagged `Client=tanuh` (ECR / ACM / ALB-TG) per
> `../tanuh-metabase/COST_TRACKING.md`.

## Files

| File | Purpose |
|---|---|
| `aws_ci_setup.sh` / `aws_ci_teardown.sh` | ECR repo `avniproject/tanuh-superset` + GitHub OIDC push role for the build repo's CI. One-time. |
| `aws_ec2_pull_grant.sh` | Adds a `tanuh-superset-ecr-pull` inline policy to the existing `tanuh-metabase-ec2-role` so the host can pull the image. |
| `DB_BOOTSTRAP.md` | Manual runbook: create `tanuh_reporting_superset_db` + `tanuh_superset_user` on proddb02, and the `tanuh_superset_*` vault keys. |
| `aws_alb_setup.sh` / `aws_alb_teardown.sh` | Wire `:8088` behind `reporting-alb` (ACM cert, target group health `/health`, listener rule, SG ingress, Route53 alias). |

The ansible deploy itself lives in `configure/`:
`prod_tanuh_superset_servers.yml`, `roles/tanuh_superset/`,
`group_vars/tanuh_superset_docker_vars.yml`, `make tanuh-superset-prod`.

## Order of operations

1. **CI infra (one-time):** `bash aws_ci_setup.sh` → set the printed role ARN in
   the build repo's `.github/workflows/build-and-push.yml` and enable the `v*`
   tag trigger. _(Done: `6.0.0-tanuh-1` is in ECR.)_
2. **EC2 pull grant:** `bash aws_ec2_pull_grant.sh`.
3. **Metadata DB:** follow `DB_BOOTSTRAP.md` — create the DB/role on proddb02 and
   add the `tanuh_superset_*` keys to `configure/group_vars/prod-secret-vars.yml.enc`.
4. **Deploy:** `cd ../../configure && make tanuh-superset-prod`. First run pulls
   the image, starts the container on :8088, then runs `superset db upgrade` →
   `fab create-admin` → `superset init`.
5. **HTTPS:** `bash aws_alb_setup.sh` (verify `LISTENER_PRIORITY` is a free slot
   on the 443 listener — Metabase uses 30).
6. **Verify** (see below).

## Memory budget (no instance resize)

Metabase is lowered to ~2 GB (`mb_memory_limit: 2g`, `java_opts: -Xmx1536m`,
in `configure/group_vars/tanuh_metabase_docker_vars.yml`) so Metabase ~2 GB +
Superset ~2 GB fit on the t3.medium (~3.7 GiB RAM + the existing 4 GB swap from
`tanuh_maintenance`). Superset gunicorn workers are pinned low (`2`).

## Verify

```bash
# Superset over HTTPS
curl -sI https://tanuh-reporting-superset.avniproject.org/health   # expect 200

# Metabase still serving (untouched apart from the lowered cap)
curl -sI https://tanuh-reporting.avniproject.org/api/health        # expect 200

# On the EC2: both containers up, memory under control
ssh ubuntu@ssh.tanuh-reporting.avniproject.org \
  'docker ps --format "{{.Names}}\t{{.Status}}"; free -m'
```

Watch `free -m` under a heavy dashboard load — sustained heavy swap = slow
dashboards; if so, revisit the caps or the instance size.

## Teardown (reverse order)

```bash
bash aws_alb_teardown.sh        # ALB wiring
# docker rm -f tanuh_superset   # on the EC2, if removing the container
aws iam delete-role-policy --role-name tanuh-metabase-ec2-role --policy-name tanuh-superset-ecr-pull
bash aws_ci_teardown.sh         # ECR repo + GHA role (last)
```

The metadata DB is dropped manually per `DB_BOOTSTRAP.md` rollback. The shared
OIDC provider and the reporting-alb are never deleted.
