-- IMPORTANT: This has to be run only against Superset DB and NOT on openchs database

-- to get information about where schema used
select * from  information_schema.tables where table_schema = 'public' and table_name like '%schema%';

-- IMPORTANT: This has to be run only against Superset DB and NOT on openchs database


-- Generate the update commands to be invoked to remove schema config
select 'update '|| table_name || ' set ' || column_name || ' = null where id > 0 and '|| column_name ||' is not null;' from  information_schema.columns where table_schema = 'public' and column_name like '%schema%';

-- IMPORTANT: This has to be run only against Superset DB and NOT on openchs database

-- Execute the Update commands generated from Select Sql command above, a subset of which would be as follows:
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


-- Generate the select commands to be invoked to CHECK for config where org_schema has been set, these should return empty results
select 'select '|| column_name || ' from ' || table_name || ' where id > 0 and '|| column_name ||' is not null limit 1;' from  information_schema.columns where table_schema = 'public' and column_name like '%schema%';

-- Execute the Select commands generated from Select Sql command above to validate no pending updates, a subset of which would be as follows:
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
