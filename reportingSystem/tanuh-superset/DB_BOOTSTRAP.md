# Tanuh Superset — metadata DB bootstrap on proddb02

One-time, **manual, witnessed** runbook for creating Superset's **metadata DB**
`tanuh_reporting_superset_db` and its owner role `tanuh_superset_user` on the
existing `proddb02` RDS, then recording the credentials in the ansible vault.

Mirrors `reportingSystem/tanuh-metabase/DB_BOOTSTRAP.md` (Phase 2: the app user
owns its own DB). It is intentionally **not automated** — there is no Makefile
target that runs this DDL, and there must not be.

> **This is Superset's own application/metadata DB — NOT a reporting data
> source.** Never point `SUPERSET_DB_*` at `tanuh_reporting_db`, and never reuse
> the shared Avni-wide Superset metadata DB. The name is Tanuh-namespaced so it
> can't collide with that shared DB on the same server.

---

## Prerequisites

- RDS endpoint: `proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com`.
- **All `psql` runs from the Tanuh EC2** (`ssh.tanuh-reporting.avniproject.org`),
  not your laptop — the RDS SG only allows the reporting VPC CIDR.
- RDS **master** credentials, looked up out-of-band (never pasted into chat/repo).
- `sslmode=require` on every connection.

```bash
ssh -i ~/.ssh/openchs-infra.pem ubuntu@ssh.tanuh-reporting.avniproject.org
sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client
export PGHOST=proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com
export PGUSER=<master> PGDATABASE=postgres PGSSLMODE=require
```

## Phase 0 — pre-flight (read-only; both MUST return 0 rows)

```sql
SELECT 1 FROM pg_database WHERE datname='tanuh_reporting_superset_db';
SELECT 1 FROM pg_roles    WHERE rolname='tanuh_superset_user';
```

If either returns a row, **STOP** — bootstrap already happened or there's a name
collision. Investigate before continuing.

## Phase 1 — create the role + DB

```sql
\set pw '''<generate via: openssl rand -base64 24>'''

CREATE USER tanuh_superset_user WITH PASSWORD :pw
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

CREATE DATABASE tanuh_reporting_superset_db OWNER tanuh_superset_user
  ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;
```

Verify the app user can connect to its own DB (from the EC2):

```bash
PGPASSWORD='<pw>' psql "host=$PGHOST user=tanuh_superset_user dbname=tanuh_reporting_superset_db sslmode=require" -c '\conninfo'
```

**Rollback (only before Superset's first run populates it):**
```sql
DROP DATABASE tanuh_reporting_superset_db;
DROP USER tanuh_superset_user;
```

## Phase 2 — record secrets in the ansible vault

On your laptop: `cd configure && ansible-vault edit group_vars/prod-secret-vars.yml.enc`
(namespaced `tanuh_superset_*` keys, alongside the existing `tanuh_mb_db_*`):

```yaml
tanuh_superset_db_dbname: "tanuh_reporting_superset_db"
tanuh_superset_db_user:   "tanuh_superset_user"
tanuh_superset_db_pass:   "<the pw from Phase 1>"
tanuh_superset_db_host:   "proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com"

# Flask secret. Generate ONCE (openssl rand -base64 42) and NEVER rotate:
# rotating it invalidates sessions and breaks encrypted secrets stored in the
# metadata DB.
tanuh_superset_secret_key: "<openssl rand -base64 42>"

# First admin (used by the role's `superset fab create-admin`):
tanuh_superset_admin_username:  "admin"
tanuh_superset_admin_password:  "<openssl rand -base64 18>"
tanuh_superset_admin_email:     "<an ops email>"
# Optional — default to Tanuh / Admin:
# tanuh_superset_admin_firstname: "Tanuh"
# tanuh_superset_admin_lastname:  "Admin"
```

These keys are consumed by `configure/group_vars/tanuh_superset_docker_vars.yml`
→ rendered into `/root/tanuh_superset_docker.env` on the host by the
`tanuh_superset` role.

## Phase 3 — deploy

```bash
cd configure
make tanuh-superset-prod
```

First run pulls the image, starts the container on :8088, then runs
`superset db upgrade` → `fab create-admin` → `superset init` against the new
metadata DB. Re-runs are idempotent; skip the init with
`EXTRA_ARGS="--skip-tags superset_init"`.
