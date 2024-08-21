-- to get information about where schema used
select * from  information_schema.tables where table_schema = 'public' and table_name like '%schema%';


select 'update '|| table_name || ' set ' || column_name || ' = null where id > 0 and '|| column_name ||' is not null;' from  information_schema.columns where table_schema = 'public' and column_name like '%schema%';


update saved_query set schema = null where id > 0 and schema is not null;
update table_schema set schema = null where id > 0 and schema is not null;
update query set schema = null where id > 0 and schema is not null;
update query set tmp_schema_name = null where id > 0 and tmp_schema_name is not null;
update tab_state set schema = null where id > 0 and schema is not null;
update slices set schema_perm = null where id > 0 and schema_perm is not null;
update dbs set force_ctas_schema = null where id > 0 and force_ctas_schema is not null;
update tables set schema = null where id > 0 and schema is not null;
update tables set schema_perm = null where id > 0 and schema_perm is not null;
update sl_tables set schema = null where id > 0 and schema is not null;



select 'select '|| column_name || ' from ' || table_name || ' where id > 0 and '|| column_name ||' is not null limit 1;' from  information_schema.columns where table_schema = 'public' and column_name like '%schema%';


select schema from saved_query where id > 0 and schema is not null limit 1;
select schema from table_schema where id > 0 and schema is not null limit 1;
select schema from query where id > 0 and schema is not null limit 1;
select tmp_schema_name from query where id > 0 and tmp_schema_name is not null limit 1;
select schema from tab_state where id > 0 and schema is not null limit 1;
select schema_perm from slices where id > 0 and schema_perm is not null limit 1;
select force_ctas_schema from dbs where id > 0 and force_ctas_schema is not null limit 1;
select schema from tables where id > 0 and schema is not null limit 1;
select schema_perm from tables where id > 0 and schema_perm is not null limit 1;
select schema from sl_tables where id > 0 and schema is not null limit 1;