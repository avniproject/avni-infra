-- Database prerequisites for avni-server. Run ONCE against a freshly created
-- load-test database, before the first deploy.
--
-- WHY THIS FILE EXISTS
--   The first deploy of avni-server crash-looped. Flyway got 488 migrations in,
--   reached schema 1.64, then failed:
--
--     Migration ... "1.64.5 - CreateNecessaryViewsForAddressLevel" failed!
--     SQL State : 42883
--     Message   : ERROR: function uuid_generate_v4() does not exist
--
--   The JVM exits, systemd restarts it, and it fails identically -- so the ALB
--   target never becomes healthy and /ping returns 502 through the edge. The
--   symptom points at the load balancer; the cause is an absent extension.
--
--   OpenTofu creates the database and the master user, and the parameter group
--   preloads pg_stat_statements and pg_prewarm. Neither of those is the same as
--   CREATE EXTENSION inside the database, and nothing in the module or the
--   Ansible roles does it.
--
-- SOURCE OF TRUTH
--   avni-server's own Makefile, target `_build_db`. If that target changes,
--   this file is stale. The user and database it also creates are already
--   provided by OpenTofu (db_name = openchs, username = openchs), so only the
--   extensions and roles remain.
--
-- IDEMPOTENT
--   Safe to re-run. The extensions use IF NOT EXISTS; the roles are guarded,
--   because CREATE ROLE has no IF NOT EXISTS and a second run would otherwise
--   abort the transaction.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS ltree;
CREATE EXTENSION IF NOT EXISTS hstore;

-- Multi-tenancy roles. avni-server's SetOrganisationJdbcInterceptor issues
-- `set role "<dbUser>"` on every connection borrow, and row-level security is
-- enforced through these, so they are not optional decoration.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'demo') THEN
    CREATE ROLE demo WITH NOINHERIT NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openchs_impl') THEN
    CREATE ROLE openchs_impl;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'organisation_user') THEN
    CREATE ROLE organisation_user CREATEROLE ADMIN openchs_impl;
  END IF;
END
$$;

GRANT demo TO openchs WITH ADMIN OPTION;
GRANT openchs_impl TO openchs WITH ADMIN OPTION;

-- ---------------------------------------------------------------------------
-- Grant the organisation's database role access to the tables.
--
-- SetOrganisationJdbcInterceptor issues `set role "<organisation.db_user>"` on
-- every connection borrow -- for organisation 1 that role is openchs_impl, not
-- openchs -- and the role owns nothing, so without this every authenticated
-- request fails with "permission denied for table ..." while /ping stays green.
--
-- THIS FILE MUST BE RUN TWICE ON A FRESH DATABASE, and the two halves want
-- opposite ordering:
--
--   The EXTENSIONS above must exist BEFORE avni-server starts, or Flyway dies
--   on migration 1.64.5 with "function uuid_generate_v4() does not exist".
--
--   This GRANT covers tables that exist WHEN IT RUNS. Before Flyway that is
--   almost nothing, so all ~488 migrated tables end up ungranted and the first
--   authenticated request fails naming a table nobody wrote to.
--
-- So: run once before the first deploy, and again after migrations complete.
-- The file is idempotent, so the second run is safe and cheap.
--
-- grant_all_on_all is Avni's own function, defined by its migrations and used
-- by the application when creating an organisation. Preferable to hand-written
-- GRANTs, which would drift from whatever Avni decides an org role should hold.
-- ---------------------------------------------------------------------------
SELECT grant_all_on_all((SELECT db_user FROM organisation WHERE id = 1));

-- ---------------------------------------------------------------------------
-- Drop the duplicate observation GIN indexes that the migrations create.
--
-- V1_03 creates idx_program_enrolment_obs and idx_program_encounter_obs.
-- V1_227.4 then creates program_enrolment_obs_idx and program_encounter_obs_idx
-- over the IDENTICAL column and expression -- GIN (observations jsonb_path_ops)
-- -- and CREATE INDEX IF NOT EXISTS dedupes on name, not definition, so both
-- survive. No migration drops either: `drop index ... obs` appears nowhere in
-- the 488.
--
-- PRODUCTION DOES NOT HAVE THE V1_03 PAIR. It still has idx_individual_obs, so
-- V1_03 certainly ran there; it is missing exactly the two that had duplicates
-- and kept the one that did not. Someone dropped them by hand, outside Flyway,
-- and nothing records that -- so every database built from scratch, including
-- this one on every rebuild, reintroduces them.
--
-- This matters for measurement, not for storage. Two redundant GIN indexes are
-- two extra index writes on every program_encounter and program_enrolment
-- insert, which makes the load-test write path SLOWER than the production one
-- it is supposed to model. Both tables are empty in the current dataset, so the
-- cost is zero today and arrives with the first program data.
--
-- Harmless on the first of this file's two runs, when the tables do not exist
-- yet: DROP INDEX IF EXISTS on a missing index is a no-op.
-- ---------------------------------------------------------------------------
DROP INDEX IF EXISTS idx_program_encounter_obs;
DROP INDEX IF EXISTS idx_program_enrolment_obs;
