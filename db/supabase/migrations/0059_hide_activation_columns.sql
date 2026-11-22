-- =============================================================================
-- 0059  A member's own row no longer shows who switched it, or why
--
-- From the 31 October security check. A signed in member reads their own row
-- on public.members (members_select_own), and that row carried three columns
-- written for the office: activated_by and deactivated_by (the person id of the
-- member of staff who pressed the switch) and deactivation_reason (the office's
-- words on why a membership ended). Nothing on the site shows them, but anybody
-- with a browser console could read them.
--
-- Row level security decides rows, not columns (see 0028), so this is done with
-- a column grant: the table grant is taken away and given back column by column,
-- leaving those three out.
--
-- It is an ALLOW list, on purpose, as 0028's guard is. A column added to members
-- later is hidden from signed in users until somebody adds it here, and the
-- failure is a loud "permission denied" rather than a quiet leak.
--
-- Members and staff are the same database role, so staff lose a direct read of
-- the three columns too. Nothing in the admin app or the site reads them today.
-- The office keeps a route to them through public.member_activation(), which is
-- staff only and gives names rather than ids.
--
-- activated_at and deactivated_at stay readable: admin_member_list uses both,
-- and a member seeing when their own membership started or ended is no secret.
--
-- Writes are untouched. set_member_active updates deactivation_reason with a
-- WHERE on id only, and the stamping trigger needs no privilege of the caller.
--
-- Safe to run twice.
-- =============================================================================

revoke select on public.members from authenticated;

grant select (
  id, person_id, membership_number, grade_id, employer_id, current_job_title,
  joined_on, is_active, status, activated_at, deactivated_at,
  created_at, updated_at
) on public.members to authenticated;

-- A column level revoke does nothing while a table level grant stands, and a
-- table level grant restored by any later migration would quietly undo this.
-- Revoking the three columns as well means a stray column grant on one of them
-- is the only way back, which test 53 looks for.
revoke select (activated_by, deactivated_by, deactivation_reason)
  on public.members from authenticated, anon;

-- -----------------------------------------------------------------------------
-- The office's route to the three columns
-- -----------------------------------------------------------------------------
create or replace function public.member_activation(p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  r jsonb;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may see who switched a membership.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
           'activated_at',        m.activated_at,
           'activated_by_id',     m.activated_by,
           'activated_by',        nullif(trim(coalesce(pa.given_name, '') || ' ' || coalesce(pa.family_name, '')), ''),
           'deactivated_at',      m.deactivated_at,
           'deactivated_by_id',   m.deactivated_by,
           'deactivated_by',      nullif(trim(coalesce(pd.given_name, '') || ' ' || coalesce(pd.family_name, '')), ''),
           'deactivation_reason', m.deactivation_reason)
    into r
    from public.members m
    left join public.people pa on pa.id = m.activated_by
    left join public.people pd on pd.id = m.deactivated_by
   where m.id = p_member_id;

  if r is null then
    raise exception 'Membership % not found.', p_member_id;
  end if;
  return r;
end;
$$;

revoke all on function public.member_activation(uuid) from public;
grant execute on function public.member_activation(uuid) to authenticated, service_role;

comment on function public.member_activation(uuid) is
  'Who switched a membership on or off, when, and the office''s reason. Membership '
  'staff only. The three columns behind it are not readable by signed in users '
  'since 0059, so this is the office''s one route to them.';
