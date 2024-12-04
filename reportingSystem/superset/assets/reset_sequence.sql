SELECT * FROM information_schema.sequences order by sequence_name;


select 'SELECT SETVAL(''' || table_name || '_id_seq'' ,(SELECT GREATEST(MAX(id), nextval(''' || table_name || '_id_seq'')-1) from  ' || table_name || '));'
from information_schema.tables
where table_schema = 'public'
  and table_name in(
    SELECT split_part(sequence_name,'_id_seq',1) FROM information_schema.sequences
)
order by 1;
-- to generate stamtement


SELECT
    sequence_schema,
    sequence_name,
    last_value AS current_value
FROM
    information_schema.sequences
        JOIN pg_sequences ON sequence_schema = schemaname AND sequence_name = sequencename
        JOIN pg_class ON pg_class.relname = sequence_name
        JOIN pg_sequence ON pg_sequence.seqrelid = pg_class.oid
where last_value is null
ORDER BY
    sequence_schema,
    sequence_name
;



SELECT SETVAL('ab_permission_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_permission_id_seq')-1) from  ab_permission));
SELECT SETVAL('ab_permission_view_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_permission_view_id_seq')-1) from  ab_permission_view));
SELECT SETVAL('ab_permission_view_role_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_permission_view_role_id_seq')-1) from  ab_permission_view_role));
SELECT SETVAL('ab_register_user_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_register_user_id_seq')-1) from  ab_register_user));
SELECT SETVAL('ab_role_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_role_id_seq')-1) from  ab_role));
SELECT SETVAL('ab_user_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_user_id_seq')-1) from  ab_user));
SELECT SETVAL('ab_user_role_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_user_role_id_seq')-1) from  ab_user_role));
SELECT SETVAL('ab_view_menu_id_seq' ,(SELECT GREATEST(MAX(id), nextval('ab_view_menu_id_seq')-1) from  ab_view_menu));
SELECT SETVAL('access_request_id_seq' ,(SELECT GREATEST(MAX(id), nextval('access_request_id_seq')-1) from  access_request));
SELECT SETVAL('alert_logs_id_seq' ,(SELECT GREATEST(MAX(id), nextval('alert_logs_id_seq')-1) from  alert_logs));
SELECT SETVAL('alert_owner_id_seq' ,(SELECT GREATEST(MAX(id), nextval('alert_owner_id_seq')-1) from  alert_owner));
SELECT SETVAL('alerts_id_seq' ,(SELECT GREATEST(MAX(id), nextval('alerts_id_seq')-1) from  alerts));
SELECT SETVAL('annotation_id_seq' ,(SELECT GREATEST(MAX(id), nextval('annotation_id_seq')-1) from  annotation));
SELECT SETVAL('annotation_layer_id_seq' ,(SELECT GREATEST(MAX(id), nextval('annotation_layer_id_seq')-1) from  annotation_layer));
SELECT SETVAL('cache_keys_id_seq' ,(SELECT GREATEST(MAX(id), nextval('cache_keys_id_seq')-1) from  cache_keys));
SELECT SETVAL('clusters_id_seq' ,(SELECT GREATEST(MAX(id), nextval('clusters_id_seq')-1) from  clusters));
SELECT SETVAL('columns_id_seq' ,(SELECT GREATEST(MAX(id), nextval('columns_id_seq')-1) from  columns));
SELECT SETVAL('css_templates_id_seq' ,(SELECT GREATEST(MAX(id), nextval('css_templates_id_seq')-1) from  css_templates));
SELECT SETVAL('dashboard_email_schedules_id_seq' ,(SELECT GREATEST(MAX(id), nextval('dashboard_email_schedules_id_seq')-1) from  dashboard_email_schedules));
SELECT SETVAL('dashboard_roles_id_seq' ,(SELECT GREATEST(MAX(id), nextval('dashboard_roles_id_seq')-1) from  dashboard_roles));
SELECT SETVAL('dashboard_slices_id_seq' ,(SELECT GREATEST(MAX(id), nextval('dashboard_slices_id_seq')-1) from  dashboard_slices));
SELECT SETVAL('dashboard_user_id_seq' ,(SELECT GREATEST(MAX(id), nextval('dashboard_user_id_seq')-1) from  dashboard_user));
SELECT SETVAL('dashboards_id_seq' ,(SELECT GREATEST(MAX(id), nextval('dashboards_id_seq')-1) from  dashboards));
SELECT SETVAL('datasources_id_seq' ,(SELECT GREATEST(MAX(id), nextval('datasources_id_seq')-1) from  datasources));
SELECT SETVAL('dbs_id_seq' ,(SELECT GREATEST(MAX(id), nextval('dbs_id_seq')-1) from  dbs));
SELECT SETVAL('druiddatasource_user_id_seq' ,(SELECT GREATEST(MAX(id), nextval('druiddatasource_user_id_seq')-1) from  druiddatasource_user));
SELECT SETVAL('dynamic_plugin_id_seq' ,(SELECT GREATEST(MAX(id), nextval('dynamic_plugin_id_seq')-1) from  dynamic_plugin));
SELECT SETVAL('favstar_id_seq' ,(SELECT GREATEST(MAX(id), nextval('favstar_id_seq')-1) from  favstar));
SELECT SETVAL('filter_sets_id_seq' ,(SELECT GREATEST(MAX(id), nextval('filter_sets_id_seq')-1) from  filter_sets));
SELECT SETVAL('key_value_id_seq' ,(SELECT GREATEST(MAX(id), nextval('key_value_id_seq')-1) from  key_value));
SELECT SETVAL('keyvalue_id_seq' ,(SELECT GREATEST(MAX(id), nextval('keyvalue_id_seq')-1) from  keyvalue));
SELECT SETVAL('logs_id_seq' ,(SELECT GREATEST(MAX(id), nextval('logs_id_seq')-1) from  logs));
SELECT SETVAL('metrics_id_seq' ,(SELECT GREATEST(MAX(id), nextval('metrics_id_seq')-1) from  metrics));
SELECT SETVAL('query_id_seq' ,(SELECT GREATEST(MAX(id), nextval('query_id_seq')-1) from  query));
SELECT SETVAL('report_execution_log_id_seq' ,(SELECT GREATEST(MAX(id), nextval('report_execution_log_id_seq')-1) from  report_execution_log));
SELECT SETVAL('report_recipient_id_seq' ,(SELECT GREATEST(MAX(id), nextval('report_recipient_id_seq')-1) from  report_recipient));
SELECT SETVAL('report_schedule_id_seq' ,(SELECT GREATEST(MAX(id), nextval('report_schedule_id_seq')-1) from  report_schedule));
SELECT SETVAL('report_schedule_user_id_seq' ,(SELECT GREATEST(MAX(id), nextval('report_schedule_user_id_seq')-1) from  report_schedule_user));
SELECT SETVAL('rls_filter_roles_id_seq' ,(SELECT GREATEST(MAX(id), nextval('rls_filter_roles_id_seq')-1) from  rls_filter_roles));
SELECT SETVAL('rls_filter_tables_id_seq' ,(SELECT GREATEST(MAX(id), nextval('rls_filter_tables_id_seq')-1) from  rls_filter_tables));
SELECT SETVAL('row_level_security_filters_id_seq' ,(SELECT GREATEST(MAX(id), nextval('row_level_security_filters_id_seq')-1) from  row_level_security_filters));
SELECT SETVAL('saved_query_id_seq' ,(SELECT GREATEST(MAX(id), nextval('saved_query_id_seq')-1) from  saved_query));
SELECT SETVAL('sl_columns_id_seq' ,(SELECT GREATEST(MAX(id), nextval('sl_columns_id_seq')-1) from  sl_columns));
SELECT SETVAL('sl_datasets_id_seq' ,(SELECT GREATEST(MAX(id), nextval('sl_datasets_id_seq')-1) from  sl_datasets));
SELECT SETVAL('sl_tables_id_seq' ,(SELECT GREATEST(MAX(id), nextval('sl_tables_id_seq')-1) from  sl_tables));
SELECT SETVAL('slice_email_schedules_id_seq' ,(SELECT GREATEST(MAX(id), nextval('slice_email_schedules_id_seq')-1) from  slice_email_schedules));
SELECT SETVAL('slice_user_id_seq' ,(SELECT GREATEST(MAX(id), nextval('slice_user_id_seq')-1) from  slice_user));
SELECT SETVAL('slices_id_seq' ,(SELECT GREATEST(MAX(id), nextval('slices_id_seq')-1) from  slices));
SELECT SETVAL('sql_metrics_id_seq' ,(SELECT GREATEST(MAX(id), nextval('sql_metrics_id_seq')-1) from  sql_metrics));
SELECT SETVAL('sql_observations_id_seq' ,(SELECT GREATEST(MAX(id), nextval('sql_observations_id_seq')-1) from  sql_observations));
SELECT SETVAL('sqlatable_user_id_seq' ,(SELECT GREATEST(MAX(id), nextval('sqlatable_user_id_seq')-1) from  sqlatable_user));
SELECT SETVAL('tab_state_id_seq' ,(SELECT GREATEST(MAX(id), nextval('tab_state_id_seq')-1) from  tab_state));
SELECT SETVAL('table_columns_id_seq' ,(SELECT GREATEST(MAX(id), nextval('table_columns_id_seq')-1) from  table_columns));
SELECT SETVAL('table_schema_id_seq' ,(SELECT GREATEST(MAX(id), nextval('table_schema_id_seq')-1) from  table_schema));
SELECT SETVAL('tables_id_seq' ,(SELECT GREATEST(MAX(id), nextval('tables_id_seq')-1) from  tables));
SELECT SETVAL('tag_id_seq' ,(SELECT GREATEST(MAX(id), nextval('tag_id_seq')-1) from  tag));
SELECT SETVAL('tagged_object_id_seq' ,(SELECT GREATEST(MAX(id), nextval('tagged_object_id_seq')-1) from  tagged_object));
SELECT SETVAL('url_id_seq' ,(SELECT GREATEST(MAX(id), nextval('url_id_seq')-1) from  url));
SELECT SETVAL('user_attribute_id_seq' ,(SELECT GREATEST(MAX(id), nextval('user_attribute_id_seq')-1) from  user_attribute));


SELECT
    sequence_schema,
    sequence_name,
    last_value AS current_value
FROM
    information_schema.sequences
        JOIN pg_sequences ON sequence_schema = schemaname AND sequence_name = sequencename
        JOIN pg_class ON pg_class.relname = sequence_name
        JOIN pg_sequence ON pg_sequence.seqrelid = pg_class.oid
where last_value is null
ORDER BY
    sequence_schema,
    sequence_name
;
-- it should shows 0 result at end if not. no move further and check the sequence.