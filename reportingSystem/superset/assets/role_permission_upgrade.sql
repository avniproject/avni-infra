---------- update recent activity ------------------------------

select apv.id
from ab_permission p
         join ab_permission_view apv on p.id = apv.permission_id
         join ab_view_menu avm on apv.view_menu_id = avm.id
where p.name =  'can_recent_activity' and avm.name = 'Superset';
-- permission_view_id : 124

select role.id, role.name
from ab_role role
where role.id not in(
    select role_id
    from ab_permission p
             join ab_permission_view apv on p.id = apv.permission_id
             join ab_view_menu avm on apv.view_menu_id = avm.id
             join ab_permission_view_role apvr on apv.id = apvr.permission_view_id
    where p.name =  'can_recent_activity' and avm.name = 'Superset'
 )and (role.name not in ('Public', 'granter', 'sql_lab')) or (role.name ilike '%gam%' );
-- role ids : [17, 18, 20, 22, 23, 24, 26, 27, 29, 38, 39, 25, 44]


------------ update explore --------------------------------------

select apv.id
from ab_permission p
         join ab_permission_view apv on p.id = apv.permission_id
         join ab_view_menu avm on apv.view_menu_id = avm.id
where p.name =  'can_read' and avm.name = 'Explore';
-- permission_view_id : 5890


select role.id, role.name
from ab_role role
where role.id not in(
    select role_id
    from ab_permission p
             join ab_permission_view apv on p.id = apv.permission_id
             join ab_view_menu avm on apv.view_menu_id = avm.id
             join ab_permission_view_role apvr on apv.id = apvr.permission_view_id
    where p.name =  'can_read' and avm.name = 'Explore'
) and role.name ilike '%gam%' ;
-- role ids : [29, 30, 31, 32, 33, 34, 35, 36, 37, 39]

