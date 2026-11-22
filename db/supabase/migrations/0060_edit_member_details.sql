-- =============================================================================
-- 0060  The office edits the details the website holds about a member
--
-- Steve, 1 November 2026. Dynamics owns a member's name, emails, whether they
-- are a member and their grade (0054), and the member owns their mobile and
-- addresses (/profile). That left four things the website alone holds and no
-- screen could change: the membership number, the joining date, the job title
-- and the employer. Until now the only way was SQL in the Supabase editor.
--
-- public.update_member_details does all four in one call, for membership staff
-- only, and refuses rather than guesses:
--
--   the number: trimmed and upper cased, letters, digits and hyphens only, at
--     most 20 characters, not held by another member (in any case), and not a
--     number the previous site's register (0058) keeps for somebody else who
--     has not been loaded yet, such as Monday's four. A register number is
--     taken by the member whose surname matches it, and the register then
--     remembers who took it, as the load does. A number the member gives up
--     is released on the register so it can be taken again.
--   the joining date: not in the future.
--   the employer: a name. An organisation with that name (ignoring case) is
--     used, otherwise one is made. Empty means no employer.
--   the job title: trimmed; empty means none.
--
-- DEFINER, because the register is readable by nobody but the owner. The staff
-- check is the first thing it does. Nothing here touches the columns Dynamics
-- owns, so members_dynamics_guard has nothing to say, and the audit trigger
-- from 0005 records the change with the staff member's own id.
--
-- admin_member_list gains three columns at the end, so nothing that reads it
-- notices: employer, in_dynamics (whether the person is linked to a Dynamics
-- contact) and alt_email, for the card to show what Dynamics holds. It keeps
-- 0057's staff gate.
--
-- Safe to run twice.
-- =============================================================================

create or replace function public.update_member_details(
  p_member_id         uuid,
  p_membership_number text,
  p_joined_on         date,
  p_current_job_title text default null,
  p_employer          text default null
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  m        public.members;
  v_family text;
  v_num    text := upper(btrim(coalesce(p_membership_number, '')));
  v_title  text := nullif(btrim(coalesce(p_current_job_title, '')), '');
  v_emp    text := nullif(btrim(regexp_replace(coalesce(p_employer, ''), '\s+', ' ', 'g')), '');
  v_org    uuid;
  reg      record;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may change a member''s details.' using errcode = '42501';
  end if;

  select * into m from public.members where id = p_member_id for update;
  if not found then
    raise exception 'Membership % not found.', p_member_id using errcode = 'P0002';
  end if;
  select family_name into v_family from public.people where id = m.person_id;

  -- the number
  if v_num = '' then
    raise exception 'The membership number cannot be empty.' using errcode = '22023';
  end if;
  if length(v_num) > 20 or v_num !~ '^[A-Z0-9-]+$' then
    raise exception 'A membership number is letters, digits and hyphens only, at most 20 characters.'
      using errcode = '22023';
  end if;
  if exists (select 1 from public.members
              where upper(membership_number) = v_num and id <> m.id) then
    raise exception 'Membership number % is already held by another member.', v_num using errcode = '23505';
  end if;
  if v_num <> upper(m.membership_number) then
    select * into reg from public.legacy_register where upper(membership_number) = v_num;
    if found and reg.used_by is distinct from m.id
       and (reg.used_by is null or exists (select 1 from public.members where id = reg.used_by))
       and lower(btrim(reg.family_name)) <> lower(btrim(coalesce(v_family, ''))) then
      raise exception 'Membership number % is kept on the previous register for % %, who has not been loaded yet.',
        v_num, reg.given_name, reg.family_name using errcode = '23505';
    end if;
  end if;

  -- the date
  if p_joined_on is null then
    raise exception 'The joining date cannot be empty.' using errcode = '22023';
  end if;
  if p_joined_on > current_date then
    raise exception 'The joining date cannot be in the future.' using errcode = '22023';
  end if;

  -- the employer
  if v_emp is not null then
    if length(v_emp) > 200 then
      raise exception 'An employer''s name is at most 200 characters.' using errcode = '22023';
    end if;
    select id into v_org from public.organisations where lower(name) = lower(v_emp);
    if v_org is null then
      insert into public.organisations (name) values (v_emp) returning id into v_org;
    end if;
  end if;

  update public.members
     set membership_number = v_num,
         joined_on         = p_joined_on,
         current_job_title = v_title,
         employer_id       = v_org
   where id = m.id;

  -- The register remembers who holds its numbers, as the load does.
  if v_num <> upper(m.membership_number) then
    update public.legacy_register set used_by = null
     where used_by = m.id and upper(membership_number) <> v_num;
    update public.legacy_register set used_by = m.id
     where upper(membership_number) = v_num;
  end if;

  return jsonb_build_object(
    'membership_number', v_num,
    'number_changed',    v_num <> upper(m.membership_number),
    'joined_on',         p_joined_on,
    'current_job_title', v_title,
    'employer',          v_emp);
end;
$$;

revoke all on function public.update_member_details(uuid, text, date, text, text) from public;
grant execute on function public.update_member_details(uuid, text, date, text, text) to authenticated, service_role;

comment on function public.update_member_details(uuid, text, date, text, text) is
  'The four things only the website holds about a member: number, joining date, job title, employer. '
  'Membership staff only. Name, emails and grade come from Dynamics and are not touched here (0060).';

-- -----------------------------------------------------------------------------
-- The members list, with the employer and the Dynamics link, still staff only
-- -----------------------------------------------------------------------------
create or replace view public.admin_member_list
with (security_invoker = true) as
select q.* from (
  select m.id, m.membership_number, m.is_active, m.status,
         p.given_name, p.family_name, p.email,
         g.name as grade, m.grade_id,
         m.joined_on, m.current_job_title,
         p.auth_user_id is not null as has_account,
         m.activated_at, m.deactivated_at,
         o.name as employer,
         p.dynamics_contact_id is not null as in_dynamics,
         p.alt_email
    from public.members m
    join public.people p on p.id = m.person_id
    join public.membership_grades g on g.id = m.grade_id
    left join public.organisations o on o.id = m.employer_id
) q, lateral (select app.is_staff() as staff_gate) g
where g.staff_gate;
