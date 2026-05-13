# Tanuh Metabase — DB bootstrap on prod openchs RDS

This document is the **one-time, manual, witnessed** runbook for creating the `tanuh_reporting_db` database and `tanuh_metabase_user` role on the existing prod openchs RDS.

It is intentionally not automated. The prod openchs RDS hosts production-critical data; every DDL step is a human-driven `psql` command against a fresh snapshot.

There is **no Makefile target** that runs these commands. There **must not be**.

---

## Prerequisites

- The prod RDS endpoint: `proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com` (Postgres 16.8).
- The Tanuh EC2 must already exist (run `aws_setup.sh` first). **All psql commands run from the EC2**, not your laptop — the RDS only accepts traffic from the reporting VPC CIDR via peering, so direct laptop access is blocked by the SG.
- RDS **master** credentials, retrieved from your secrets store (NOT committed anywhere). Look these up out-of-band; never paste them into a chat or this repo.
- The Tanuh app-user password — generate a fresh strong random secret now (e.g. `openssl rand -base64 24`) and stash it temporarily; you'll set it on the role and then write it into the ansible vault.
- `aws` CLI v2 (on your laptop) for the snapshot step.

## Where to run the commands

| Step | Run from | Why |
|---|---|---|
| Snapshot (`aws rds create-db-snapshot`) | Laptop | API call, doesn't need network reach to RDS. |
| `psql` connect as master | Tanuh EC2 (SSH first) | RDS SG only allows the reporting VPC CIDR. |
| `psql` verify as app user | Tanuh EC2 | Same reason. |
| `ansible-vault edit` | Laptop | Encrypted-file edit. |

---

## Phase 0 — pre-flight (read-only)

SSH into the Tanuh EC2 first. The RDS is unreachable from your laptop.

```bash
ssh -i ~/.ssh/openchs-infra.pem ubuntu@ssh.tanuh-reporting.avniproject.org
```

On the EC2, install psql if needed and connect:

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client

export PGHOST=proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com
export PGUSER=<master>
export PGDATABASE=postgres
export PGSSLMODE=require

psql -c "SHOW max_connections;"
psql -c "SELECT count(*) FROM pg_stat_activity;"

psql -c "SELECT 1 FROM pg_database WHERE datname='tanuh_reporting_db';"
psql -c "SELECT 1 FROM pg_roles    WHERE rolname='tanuh_metabase_user';"
```

**Expected:**
- `max_connections` minus `count(*)` ≥ 50 (headroom for the new Metabase + 15-connection pool).
- Both probe queries return 0 rows. If either returns a row, **stop** — the bootstrap has already happened (or there's a name collision). Investigate before continuing.

---

## Phase 1 — verify PITR/automated backups cover the change window

A manual snapshot is **not required** if automated backups + PITR are healthy. The DDL we're running (CREATE USER, CREATE DATABASE, REVOKE/GRANT on the new DB) is reversible in seconds via `DROP DATABASE`/`DROP USER` and never touches any existing database. The catastrophic-case rollback is PITR.

Verify (from laptop):

```bash
aws rds describe-db-instances --region ap-south-1 --db-instance-identifier proddb02 \
  --query 'DBInstances[].{Retention:BackupRetentionPeriod,LatestRestoreTime:LatestRestorableTime}'
```

Required: `BackupRetentionPeriod` ≥ 7, `LatestRestoreTime` within the last 10 minutes. If either is off, take an explicit manual snapshot before proceeding:

```bash
SNAP_ID="proddb02-pre-tanuh-$(date +%Y%m%d-%H%M)"
aws rds create-db-snapshot --region ap-south-1 \
  --db-instance-identifier proddb02 --db-snapshot-identifier "$SNAP_ID"
aws rds wait db-snapshot-available --region ap-south-1 --db-snapshot-identifier "$SNAP_ID"
```

---

## Phase 2 — create role + database

Connect as master from the Tanuh EC2:

```bash
psql "host=proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com user=<master> dbname=postgres sslmode=require"
```

In the psql prompt, **set the password** as a variable so it never lands in history. The `\set` form keeps it out of the on-disk `~/.psql_history` for the `CREATE USER` statement itself.

```sql
\set pw '''<your-generated-password>'''
```

Re-run the probes to make sure nothing changed since Phase 0:

```sql
SELECT 1 FROM pg_database WHERE datname='tanuh_reporting_db';
SELECT 1 FROM pg_roles    WHERE rolname='tanuh_metabase_user';
```

Both must return 0 rows. **If they don't, stop.**

Create the role (autocommit; no transaction):

```sql
CREATE USER tanuh_metabase_user WITH PASSWORD :pw
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
```

Create the database (autocommit — `CREATE DATABASE` cannot run in a transaction):

```sql
CREATE DATABASE tanuh_reporting_db OWNER tanuh_metabase_user
  ENCODING 'UTF8'
  LC_COLLATE 'en_US.UTF-8'
  LC_CTYPE   'en_US.UTF-8'
  TEMPLATE   template0;
```

`OWNER tanuh_metabase_user` gives the app user full privileges on its DB — that's sufficient for Metabase. Skipping `REVOKE ALL ON DATABASE ... FROM PUBLIC` to match the existing `reportingdb` convention; the additional hardening can be added later as a separate change if desired.

Exit psql: `\q`.

---

## Phase 3 — verify as the app user

From the **Tanuh EC2** (so you're inside the reporting VPC and the SG/peering path is exercised):

```bash
ssh ubuntu@ssh.tanuh-reporting.avniproject.org
psql "host=<prod-rds-endpoint> user=tanuh_metabase_user dbname=tanuh_reporting_db sslmode=require"
```

You should land in a `tanuh_reporting_db=>` prompt. Run:

```sql
\conninfo
\dn
SELECT current_user, current_database();
```

`current_user` should be `tanuh_metabase_user`, `current_database` should be `tanuh_reporting_db`. Exit.

---

## Phase 4 — record the password in the vault

Add to `configure/group_vars/prod-secret-vars.yml.enc` via:

```bash
cd configure
ansible-vault edit group_vars/prod-secret-vars.yml.enc
```

Add (or update) these keys:

```yaml
tanuh_mb_db_dbname: "tanuh_reporting_db"
tanuh_mb_db_user:   "tanuh_metabase_user"
tanuh_mb_db_pass:   "<your-generated-password>"
tanuh_mb_db_host:   "<prod-rds-endpoint>"
```

**Do not** commit the password in plaintext anywhere. The vault is the only place it lives.

After saving the vault, confirm the file still decrypts cleanly:

```bash
ansible-vault view group_vars/prod-secret-vars.yml.enc > /dev/null && echo OK
```

---

## Open follow-up: rotate the initial password

The first deploy may have used a weak interim password (validation of the deploy flow). Once the Tanuh Metabase is running healthily, rotate to a strong random:

```bash
# generate a new strong password
NEW_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

# on the Tanuh EC2, connect as RDS master and rotate
psql "host=proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com user=<master> dbname=postgres sslmode=require" \
  -c "ALTER USER tanuh_metabase_user WITH PASSWORD '$NEW_PASS';"

# update the vault on your laptop
ansible-vault edit configure/group_vars/prod-secret-vars.yml.enc
# ... change tanuh_mb_db_pass to the new value ...

# redeploy to refresh the env file on the container
cd configure && make tanuh-metabase-prod
```

## Rollback

**Only valid before Metabase first-run populates the DB** (i.e., before you run `make tanuh-metabase-prod` for the first time). After first-run, the DB has Metabase's own data and rollback = restore from the snapshot.

```sql
-- as master, NOT connected to tanuh_reporting_db
DROP DATABASE tanuh_reporting_db;
DROP USER tanuh_metabase_user;
```

If you need to restore from the snapshot, follow the standard RDS restore procedure (creates a new RDS instance from the snapshot; you then need to swap or restore data into the live RDS — heavy, plan accordingly).

---

## Final checks

- Phase 0 re-run probes return 1 row each (DB exists, role exists).
- Phase 3 connection as `tanuh_metabase_user` succeeds.
- Vault file decrypts cleanly with the four `tanuh_mb_*` keys present.
- Snapshot `proddb02-pre-tanuh-YYYYMMDD-HHMM` shows `available` in `aws rds describe-db-snapshots`.

Once all four are true, proceed to `make tanuh-metabase-prod -- --skip-tags metabase_db_trigger` from `configure/`.
