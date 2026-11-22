-- =============================================================================
-- 0056  Loading the AMI members from Dynamics, built now, used later
--
-- Steve, 31 October: put every AMI member on the website, from Dynamics, with
-- new membership numbers. Agreed the same evening: build it now, and press it
-- only after the independent security test (or just before it, so the testers
-- see real data). The handover rule stands: no real member data until then.
--
-- So the load has a lock. The setting dynamics_member_load is 'off', and
-- dynamics_members_load refuses to create anybody until a person switches it
-- on, deliberately, in the SQL editor:
--
--   update public.system_settings set value = 'on' where key = 'dynamics_member_load';
--
-- A preview (p_go false) works whatever the setting: who would be created,
-- with which number and grade, and who would be left out and why. Super users
-- only, both ways.
--
-- WHO IS CREATED: every AMI member Dynamics lists (dynamics_members_seen) who
-- is not linked to anybody on the website, has an email nobody on the website
-- holds, and whose AMI Category is mapped to a grade. Each gets a person
-- (name and emails from Dynamics, linked to the contact) and an ACTIVE, current
-- membership with a new number, joined on the day of the load. Nobody is sent
-- anything: no welcome email, no card. Those come when they first sign in.
--
-- NUMBERS: prefix, then the number padded to the digits given, in surname then
-- first name order, from the start given, skipping any already used.
--
-- Safe to run twice.
-- =============================================================================

insert into public.system_settings (key, value, note) values
  ('dynamics_member_load', 'off',
   'on lets a super user create website members from the AMI members in Dynamics '
   '(Members and Dynamics, Create website members). Leave off until the security test.')
on conflict (key) do nothing;

create or replace function public.dynamics_members_load(
  p_prefix text default 'AMI-', p_start integer default 1, p_digits integer default 4, p_go boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  r        record;
  n        integer := greatest(coalesce(p_start, 1), 1);
  v_num    text;
  v_pid    uuid;
  v_mid    uuid;
  v_made   integer := 0;
  v_plan   jsonb := '[]'::jsonb;
  v_left   jsonb := '[]'::jsonb;
  v_prefix text := coalesce(p_prefix, '');
begin
  if not app.is_super_user() then
    raise exception 'Loading members is for a super user.' using errcode = '42501';
  end if;
  if v_prefix !~ '^[A-Za-z0-9-]{0,10}$' or p_digits not between 1 and 8 then
    raise exception 'The prefix is up to 10 letters, digits or hyphens, and the number 1 to 8 digits.' using errcode = '22023';
  end if;
  if p_go and coalesce(app.setting('dynamics_member_load'), 'off') <> 'on' then
    raise exception 'Loading members is switched off (dynamics_member_load). It stays off until the security test has been done.'
      using errcode = '42501';
  end if;

  for r in
    select s.*, gm.grade_id, g.name as grade_name
      from public.dynamics_members_seen s
      left join public.dynamics_grade_map gm on gm.category_key = app.name_key(s.category)
      left join public.membership_grades g on g.id = gm.grade_id
     where s.person_id is null
     order by lower(coalesce(s.family_name, '')), lower(coalesce(s.given_name, '')), s.contact_id
  loop
    if r.email is null then
      v_left := v_left || jsonb_build_object('name', btrim(coalesce(r.given_name, '') || ' ' || coalesce(r.family_name, '')),
                                             'why', 'No email in Dynamics.');
      continue;
    end if;
    if r.grade_id is null then
      v_left := v_left || jsonb_build_object('name', btrim(coalesce(r.given_name, '') || ' ' || coalesce(r.family_name, '')),
                                             'why', 'AMI Category ' || coalesce('"' || r.category || '"', 'empty') || ' is not mapped to a grade.');
      continue;
    end if;
    if r.family_name is null or r.given_name is null then
      v_left := v_left || jsonb_build_object('name', coalesce(r.given_name, r.family_name, r.email),
                                             'why', 'No first or last name in Dynamics.');
      continue;
    end if;
    if exists (select 1 from public.people p
                where lower(btrim(p.email)) in (r.email, r.email2) or p.alt_email in (r.email, r.email2)) then
      v_left := v_left || jsonb_build_object('name', r.given_name || ' ' || r.family_name,
                                             'why', 'Somebody on the website already has one of their emails; the sync will link them.');
      continue;
    end if;

    loop
      v_num := v_prefix || lpad(n::text, p_digits, '0');
      exit when not exists (select 1 from public.members where upper(membership_number) = upper(v_num));
      n := n + 1;
    end loop;
    n := n + 1;

    if p_go then
      insert into public.people (given_name, family_name, email, alt_email, dynamics_contact_id)
      values (r.given_name, r.family_name, r.email, r.email2, r.contact_id)
      returning id into v_pid;
      insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status, activated_at)
      values (v_pid, v_num, r.grade_id, current_date, true, 'current', now())
      returning id into v_mid;
      insert into public.member_preferences (member_id) values (v_mid);
      update public.dynamics_members_seen set person_id = v_pid, problem = null where contact_id = r.contact_id;
      v_made := v_made + 1;
    elsif jsonb_array_length(v_plan) < 25 then
      v_plan := v_plan || jsonb_build_object('number', v_num, 'name', r.given_name || ' ' || r.family_name,
                                             'grade', r.grade_name, 'email', r.email);
    end if;
    if not p_go then v_made := v_made + 1; end if;
  end loop;

  return jsonb_build_object('go', p_go, 'count', v_made, 'first', v_plan, 'left_out', v_left,
                            'allowed', coalesce(app.setting('dynamics_member_load'), 'off') = 'on');
end;
$$;
revoke all on function public.dynamics_members_load(text, integer, integer, boolean) from public, anon;
grant execute on function public.dynamics_members_load(text, integer, integer, boolean) to authenticated;
