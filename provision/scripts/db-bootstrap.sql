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
