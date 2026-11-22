-- =============================================================================
-- 0040  The CPD scheme page lists the activities the office has switched on
--
-- Steve, 30 October 2026: "the web pages automatically reflect the CPD ticked
-- in the admin". The two "what counts" cards on /cpd-scheme used to carry a
-- typed list of activities, which went out of date the evening the 2027 scheme
-- was agreed. They are now drawn from this view: every ACTIVE activity type,
-- core in one card and non core in the other, with what each is worth.
--
-- Only what a visitor needs: the name, core or not, the value, the order.
-- Nothing about who logs it, evidence or word counts, and nothing switched off.
--
-- security_invoker is NOT set, deliberately, and that is the pattern 0012 uses
-- for every public view: anon holds no grant on cpd_activity_types itself, so
-- the view has to read the table as its owner. The WHERE is the whole of what
-- the public may see.
--
-- Safe to run twice.
-- =============================================================================
create or replace view public.public_cpd_activities
with (security_invoker = false) as
  select t.name, t.is_core, t.points, t.points_min, t.points_max, t.sort_order
    from public.cpd_activity_types t
   where t.active
   order by t.is_core desc, t.sort_order, t.name;

revoke all on public.public_cpd_activities from public;
grant select on public.public_cpd_activities to anon, authenticated;

comment on view public.public_cpd_activities is
  'The active CPD activity types, for the CPD scheme page. Changing a type on '
  'the admin app''s CPD activity types screen changes the page.';
