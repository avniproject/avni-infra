-- A single organisation-scoped user, so the load-test environment can be
-- exercised with a real authenticated request.
--
-- THIS IS NOT G5. The harness plan's G5 provisions N users with catchments
-- sized against the generated dataset, emits sync-users.csv with stable device
-- IDs, and bootstraps each user's sync-status baseline. None of that is
-- possible before the dataset exists (F5.1/H), and G5 is explicit that the
-- dataset and the user set must be designed together by one owner -- design
-- them apart and you get users whose catchments do not intersect the data, and
-- a simulation that measures nothing.
--
-- What this does is narrower and immediately useful: it makes
-- `AVNI_IDP_TYPE=none` demonstrable end to end. Before it, the environment
-- answers /ping but every API call returns 401, because the USER-NAME header
-- names a user that does not exist -- which is indistinguishable, from the
-- outside, from authentication being broken.
--
-- WHY IT REUSES ORGANISATION 1 RATHER THAN CREATING ONE
--   Migration V0_41 seeds organisation id=1 ('OpenCHS', db_user 'openchs'), and
--   the connection already authenticates as that role -- which matters, because
--   SetOrganisationJdbcInterceptor issues `set role "<db_user>"` on every
--   connection borrow and row-level security is enforced through it.
--
--   Creating a *new* organisation properly means a matching Postgres role, the
--   RLS policies keyed on organisation.db_user, an account, and an
--   organisation_config row. Getting any of that subtly wrong yields an org
--   that half-works and fails later in ways that look like application bugs.
--   For a smoke test that is a poor trade. A dedicated organisation belongs
--   with the dataset work, where multi-tenancy is a deliberate test dimension
--   (harness section I) rather than a side effect.
--
-- IDEMPOTENT. Safe to re-run; it will not duplicate the user or the membership.
--
-- NOTE ON COLUMNS. `users` has no `version` column despite older migrations
-- inserting one -- it was dropped as the audit fields moved. Column lists here
-- were taken from information_schema on the live schema rather than from
-- migration history, which for 488 migrations is not a reliable guide to the
-- current shape.

BEGIN;

-- Scope 'None' rather than 'ByCatchment', deliberately. There is a check
-- constraint requiring a catchment whenever the scope is ByCatchment, and this
-- user has no catchment because there is no data for one to select. The
-- consequence is worth stating: this user can authenticate, but it will sync
-- almost nothing. Catchment assignment is the lever that controls sync volume
-- per user, and that is G5's job.
INSERT INTO users (
    username, name, uuid, organisation_id,
    operating_individual_scope,
    created_by_id, last_modified_by_id,
    created_date_time, last_modified_date_time,
    is_voided, is_org_admin
)
SELECT
    'loadtest@openchs', 'Load test smoke user',
    '8f1b6c2e-4a3d-4c19-9a7e-2d5b0f7c1a44', 1,
    'None',
    1, 1, current_timestamp, current_timestamp,
    false, false
WHERE NOT EXISTS (SELECT 1 FROM users WHERE username = 'loadtest@openchs');

-- Without group membership the user authenticates and is then denied on
-- privilege checks, which reads as a 403 and looks like a different problem.
-- 'Everyone' is the group migrations create per organisation.
INSERT INTO user_group (
    uuid, user_id, group_id, organisation_id,
    created_by_id, last_modified_by_id,
    created_date_time, last_modified_date_time,
    is_voided, version
)
SELECT
    'b4c7d5e1-9f26-4a83-bd10-6e3c8a47f902',
    u.id, g.id, 1,
    1, 1, current_timestamp, current_timestamp,
    false, 1
FROM users u
JOIN groups g ON g.organisation_id = u.organisation_id AND g.name = 'Everyone'
WHERE u.username = 'loadtest@openchs'
  AND NOT EXISTS (
      SELECT 1 FROM user_group ug WHERE ug.user_id = u.id AND ug.group_id = g.id
  );

-- user_group.version is NULLABLE in the database and a PRIMITIVE int on the
-- entity, so a NULL is not merely untidy -- Hibernate throws
-- "Null value was assigned to a property of primitive type" and every request
-- touching user groups returns 500. Nullable in the schema is not the same as
-- optional to the application, which is why the column list above was wrong
-- when taken from information_schema's NOT NULL columns alone.
UPDATE user_group SET version = 1
WHERE version IS NULL
  AND user_id = (SELECT id FROM users WHERE username = 'loadtest@openchs');

-- Grant the organisation's database role access to the tables.
--
-- This is the step whose absence produces `permission denied for table users`
-- on every authenticated request while /ping stays green.
-- SetOrganisationJdbcInterceptor issues `set role "<organisation.db_user>"` on
-- every connection borrow -- for organisation 1 that role is openchs_impl, not
-- openchs -- and the role owns nothing, so without grants it can read nothing.
--
-- grant_all_on_all is Avni's own function, defined by its migrations, and is
-- what the application uses when an organisation is created. Calling it is
-- preferable to hand-written GRANTs, which would drift from whatever Avni
-- decides an organisation role should hold.
SELECT grant_all_on_all((SELECT db_user FROM organisation WHERE id = 1));

COMMIT;

-- Verify, and show what is missing rather than only what is present.
SELECT u.username,
       u.operating_individual_scope AS scope,
       u.catchment_id,
       o.name        AS organisation,
       o.db_user,
       g.name        AS group_name
FROM users u
JOIN organisation o ON o.id = u.organisation_id
LEFT JOIN user_group ug ON ug.user_id = u.id AND ug.is_voided = false
LEFT JOIN groups g ON g.id = ug.group_id
WHERE u.username = 'loadtest@openchs';
