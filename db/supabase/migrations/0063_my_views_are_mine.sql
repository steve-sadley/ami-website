-- =============================================================================
-- 0063  Every "my" view shows the signed in person's own rows, even to staff
--
-- Found by Steve on 1 November 2026, signing in to the site as himself: My AMI
-- said "Your record could not be loaded just now."
--
-- my_profile, my_card, my_cpd_summary and my_cpd run as the caller and never
-- said whose rows they were. They relied on row level security to keep a member
-- to their own, which works for a member. Membership staff, though, may read
-- every member's row, so for somebody who is BOTH staff and a member these
-- views returned the whole membership: 118 profiles where the page asked for
-- one, so it gave up. My CPD would have listed everybody's entries as theirs.
-- Steve is the first person who is both, which is why nobody saw it before.
--
-- Each is restated as itself with its own filter, so it no longer depends on
-- what the caller's role happens to allow:
--   my_profile, my_card, my_cpd_summary   wrapped: only rows whose member_id is
--                                         app.member_id()
--   my_cpd                                has no member_id column, so its own
--                                         query gains WHERE e.member_id =
--                                         app.member_id()
-- The columns are unchanged, so nothing that reads them notices. They still
-- run as the caller, so a member still sees only what row level security lets
-- them see as well. my_posts, my_learning and my_recent already filter on the
-- signed in member and are left alone. Test 62 checks EVERY my_ view there is,
-- so one added later without a filter fails it.
--
-- Safe to run twice: a view already filtered is left alone.
-- =============================================================================
do $$
declare
  v   text;
  def text;
begin
  foreach v in array array['my_profile', 'my_card', 'my_cpd_summary'] loop
    def := pg_get_viewdef(('public.' || v)::regclass, true);
    if def like '%my_own_rows%' then
      continue;
    end if;
    def := regexp_replace(def, ';\s*$', '');
    execute format(
      'create or replace view public.%I with (security_invoker = true) as '
      'select q.* from (%s) q where q.member_id = (select app.member_id() as my_own_rows)',
      v, def);
  end loop;

  def := pg_get_viewdef('public.my_cpd'::regclass, true);
  if def not like '%my_own_rows%' then
    def := regexp_replace(def, ';\s*$', '');
    -- Appending a WHERE is only right while the query still ends with its last
    -- join and has no WHERE of its own at the top. If that ever changes, stop.
    if def !~ 'JOIN cpd_activity_types t ON t\.id = e\.activity_type_id\s*$' then
      raise exception 'my_cpd no longer ends as 0063 expects; restate it by hand rather than guess.';
    end if;
    execute format(
      'create or replace view public.my_cpd with (security_invoker = true) as '
      '%s WHERE e.member_id = (select app.member_id() as my_own_rows)', def);
  end if;
end $$;
