-- Indexes production has that a database built from Avni's migrations does not.
--
--   AVNI_DB_SQL=scripts/db-index-parity.sql ./scripts/db-bootstrap.sh
--
-- RUN THIS AFTER LOADING A DATASET, NOT BEFORE. Building these on data already
-- present is far faster than having every COPY maintain them, and it keeps load
-- times comparable between runs. The consequence, which belongs in any report:
-- a load timed without these present does NOT reflect production's write cost.
--
-- WHY THIS FILE HAS TO EXIST
--   Nothing in avni-server creates these. Not the 488 migrations -- those define
--   sync_1..5 only for entity_approval_status, in V1_274 -- and not the Java:
--   `grep -rni "create index\|createIndex"` over both source trees returns
--   nothing. They are absent from avni-infra and avni-perf too. They exist on
--   production because someone built them by hand, and nothing records it.
--
--   So production's schema cannot be reproduced from the repository, and every
--   environment built from it silently lacks the indexes that make sync work at
--   scale. Captured 2026-09-30 by diffing the full public schema: 120 of 134
--   shared tables matched exactly, 14 differed, all in this direction.
--
-- WHY IT MATTERS MORE THAN ITS SIZE SUGGESTS
--   The sync_N shapes are the sync scope predicate. individual_sync_1 is
--   (address_id, last_modified_date_time, organisation_id, subject_type_id) --
--   catchment addresses, changed-since, org, type -- which is exactly the query
--   OperatingIndividualScopeAwareRepository builds. sync_2 substitutes
--   individual_id for direct assignment, sync_3/4 add the sync concepts, sync_5
--   covers all of it. Without them the sync path has no supporting index and
--   the planner picks something else entirely, so a latency figure measured
--   without these is not pessimistic -- it is measuring a different plan.
--
--   Highest-traffic omissions, by production scan count:
--     individual_sync_2_index                    3,588,699,445
--     subject_migration_individual_id_idx        3,143,389,260
--     location_location_mapping_location_id_idx  1,527,913,284
--     individual_sync_5_index                      336,585,043
--     program_encounter_sync_1_index               326,485,574
--     address_level_lineage_gist_idx               262,603,725
--
-- THREE OF PRODUCTION'S 41 ARE DELIBERATELY NOT REPRODUCED
--   audit_last_modified_date_time_index            1888 MB, 0 scans in 69 days
--   idx_batch_job_execution_params_parameter_name    Spring Batch internals
--   idx_batch_job_execution_params_parameter_value   Spring Batch internals
--
--   `audit` is write-only bloat on both sides and nothing reads that index;
--   1.9 GB of index maintenance on every insert would slow loads for no
--   measurement. The batch_job_execution_params pair belongs to Spring Batch
--   job history, which no sync scenario exercises. Everything else is created
--   exactly as production has it, including indexes production barely uses --
--   program_encounter_earliest_visit_date_time_index is 545 MB for 61 scans --
--   because matching production's WRITE cost matters as much as its read plans,
--   and quietly dropping them would overstate insert throughput.
--
-- No CONCURRENTLY: it cannot run inside a transaction, and there is no live
-- traffic to protect here. IF NOT EXISTS throughout, so this is re-runnable.

\timing on
-- address_level.address_level_lineage_gist_idx  (171 MB on prod, 262,603,725 scans)
CREATE INDEX IF NOT EXISTS address_level_lineage_gist_idx
  ON public.address_level USING gist (lineage);

-- encounter.encounter_sync_1_index  (370 MB on prod, 146,989,901 scans)
CREATE INDEX IF NOT EXISTS encounter_sync_1_index
  ON public.encounter USING btree (address_id, last_modified_date_time, organisation_id, encounter_type_id);

-- encounter.encounter_sync_2_index  (344 MB on prod, 7,626,203 scans)
CREATE INDEX IF NOT EXISTS encounter_sync_2_index
  ON public.encounter USING btree (individual_id, last_modified_date_time, organisation_id, encounter_type_id);

-- encounter.encounter_sync_3_index  (472 MB on prod, 287,095 scans)
CREATE INDEX IF NOT EXISTS encounter_sync_3_index
  ON public.encounter USING btree (sync_concept_1_value, last_modified_date_time, organisation_id, encounter_type_id);

-- encounter.encounter_sync_4_index  (476 MB on prod, 19,798 scans)
CREATE INDEX IF NOT EXISTS encounter_sync_4_index
  ON public.encounter USING btree (sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, encounter_type_id);

-- encounter.encounter_sync_5_index  (578 MB on prod, 2,542 scans)
CREATE INDEX IF NOT EXISTS encounter_sync_5_index
  ON public.encounter USING btree (address_id, individual_id, sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, encounter_type_id);

-- encounter_type.encounter_type_name__index  (464 kB on prod, 1,762,530 scans)
CREATE INDEX IF NOT EXISTS encounter_type_name__index
  ON public.encounter_type USING btree (name);

-- group_subject.group_subject_sync_1_index  (187 MB on prod, 46,816,748 scans)
CREATE INDEX IF NOT EXISTS group_subject_sync_1_index
  ON public.group_subject USING btree (group_subject_address_id, member_subject_address_id, last_modified_date_time, organisation_id);

-- group_subject.group_subject_sync_2_index  (168 MB on prod, 1,472,315 scans)
CREATE INDEX IF NOT EXISTS group_subject_sync_2_index
  ON public.group_subject USING btree (group_subject_id, member_subject_id, last_modified_date_time, organisation_id);

-- group_subject.group_subject_sync_3_index  (141 MB on prod, 18,606 scans)
CREATE INDEX IF NOT EXISTS group_subject_sync_3_index
  ON public.group_subject USING btree (group_subject_sync_concept_1_value, last_modified_date_time, organisation_id);

-- group_subject.group_subject_sync_4_index  (142 MB on prod, 11,847 scans)
CREATE INDEX IF NOT EXISTS group_subject_sync_4_index
  ON public.group_subject USING btree (group_subject_sync_concept_1_value, group_subject_sync_concept_2_value, last_modified_date_time, organisation_id);

-- group_subject.group_subject_sync_5_index  (310 MB on prod, 3,402,170 scans)
CREATE INDEX IF NOT EXISTS group_subject_sync_5_index
  ON public.group_subject USING btree (group_subject_address_id, member_subject_address_id, group_subject_id, member_subject_id, group_subject_sync_concept_1_value, group_subject_sync_concept_2_value, last_modified_date_time, organisation_id);

-- individual.individual_address_id_index  (130 MB on prod, 153,774,423 scans)
CREATE INDEX IF NOT EXISTS individual_address_id_index
  ON public.individual USING btree (address_id);

-- individual.individual_registration_date_index  (135 MB on prod, 22,491 scans)
CREATE INDEX IF NOT EXISTS individual_registration_date_index
  ON public.individual USING btree (registration_date);

-- individual.individual_sync_1_index  (202 MB on prod, 174,660,542 scans)
CREATE INDEX IF NOT EXISTS individual_sync_1_index
  ON public.individual USING btree (address_id, last_modified_date_time, organisation_id, subject_type_id);

-- individual.individual_sync_2_index  (189 MB on prod, 3,588,699,445 scans)
CREATE INDEX IF NOT EXISTS individual_sync_2_index
  ON public.individual USING btree (id, last_modified_date_time, organisation_id, subject_type_id);

-- individual.individual_sync_3_index  (278 MB on prod, 2,903,215 scans)
CREATE INDEX IF NOT EXISTS individual_sync_3_index
  ON public.individual USING btree (sync_concept_1_value, last_modified_date_time, organisation_id, subject_type_id);

-- individual.individual_sync_4_index  (304 MB on prod, 299,267 scans)
CREATE INDEX IF NOT EXISTS individual_sync_4_index
  ON public.individual USING btree (sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, subject_type_id);

-- individual.individual_sync_5_index  (329 MB on prod, 336,585,043 scans)
CREATE INDEX IF NOT EXISTS individual_sync_5_index
  ON public.individual USING btree (address_id, id, sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, subject_type_id);

-- location_location_mapping.location_location_mapping_location_id_idx  (28 MB on prod, 1,527,913,284 scans)
CREATE UNIQUE INDEX IF NOT EXISTS location_location_mapping_location_id_idx
  ON public.location_location_mapping USING btree (location_id);

-- operational_program.org_operational_program_idx  (144 kB on prod, 31 scans)
CREATE UNIQUE INDEX IF NOT EXISTS org_operational_program_idx
  ON public.operational_program USING btree (organisation_id, name);

-- program.program_name__index  (128 kB on prod, 242,281 scans)
CREATE INDEX IF NOT EXISTS program_name__index
  ON public.program USING btree (name);

-- program_encounter.program_encounter_earliest_visit_date_time_index  (545 MB on prod, 61 scans)
CREATE INDEX IF NOT EXISTS program_encounter_earliest_visit_date_time_index
  ON public.program_encounter USING btree (earliest_visit_date_time);

-- program_encounter.program_encounter_encounter_date_time_index  (493 MB on prod, 7,353 scans)
CREATE INDEX IF NOT EXISTS program_encounter_encounter_date_time_index
  ON public.program_encounter USING btree (encounter_date_time);

-- program_encounter.program_encounter_individual_id_index  (248 MB on prod, 194,267 scans)
CREATE INDEX IF NOT EXISTS program_encounter_individual_id_index
  ON public.program_encounter USING btree (individual_id);

-- program_encounter.program_encounter_sync_1_index  (864 MB on prod, 326,485,574 scans)
CREATE INDEX IF NOT EXISTS program_encounter_sync_1_index
  ON public.program_encounter USING btree (address_id, last_modified_date_time, organisation_id, encounter_type_id);

-- program_encounter.program_encounter_sync_2_index  (465 MB on prod, 95,488 scans)
CREATE INDEX IF NOT EXISTS program_encounter_sync_2_index
  ON public.program_encounter USING btree (individual_id, last_modified_date_time, organisation_id, encounter_type_id);

-- program_encounter.program_encounter_sync_3_index  (2008 MB on prod, 829,434 scans)
CREATE INDEX IF NOT EXISTS program_encounter_sync_3_index
  ON public.program_encounter USING btree (sync_concept_1_value, last_modified_date_time, organisation_id, encounter_type_id);

-- program_encounter.program_encounter_sync_4_index  (2360 MB on prod, 840 scans)
CREATE INDEX IF NOT EXISTS program_encounter_sync_4_index
  ON public.program_encounter USING btree (sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, encounter_type_id);

-- program_encounter.program_encounter_sync_5_index  (925 MB on prod, 64,110,219 scans)
CREATE INDEX IF NOT EXISTS program_encounter_sync_5_index
  ON public.program_encounter USING btree (address_id, individual_id, sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, encounter_type_id);

-- program_enrolment.program_enrolment_enrolment_date_time__index  (50 MB on prod, 82 scans)
CREATE INDEX IF NOT EXISTS program_enrolment_enrolment_date_time__index
  ON public.program_enrolment USING btree (enrolment_date_time);

-- program_enrolment.program_enrolment_program_exit_date_time_index  (35 MB on prod, 39,239 scans)
CREATE INDEX IF NOT EXISTS program_enrolment_program_exit_date_time_index
  ON public.program_enrolment USING btree (program_exit_date_time);

-- program_enrolment.program_enrolment_sync_1_index  (101 MB on prod, 106,693,687 scans)
CREATE INDEX IF NOT EXISTS program_enrolment_sync_1_index
  ON public.program_enrolment USING btree (address_id, last_modified_date_time, organisation_id, program_id);

-- program_enrolment.program_enrolment_sync_2_index  (82 MB on prod, 26,371,033 scans)
CREATE INDEX IF NOT EXISTS program_enrolment_sync_2_index
  ON public.program_enrolment USING btree (individual_id, last_modified_date_time, organisation_id, program_id);

-- program_enrolment.program_enrolment_sync_3_index  (410 MB on prod, 331,517 scans)
CREATE INDEX IF NOT EXISTS program_enrolment_sync_3_index
  ON public.program_enrolment USING btree (sync_concept_1_value, last_modified_date_time, organisation_id, program_id);

-- program_enrolment.program_enrolment_sync_4_index  (462 MB on prod, 315 scans)
CREATE INDEX IF NOT EXISTS program_enrolment_sync_4_index
  ON public.program_enrolment USING btree (sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, program_id);

-- program_enrolment.program_enrolment_sync_5_index  (135 MB on prod, 86,796,263 scans)
CREATE INDEX IF NOT EXISTS program_enrolment_sync_5_index
  ON public.program_enrolment USING btree (address_id, individual_id, sync_concept_1_value, sync_concept_2_value, last_modified_date_time, organisation_id, program_id);

-- subject_migration.subject_migration_individual_id_idx  (2848 kB on prod, 3,143,389,260 scans)
CREATE INDEX IF NOT EXISTS subject_migration_individual_id_idx
  ON public.subject_migration USING btree (individual_id);