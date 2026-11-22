-- =============================================================================
-- Are the admin views gated to staff on this database?
--
--   Supabase SQL editor: paste and run. It changes nothing.
--
-- Every row should say yes. A "no" means 0057 has not reached that view: run
-- 0057_admin_views_staff_only.sql again (it is safe twice), then this again.
-- Running an older migration after 0057 puts the view back without its gate,
-- which is the usual reason.
-- =============================================================================
select c.relname as view,
       case when pg_get_viewdef(c.oid, true) like '%staff_gate%' then 'yes' else 'NO' end as gated_to_staff
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'v' and c.relname like 'admin\_%'
 order by gated_to_staff, c.relname;
