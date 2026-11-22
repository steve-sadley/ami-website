-- =============================================================================
-- 0003  Helper functions
--
-- Every one is security definer with a locked search path, so it reads the
-- tables it needs regardless of the caller's own policies and cannot be
-- hijacked by a search path trick.
--
-- Policies must call these WRAPPED, as (select app.member_id()), not bare.
-- Wrapped, the planner evaluates them once per query. Bare, it evaluates them
-- once per row, which on cpd_entries and forum_posts is the difference between
-- a fast page and a slow one.
-- =============================================================================

create or replace function app.person_id() returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid();
$$;

create or replace function app.member_id() returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.id from public.members m where m.person_id = auth.uid();
$$;

create or replace function app.is_active_member() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select m.is_active from public.members m where m.person_id = auth.uid()),
    false);
$$;

create or replace function app.has_role(p_role text) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.role_grants g
    where g.person_id = auth.uid() and g.role_code = p_role);
$$;

create or replace function app.is_staff() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.role_grants g
    where g.person_id = auth.uid()
      and g.role_code in ('super_user', 'administrator', 'editor', 'membership', 'moderator'));
$$;

create or replace function app.is_super_user() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.role_grants g
    where g.person_id = auth.uid() and g.role_code = 'super_user');
$$;

-- Membership staff. The narrower right that covers member records, the active
-- switch, membership years and CPD acceptance.
create or replace function app.is_membership_staff() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.role_grants g
    where g.person_id = auth.uid()
      and g.role_code in ('super_user', 'administrator', 'membership'));
$$;

create or replace function app.is_editor() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.role_grants g
    where g.person_id = auth.uid()
      and g.role_code in ('super_user', 'administrator', 'editor'));
$$;

create or replace function app.is_moderator() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.role_grants g
    where g.person_id = auth.uid()
      and g.role_code in ('super_user', 'administrator', 'moderator'));
$$;

grant execute on function
  app.person_id(), app.member_id(), app.is_active_member(), app.has_role(text),
  app.is_staff(), app.is_super_user(), app.is_membership_staff(),
  app.is_editor(), app.is_moderator()
to anon, authenticated, service_role;
