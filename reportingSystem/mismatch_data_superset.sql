--  remove dashboard roles which doesn't have corresponding ab_roles
begin transaction ;

select count(*)
from dashboard_roles
where role_id not in (
    select id from ab_role
);
-- 4

delete from dashboard_roles
where role_id not in (
    select id from ab_role
);


select count(*)
from dashboard_roles
where role_id not in (
    select id from ab_role
);
-- 0

commit;
rollback; -- (if count is not 0)

-- remove tab_state where associate query is not avialable
begin transaction;

select count(*)
from tab_state
where latest_query_id not in (
    select client_id from query
)
;
-- 15

delete from tab_state
where latest_query_id not in (
    select client_id from query
)
;

select count(*)
from tab_state
where latest_query_id not in (
    select client_id from query
)
;
-- 0

commit;
rollback; -- (if count is not 0)
