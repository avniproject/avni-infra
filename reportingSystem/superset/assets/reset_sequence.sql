SELECT * FROM information_schema.sequences;

select table_name  from information_schema.tables where table_schema = 'public' order by 1;

select *
from alert_owner_id_seq;


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



select SETVAL('ab_permission_id_seq', (SELECT MAX(id) FROM  ab_permission));
select SETVAL('ab_permission_view_id_seq', (SELECT MAX(id) FROM  ab_permission_view));
select SETVAL('ab_permission_view_role_id_seq', (SELECT MAX(id) FROM  ab_permission_view_role));
select SETVAL('ab_register_user_id_seq', (SELECT MAX(id) FROM  ab_register_user));
select SETVAL('ab_role_id_seq', (SELECT MAX(id) FROM  ab_role));
select SETVAL('ab_user_id_seq', (SELECT MAX(id) FROM  ab_user));
select SETVAL('ab_user_role_id_seq', (SELECT MAX(id) FROM  ab_user_role));
select SETVAL('ab_view_menu_id_seq', (SELECT MAX(id) FROM  ab_view_menu));
select SETVAL('access_request_id_seq', (SELECT MAX(id) FROM  access_request));
select SETVAL('alert_logs_id_seq', (SELECT MAX(id) FROM  alert_logs));
select SETVAL('alert_owner_id_seq', (SELECT MAX(id) FROM  alert_owner));
select SETVAL('alerts_id_seq', (SELECT MAX(id) FROM  alerts));
select SETVAL('annotation_id_seq', (SELECT MAX(id) FROM  annotation));
select SETVAL('annotation_layer_id_seq', (SELECT MAX(id) FROM  annotation_layer));
select SETVAL('cache_keys_id_seq', (SELECT MAX(id) FROM  cache_keys));
select SETVAL('clusters_id_seq', (SELECT MAX(id) FROM  clusters));
select SETVAL('columns_id_seq', (SELECT MAX(id) FROM  columns));
select SETVAL('css_templates_id_seq', (SELECT MAX(id) FROM  css_templates));
select SETVAL('dashboard_email_schedules_id_seq', (SELECT MAX(id) FROM  dashboard_email_schedules));
select SETVAL('dashboard_roles_id_seq', (SELECT MAX(id) FROM  dashboard_roles));
select SETVAL('dashboard_slices_id_seq', (SELECT MAX(id) FROM  dashboard_slices));
select SETVAL('dashboard_user_id_seq', (SELECT MAX(id) FROM  dashboard_user));
select SETVAL('dashboards_id_seq', (SELECT MAX(id) FROM  dashboards));
select SETVAL('datasources_id_seq', (SELECT MAX(id) FROM  datasources));
select SETVAL('dbs_id_seq', (SELECT MAX(id) FROM  dbs));
select SETVAL('druiddatasource_user_id_seq', (SELECT MAX(id) FROM  druiddatasource_user));
select SETVAL('dynamic_plugin_id_seq', (SELECT MAX(id) FROM  dynamic_plugin));
select SETVAL('favstar_id_seq', (SELECT MAX(id) FROM  favstar));
select SETVAL('filter_sets_id_seq', (SELECT MAX(id) FROM  filter_sets));
select SETVAL('key_value_id_seq', (SELECT MAX(id) FROM  key_value));
select SETVAL('keyvalue_id_seq', (SELECT MAX(id) FROM  keyvalue));
select SETVAL('logs_id_seq', (SELECT MAX(id) FROM  logs));
select SETVAL('metrics_id_seq', (SELECT MAX(id) FROM  metrics));
select SETVAL('query_id_seq', (SELECT MAX(id) FROM  query));
select SETVAL('report_execution_log_id_seq', (SELECT MAX(id) FROM  report_execution_log));
select SETVAL('report_recipient_id_seq', (SELECT MAX(id) FROM  report_recipient));
select SETVAL('report_schedule_id_seq', (SELECT MAX(id) FROM  report_schedule));
select SETVAL('report_schedule_user_id_seq', (SELECT MAX(id) FROM  report_schedule_user));
select SETVAL('rls_filter_roles_id_seq', (SELECT MAX(id) FROM  rls_filter_roles));
select SETVAL('rls_filter_tables_id_seq', (SELECT MAX(id) FROM  rls_filter_tables));
select SETVAL('row_level_security_filters_id_seq', (SELECT MAX(id) FROM  row_level_security_filters));
select SETVAL('saved_query_id_seq', (SELECT MAX(id) FROM  saved_query));
select SETVAL('sl_columns_id_seq', (SELECT MAX(id) FROM  sl_columns));
select SETVAL('sl_datasets_id_seq', (SELECT MAX(id) FROM  sl_datasets));
select SETVAL('sl_tables_id_seq', (SELECT MAX(id) FROM  sl_tables));
select SETVAL('slice_email_schedules_id_seq', (SELECT MAX(id) FROM  slice_email_schedules));
select SETVAL('slice_user_id_seq', (SELECT MAX(id) FROM  slice_user));
select SETVAL('slices_id_seq', (SELECT MAX(id) FROM  slices));
select SETVAL('sql_metrics_id_seq', (SELECT MAX(id) FROM  sql_metrics));
select SETVAL('sql_observations_id_seq', (SELECT MAX(id) FROM  sql_observations));
select SETVAL('sqlatable_user_id_seq', (SELECT MAX(id) FROM  sqlatable_user));
select SETVAL('tab_state_id_seq', (SELECT MAX(id) FROM  tab_state));
select SETVAL('table_columns_id_seq', (SELECT MAX(id) FROM  table_columns));
select SETVAL('table_schema_id_seq', (SELECT MAX(id) FROM  table_schema));
select SETVAL('tables_id_seq', (SELECT MAX(id) FROM  tables));
select SETVAL('tag_id_seq', (SELECT MAX(id) FROM  tag));
select SETVAL('tagged_object_id_seq', (SELECT MAX(id) FROM  tagged_object));
select SETVAL('url_id_seq', (SELECT MAX(id) FROM  url));
select SETVAL('user_attribute_id_seq', (SELECT MAX(id) FROM  user_attribute));

