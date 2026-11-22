-- =============================================================================
-- 0057  The admin views answer staff only
--
-- Found by the security check on 31 October (the first run, before any real
-- member data): a signed in member could read admin_member_list and
-- admin_dynamics_member_check. Each gave only the member's own row, because
-- the views run as the caller and row level security on the tables beneath
-- them kept everybody else out. So nothing leaked. But a view written for the
-- office should not depend on the tables happening to filter it, and the own
-- row it did give included office notes.
--
-- Every view whose name starts admin_ now answers nobody but staff, whatever
-- the tables beneath it allow: each is restated as itself with a staff gate
-- around it. Its columns are unchanged, so nothing that reads it notices, and
-- it still runs as the caller, so staff still see only what their own role
-- lets them.
--
-- A view added later under the admin_ name must carry the same gate. Test 49
-- checks every admin_ view there is, so one that forgets will fail it.
--
-- Safe to run twice: a view already gated is left alone.
-- =============================================================================
do $$
declare
  v    record;
  def  text;
begin
  for v in
    select c.relname, c.reloptions
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v' and c.relname like 'admin\_%'
  loop
    def := pg_get_viewdef(('public.' || quote_ident(v.relname))::regclass, true);
    if def like '%app.is_staff()%AS staff_gate%' or def like '%staff_gate%' then
      continue;
    end if;
    def := regexp_replace(def, ';\s*$', '');
    execute format(
      'create or replace view public.%I with (security_invoker = true) as '
      'select q.* from (%s) q, lateral (select app.is_staff() as staff_gate) g where g.staff_gate',
      v.relname, def);
  end loop;
end $$;
