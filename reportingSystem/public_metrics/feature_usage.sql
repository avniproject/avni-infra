-- Feature usage dashboard (avniproject/avni-product-ops#331)
-- Spec: avni-product-ops analysis/feature-usage-dashboard/feature-usage-dashboard_spec.md
-- Decision 27 Nov 2026 (avni-product-ops context/decisions-log.md): count-only objects may live in
-- public_metrics on the production database.
--
-- Run by a person on the PRODUCTION PRIMARY, signed in as openchs:
--   psql -h serverdb.avniproject.org -U openchs -d openchs \
--        -v writer_password="$(security find-generic-password -s avni_metrics_writer -w)" \
--        -f feature_usage.sql
-- Never on staging/prerelease/on-premise: these objects are prod reporting only, not Flyway.
--
-- Rules every object here keeps:
--   * returns counts by organisation, never a name, record id, free text, rule text or secret;
--   * dates are bounded (sync_telemetry holds device-clock junk back to 1924);
--   * month/day are Asia/Kolkata calendar periods.
-- Columns checked against schema V1_410_2 (avni-server origin/19.0) on 27 Nov 2026.

begin;

create schema if not exists public_metrics;

-- 1. Live organisations ---------------------------------------------------------------
-- Production + Live, by name (question 4840's ids 1,2 also take in UAT).
-- suffix: what follows '@' in a username; falls back to db_user (Organisation.getEffectiveUsernameSuffix).
create or replace view public_metrics.v_live_orgs as
select o.id                                   as organisation_id,
       o.name                                 as organisation_name,
       coalesce(o.username_suffix, o.db_user) as suffix,
       o.media_directory
from organisation o
         join organisation_category c on c.id = o.category_id
         join organisation_status s on s.id = o.status_id
where c.name = 'Production'
  and s.name = 'Live'
  and not o.is_voided;

-- Suffixes shared by more than one non-voided organisation. The nightly job drops these
-- rather than guess, and reports them. 3 on 27 Nov 2026 (all organisations).
create or replace view public_metrics.v_duplicate_suffixes as
select coalesce(username_suffix, db_user) as suffix, count(*) as organisations
from organisation
where not is_voided
group by 1
having count(*) > 1;

-- 2. Features set up ------------------------------------------------------------------
-- One row per live org per feature that is set up. item_count is null for on/off settings.
create or replace view public_metrics.v_feature_setup as
with cfg as (select organisation_id, settings, worklist_updation_rule
             from organisation_config
             where not is_voided),
     setup as (
         -- Organisation settings page (avni-webapp OrgSettings.jsx:63-82). Values compared as text,
         -- so a malformed value reads as off rather than failing the view.
         select cfg.organisation_id, 'Organisation settings' as feature_group, k.label as feature, null::bigint as item_count
         from cfg
                  cross join (values ('saveDrafts', 'Draft save'),
                                     ('hideDateOfBirth', 'Hide date of birth on DEA'),
                                     ('hideVisitDate', 'Hide visit date'),
                                     ('enableComments', 'Comments'),
                                     ('enableClinicSharing', 'Camp mode'),
                                     ('enableMobileAppDbEncryption', 'Phone database encryption'),
                                     ('showSummaryButton', 'Summary button'),
                                     ('enableMessaging', 'Messaging'),
                                     ('useKeycloakAsIDP', 'Keycloak login'),
                                     ('useMinioForStorage', 'MinIO storage'),
                                     ('skipRuleExecution', 'Skip rules on upload'),
                                     ('showHierarchicalLocation', 'Hierarchical location'),
                                     ('donotRequirePasswordChangeOnFirstLogin', 'No password change on first login'),
                                     ('guideUserToRegisterButton', 'Guide users'),
                                     ('enableSqliteSnapshotGeneration', 'Fast sync')) k(key, label)
         where cfg.settings ->> k.key = 'true'
         union all
         -- A secret: presence only, never the value.
         select organisation_id, 'Organisation settings', 'Form validation key set', null
         from cfg
         where coalesce(settings ->> 'copilotFormValidationApiKey', '') <> ''
         union all
         -- Settings that hold lists. jsonb_typeof guard: the server tolerates non-arrays
         -- (OrganisationConfigService.java:230-231) and jsonb_array_length would fail the view.
         select cfg.organisation_id, 'App Designer', k.label, jsonb_array_length(cfg.settings -> k.key)
         from cfg
                  cross join (values ('searchFilters', 'Search filters'),
                                     ('searchResultFields', 'Search result fields'),
                                     ('myDashboardFilters', 'My Dashboard filters'),
                                     ('languages', 'Languages'),
                                     ('extensions', 'Extensions')) k(key, label)
         where jsonb_typeof(cfg.settings -> k.key) = 'array'
           and jsonb_array_length(cfg.settings -> k.key) > 0
         union all
         select organisation_id, 'App Designer', 'Worklist rule', null
         from cfg
         where coalesce(btrim(worklist_updation_rule), '') <> ''
         union all
         -- Subject types. should_sync_by_location is left out: it defaults to true (V1_208).
         select st.organisation_id, 'Subject types', f.label, count(*)
         from subject_type st
                  cross join lateral (values ('Households', st.is_household),
                                             ('Groups', st.is_group and not st.is_household),
                                             ('User subject types', st.type = 'User'),
                                             ('Sync by a registration answer', st.sync_registration_concept_1 is not null),
                                             ('Profile pictures', st.allow_profile_picture),
                                             ('Unique names', st.unique_name),
                                             ('Direct assignment', st.directly_assignable),
                                             ('Attendance', st.attendance_enabled),
                                             ('Middle name', st.allow_middle_name)) f(label, flag)
         where not st.is_voided
           and coalesce(f.flag, false)
         group by 1, 3
         union all
         -- Programs. show_growth_chart is left out: V1_350 turned it on for Child programs.
         select p.organisation_id, 'Programs and visits', f.label, count(*)
         from program p
                  cross join lateral (values ('More than one enrolment', p.allow_multiple_enrolments),
                                             ('Manual eligibility check', p.manual_eligibility_check_required),
                                             ('Eligibility rules built in the rule designer',
                                              p.enrolment_eligibility_check_declarative_rule is not null
                                                  and p.enrolment_eligibility_check_declarative_rule <> 'null'::jsonb)) f(label, flag)
         where not p.is_voided
           and coalesce(f.flag, false)
         group by 1, 3
         union all
         select et.organisation_id, 'Programs and visits', f.label, count(*)
         from encounter_type et
                  cross join lateral (values ('Locked visits', et.is_immutable),
                                             ('Eligibility rules built in the rule designer',
                                              et.encounter_eligibility_check_declarative_rule is not null
                                                  and et.encounter_eligibility_check_declarative_rule <> 'null'::jsonb)) f(label, flag)
         where not et.is_voided
           and coalesce(f.flag, false)
         group by 1, 3
         union all
         select organisation_id, 'Programs and visits', 'Forms needing approval', count(*)
         from form_mapping
         where not is_voided
           and enable_approval
         group by 1
         union all
         -- Cards. The kinds are exclusive (V1_377). Every non-standard card got action
         -- ViewSubjectProfile in V1_375, so an action card is any other action.
         select organisation_id, 'Cards', k.kind, count(*)
         from report_card rc
                  cross join lateral (values ('Standard cards', rc.standard_report_card_type_id is not null),
                                             ('Query cards', rc.query is not null and rc.custom_card_config_id is null),
                                             ('Custom design cards', rc.custom_card_config_id is not null),
                                             ('Action cards', rc.action is not null and rc.action <> 'ViewSubjectProfile'),
                                             ('Nested cards', rc.nested)) k(kind, flag)
         where not rc.is_voided
           and coalesce(k.flag, false)
         group by 1, 3
         union all
         select rc.organisation_id, 'Standard card types', t.name, count(*)
         from report_card rc
                  join standard_report_card_type t on t.id = rc.standard_report_card_type_id
         where not rc.is_voided
           and not t.is_voided
         group by 1, 3
         union all
         -- App Designer items: a count of non-voided rows per org.
         select organisation_id, 'App Designer', 'Dashboards', count(*) from dashboard where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Dashboard filters', count(*) from dashboard_filter where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Relationship types', count(*) from individual_relationship_type where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Checklists', count(*) from checklist_detail where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Videos', count(*) from video where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'App menu items', count(*) from menu_item where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Storage rule', count(*) from storage_management_config where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Calendars', count(*) from calendar where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Documentation', count(*) from documentation where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Identifier sources', count(*) from identifier_source where not is_voided group by 1
         union all
         select organisation_id, 'App Designer', 'Downloadable content', count(*) from downloadable_content where not is_voided group by 1
     )
select s.organisation_id::int as organisation_id, s.feature_group, s.feature, s.item_count
from setup s
         join public_metrics.v_live_orgs o on o.organisation_id = s.organisation_id;

-- 3. Features used, month by month (live counts over the last 24 months) -------------------
-- Tables measured on the prod read copy, 27 Nov 2026: individual_relationship 0.68M,
-- entity_approval_status 0.88M, rule_failure_telemetry 0.67M, rule_failure_log 0.11M,
-- task 0.09M, message_request_queue 701. checklist_item (4.4M) is NOT here: the nightly
-- job appends it to usage_daily.
create or replace view public_metrics.v_feature_activity_monthly as
with since as (select date_trunc('month', (now() at time zone 'Asia/Kolkata') - interval '24 months') as t),
     activity as (
         select organisation_id, 'Comments' as feature, 'Comments written' as measure, created_date_time as ts
         from comment where not is_voided
         union all
         select organisation_id, 'Comments', 'Threads opened', open_date_time from comment_thread where not is_voided
         union all
         select organisation_id, 'Comments', 'Threads resolved', resolved_date_time from comment_thread where not is_voided and resolved_date_time is not null
         union all
         select organisation_id, 'Calendars and attendance', 'Sessions marked', marked_at from session where not is_voided and marked_at is not null
         union all
         select organisation_id, 'Calendars and attendance', 'Attendance recorded', created_date_time from attendance_record where not is_voided
         union all
         select organisation_id, 'Video playlist', 'Plays', player_open_time from video_telemetric where not is_voided
         union all
         select organisation_id, 'Relationships', 'Relationships recorded', created_date_time from individual_relationship where not is_voided
         union all
         select organisation_id, 'Assignment and tasks', 'Subjects assigned', created_date_time from user_subject_assignment where not is_voided
         union all
         select organisation_id, 'Assignment and tasks', 'Tasks created', created_date_time from task where not is_voided
         union all
         select organisation_id, 'Assignment and tasks', 'Tasks closed', completed_on at time zone 'UTC' from task where not is_voided and completed_on is not null
         union all
         select organisation_id, 'Broadcast', 'News published', published_date from news where not is_voided and published_date is not null
         union all
         select organisation_id, 'Broadcast', 'Manual messages', created_date_time from manual_message where not is_voided
         union all
         -- Approvals: people's decisions only, not automatic approvals or pending rows.
         select eas.organisation_id, 'Approvals', s.status || ' by a person', eas.status_date_time
         from entity_approval_status eas
                  join approval_status s on s.id = eas.approval_status_id
         where not eas.is_voided
           and not coalesce(eas.auto_approved, false)
           and s.status in ('Approved', 'Rejected')
         union all
         select organisation_id, 'Messaging', 'Messages scheduled', scheduled_date_time from message_request_queue where not is_voided
         union all
         select organisation_id, 'Messaging', 'Messages delivered', delivered_date_time from message_request_queue where not is_voided and delivered_date_time is not null
         union all
         select organisation_id, 'Rules', 'Rule failures on the phone', error_date_time from rule_failure_telemetry
         union all
         select organisation_id, 'Rules', 'Rule failures on the web', created_date_time from rule_failure_log where not is_voided
     )
select a.organisation_id::int                                          as organisation_id,
       a.feature,
       a.measure,
       date_trunc('month', a.ts at time zone 'Asia/Kolkata')::date as month,
       count(*)::bigint                                                as value
from activity a
         join public_metrics.v_live_orgs o on o.organisation_id = a.organisation_id
         cross join since
where a.ts >= since.t at time zone 'Asia/Kolkata'
  and a.ts < now() + interval '1 day'
group by 1, 2, 3, 4;

-- 4. Daily counts written by the nightly job -------------------------------------------------
create table if not exists public_metrics.usage_daily
(
    day             date   not null,
    organisation_id int    not null,
    feature         text   not null,
    measure         text   not null,
    value           bigint not null,
    primary key (day, organisation_id, feature, measure)
);

-- 5. Views the nightly job reads for one day ------------------------------------------------
-- The job sets the day per session: set avni.metrics_day = '2026-11-26';
-- Unset, current_setting(..., true) is null and these return nothing.
create or replace view public_metrics.v_phone_pushes_for_day as
select st.organisation_id::int as organisation_id,
       'Data entry app against the phone' as feature,
       case e ->> 'entity'
           when 'Individual' then 'Subjects sent from phones'
           when 'ProgramEnrolment' then 'Enrolments sent from phones'
           else 'Visits sent from phones' end as measure,
       sum((e ->> 'done')::bigint) as value
from sync_telemetry st
         cross join lateral jsonb_array_elements(case when jsonb_typeof(st.entity_status -> 'push') = 'array'
                                                      then st.entity_status -> 'push' end) e
where not st.is_voided
  and st.sync_start_time >= (current_setting('avni.metrics_day', true)::date)::timestamp at time zone 'Asia/Kolkata'
  and st.sync_start_time < (current_setting('avni.metrics_day', true)::date + 1)::timestamp at time zone 'Asia/Kolkata'
  and e ->> 'entity' in ('Individual', 'ProgramEnrolment', 'Encounter', 'ProgramEncounter')
  and (e ->> 'done') ~ '^[0-9]+$'
group by 1, 2, 3
having sum((e ->> 'done')::bigint) > 0;

create or replace view public_metrics.v_checklist_items_for_day as
select organisation_id::int as organisation_id,
       'Checklists'        as feature,
       'Checklist items completed' as measure,
       count(*)::bigint    as value
from checklist_item
where not is_voided
  and completion_date >= (current_setting('avni.metrics_day', true)::date)::timestamp at time zone 'Asia/Kolkata'
  and completion_date < (current_setting('avni.metrics_day', true)::date + 1)::timestamp at time zone 'Asia/Kolkata'
group by 1;

-- 6. What the dashboard reads ----------------------------------------------------------------
create or replace view public_metrics.v_usage_monthly as
select organisation_id, feature, measure, month, value
from public_metrics.v_feature_activity_monthly
union all
select d.organisation_id, d.feature, d.measure, date_trunc('month', d.day)::date, sum(d.value)::bigint
from public_metrics.usage_daily d
         join public_metrics.v_live_orgs o on o.organisation_id = d.organisation_id
group by 1, 2, 3, 4;

-- 7. Logins and grants -----------------------------------------------------------------------
-- Reader: per object, not ALTER DEFAULT PRIVILEGES (metrics-reader open item 5).
grant select on public_metrics.v_live_orgs, public_metrics.v_duplicate_suffixes,
    public_metrics.v_feature_setup, public_metrics.v_feature_activity_monthly,
    public_metrics.v_phone_pushes_for_day, public_metrics.v_checklist_items_for_day,
    public_metrics.v_usage_monthly, public_metrics.usage_daily
    to avni_metrics_reader;

-- Writer: may only replace rows of usage_daily. SELECT is needed for DELETE ... WHERE.
do
$$
    begin
        if not exists (select from pg_roles where rolname = 'avni_metrics_writer') then
            create role avni_metrics_writer login noinherit connection limit 2;
        end if;
    end
$$;
alter role avni_metrics_writer with password :'writer_password';
alter role avni_metrics_writer set statement_timeout = '60s';
grant connect on database openchs to avni_metrics_writer;
grant usage on schema public_metrics to avni_metrics_writer;
grant select, insert, delete on public_metrics.usage_daily to avni_metrics_writer;

commit;

-- Checks after running (as openchs):
--   select count(*) from public_metrics.v_live_orgs;                    -- 267 on 27 Nov 2026
--   select feature_group, feature, count(*) from public_metrics.v_feature_setup group by 1, 2 order by 1, 3 desc;
--   select feature, measure, sum(value) from public_metrics.v_feature_activity_monthly group by 1, 2;
--   set role avni_metrics_writer; select 1 from public_metrics.usage_daily limit 1; reset role;
--   select rolname, rolsuper, rolinherit, rolconnlimit from pg_roles where rolname = 'avni_metrics_writer';

-- 8. Added 27 Nov 2026 for the nightly job's db function, which signs in only as the writer:
--    it reads these four views to map suffixes and to fetch the one-day counts.
grant select on public_metrics.v_live_orgs, public_metrics.v_duplicate_suffixes,
    public_metrics.v_phone_pushes_for_day, public_metrics.v_checklist_items_for_day
    to avni_metrics_writer;

-- 9. Added 27 Nov 2026: every organisation's suffix, so the nightly job can tell a request from a
--    non-live organisation (expected, e.g. tanuh_uat) from one that matches no organisation (a fault).
create or replace view public_metrics.v_all_org_suffixes as
select distinct lower(coalesce(username_suffix, db_user)) as suffix
from organisation
where coalesce(username_suffix, db_user) is not null;
grant select on public_metrics.v_all_org_suffixes to avni_metrics_writer, avni_metrics_reader;

-- 10. Added 27 Nov 2026: "Files stored" is a running total, so a month shows its highest day, not
--     the sum of its days. Every other measure is summed.
create or replace view public_metrics.v_usage_monthly as
select organisation_id, feature, measure, month, value
from public_metrics.v_feature_activity_monthly
union all
select d.organisation_id, d.feature, d.measure, date_trunc('month', d.day)::date,
       (case when d.measure = 'Files stored' then max(d.value) else sum(d.value) end)::bigint
from public_metrics.usage_daily d
         join public_metrics.v_live_orgs o on o.organisation_id = d.organisation_id
group by 1, 2, 3, 4;
