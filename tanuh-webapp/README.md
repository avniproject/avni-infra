# Tanuh Webapp Deployment

Deploys the Vite/React SPA from
[avniproject/tanuh-webapp](https://github.com/avniproject/tanuh-webapp) to the
existing Tanuh Reporting EC2 (`t3.medium`, Ubuntu 22.04) and serves it at
`https://tanuh.avniproject.org` via the existing `reporting-alb`.

The same EC2 hosts the Tanuh-branded Metabase (Docker, port 3000) at
`https://tanuh-reporting.avniproject.org`. The webapp is a separate
host-based ALB route → nginx on port 8080 → static `dist/` files.

## Architecture

```
Browser ─► tanuh.avniproject.org ─► reporting-alb:443 (SNI cert per host)
                                      │
                                      ├─ Host: tanuh.avniproject.org ──► tanuh-webapp TG ──► EC2:8080 (nginx → /var/www/tanuh-webapp)
                                      └─ Host: tanuh-reporting.avniproject.org ──► tanuh-metabase TG ──► EC2:3000 (Metabase Docker)
```

Build & runtime live entirely on the EC2: Ansible installs Node 24,
clones the repo, runs `npm ci && npm run build` with `VITE_AVNI_API_BASE_URL`
injected via `.env.production`, and rsyncs `dist/` into the nginx docroot.

## One-time AWS wiring

Run from this directory:

```bash
bash aws_alb_setup.sh
```

This provisions (using the AWS CLI in the avni account):

- ACM cert for `tanuh.avniproject.org` (DNS-validated; CNAME added to Route53 hosted zone `avniproject.org`).
- Target group `tanuh-webapp` (HTTP/8080, health check `GET /`).
- Listener rule on the existing `reporting-alb` 443 listener (priority 31, host-header → TG).
- Security group ingress on `tanuh-metabase-sg`: 8080/tcp from the ALB SG.
- Route53 ALIAS `tanuh.avniproject.org` → `reporting-alb`.

The target will report **unhealthy** until the webapp role has been applied
(nginx isn't installed/serving on 8080 yet). That's fine — re-check after the
first `make tanuh-webapp-prod`.

To undo:

```bash
bash aws_alb_teardown.sh
```

## Per-release deploy

```bash
cd ../configure
VAULT_PASSWORD_FILE=~/.ssh/infra-valut-pwd-file make tanuh-webapp-prod
```

Ansible runs only the `tanuh_webapp`-tagged tasks against
`prod_tanuh_metabase_servers.yml`, so the Tanuh Metabase container is not
touched.

What it does on the host:

1. Ensures system user `tanuh-webapp` exists.
2. Installs Node 24 (NodeSource `setup_24.x`), git, rsync, nginx.
3. Clones / fast-forwards `https://github.com/avniproject/tanuh-webapp.git` to
   `/var/lib/tanuh-webapp-build` at the configured ref.
4. Writes `.env.production` with `VITE_AVNI_API_BASE_URL`.
5. `npm ci && npm run build`.
6. `rsync --delete dist/ → /var/www/tanuh-webapp/` (owned by `www-data`).
7. Renders + enables `/etc/nginx/sites-available/tanuh-webapp.conf`, reloads
   nginx.

Re-runs are cheap: `npm ci` skips when `node_modules/.package-lock.json` is
already present and the git HEAD hasn't moved; `npm run build` runs only when
the source or `.env.production` changed.

## UAT instance (same node)

A second, isolated instance of the physician app runs on the **same** Tanuh
Reporting EC2 for pre-production validation, at
`https://uat-tanuh.avniproject.org` (nginx `:8081`). It proxies to the same prod
Avni backend; data isolation is at the **org** level — UAT testers log in with
`Tanuh_UAT`-org accounts and only touch UAT data. Use it to validate a change
before promoting the prod instance.

```
Browser ─► uat-tanuh.avniproject.org ─► reporting-alb:443 (its own SNI cert)
                                          └─ Host: uat-tanuh.avniproject.org ──► tanuh-webapp-uat TG ──► EC2:8081 (nginx → /var/www/tanuh-webapp-uat)
```

Same `tanuh_webapp` role, instantiated with
`tanuh_webapp_instance_name: tanuh-webapp-uat` (→ docroot
`/var/www/tanuh-webapp-uat`, build dir `/var/lib/tanuh-webapp-uat-build`, nginx
`tanuh-webapp-uat.conf`, port 8081).

### One-time UAT AWS wiring

Run once, from this directory, before the first UAT deploy:

```bash
WEBAPP_HOSTNAME=uat-tanuh.avniproject.org \
TG_NAME=tanuh-webapp-uat TG_PORT=8081 LISTENER_PRIORITY=32 \
bash aws_alb_setup.sh
```

Provisions (additively — the prod wiring at priority 31 is untouched):

- ACM cert for `uat-tanuh.avniproject.org` (DNS-validated; its own SNI cert on the shared 443 listener).
- Target group `tanuh-webapp-uat` (HTTP/8081, health `GET /`).
- Listener rule **priority 32**, host-header `uat-tanuh.avniproject.org` → TG.
- Security group ingress on `tanuh-metabase-sg`: 8081/tcp from the ALB SG.
- Route53 ALIAS `uat-tanuh.avniproject.org` → `reporting-alb`.

Not idempotent. To undo (same UAT env):

```bash
WEBAPP_HOSTNAME=uat-tanuh.avniproject.org TG_NAME=tanuh-webapp-uat TG_PORT=8081 LISTENER_PRIORITY=32 bash aws_alb_teardown.sh
```

### UAT deploy

```bash
cd ../configure
VAULT_PASSWORD_FILE=~/.ssh/infra-valut-pwd-file make tanuh-webapp-uat
```

Runs only the `tanuh_webapp_uat`-tagged role application against
`prod_tanuh_metabase_servers.yml`. The prod webapp, Metabase and Superset on the
same host are **not** touched: the UAT role is guarded by
`when: 'tanuh_webapp_uat' in ansible_run_tags`, so `make tanuh-webapp-prod` and
untagged runs (`make tanuh-metabase-prod`) skip it entirely. UAT tracks `main`;
deploy a specific ref with
`make tanuh-webapp-uat EXTRA_ARGS='-e tanuh_webapp_git_ref=<ref>'`.

## Pinning a release

By default the role builds from `main`. To pin to a tag or commit SHA, set
`tanuh_webapp_git_ref` in
`configure/group_vars/tanuh_metabase_docker_vars.yml`:

```yaml
  tanuh_webapp_git_ref: "v1.2.3"   # or a 40-char commit SHA
```

Commit the change, then `make tanuh-webapp-prod`.

## Tunable variables

All defined in `configure/roles/tanuh_webapp/defaults/main.yml`. The two
worth knowing:

| Var | Default | Override via |
|---|---|---|
| `tanuh_webapp_avni_api_base_url` | `https://staging.avniproject.org` | `configure/group_vars/tanuh_metabase_docker_vars.yml` |
| `tanuh_webapp_git_ref` | `main` | same file |

## CORS prerequisite

The SPA is served cross-origin to the Avni server it talks to (`tanuh.avniproject.org`
calling `staging.avniproject.org`). The Avni server's CORS allow-origins
list must include `https://tanuh.avniproject.org` (with
`Access-Control-Allow-Credentials: true`). Without this, login and every
authenticated API call will be blocked by the browser even though the bundle
deploys cleanly.

This config change happens in the avni-server side (not in this repo).

## Verification

After `make tanuh-webapp-prod`:

```bash
# HTTP layer
curl -sI https://tanuh.avniproject.org/                              # expect 200, text/html
curl -sI https://tanuh-reporting.avniproject.org/api/health          # expect 200 (Metabase untouched)

# Bundle config baked in correctly
curl -s https://tanuh.avniproject.org/ | grep -oE 'assets/index-[^"]*\.js' | head -1
# then curl that asset and grep for staging.avniproject.org
```

ALB target health:

```bash
aws elbv2 describe-target-health --region ap-south-1 \
  --target-group-arn $(aws elbv2 describe-target-groups --region ap-south-1 \
    --names tanuh-webapp --query 'TargetGroups[0].TargetGroupArn' --output text)
```

Should show `State=healthy`.

## Rollback

`tanuh_webapp_git_ref` to the previous commit/tag, then re-run
`make tanuh-webapp-prod`. The bundle is rebuilt and the swap is fast (rsync of
~1 MB of static assets).

To fully detach: `bash aws_alb_teardown.sh` (removes only the webapp wiring;
Metabase keeps working). The on-host nginx config + docroot can be left in
place, or manually removed:

```bash
ssh ubuntu@ssh.tanuh-reporting.avniproject.org sudo rm -rf \
  /etc/nginx/sites-enabled/tanuh-webapp.conf \
  /etc/nginx/sites-available/tanuh-webapp.conf \
  /var/www/tanuh-webapp /var/lib/tanuh-webapp-build
ssh ubuntu@ssh.tanuh-reporting.avniproject.org sudo nginx -s reload
```
