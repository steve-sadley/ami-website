-- =============================================================================
-- 0058  The members keep the numbers they already have
--
-- Steve, 31 October: AMI's numbers are the order of admission within the
-- month, then the month and the year. 020626 was the second member admitted
-- in June 2026. Every member on the current AMI website already has one, and
-- keeps it. Anybody new gets the next number in the same pattern.
--
--   legacy_register   the register as the current website shows it: number,
--                     name, grade and the date joined. Filled once by
--                     load-current-register.sql, which holds the real names
--                     and so is not part of the migrations. Nobody but the
--                     database's own functions can read it.
--
--   app.given_key     a first name, with the usual short forms brought to one
--                     (Rick and Richard, Tony and Anthony, Steve and Stephen),
--                     so Dynamics' "Rick Bradbury" finds the register's.
--
--   app.next_membership_number(date)   the next number for that month:
--                     01 more than the highest already used for the month, on
--                     the website or on the register, then MMYY.
--
--   dynamics_members_load(p_go)        replaces 0056's. No prefix or start:
--                     a member found on the register (same surname, same first
--                     name or its short form, and nobody else in Dynamics
--                     matching the same entry) keeps that number and joining
--                     date. Anybody else gets the next number for the month of
--                     the load. Two Dynamics records matching one register
--                     entry are left out, with the reason, until they are
--                     merged in Dynamics. A website member already linked to
--                     Dynamics whose number is still a TEST- one is given their
--                     register number. Register entries Dynamics does not list
--                     are reported, not created.
--
--   next_membership_number()  for staff: the number the approval dialog offers.
--
-- The lock from 0056 stands: creating needs dynamics_member_load = 'on'.
-- Safe to run twice.
-- =============================================================================

create table if not exists public.legacy_register (
  membership_number text primary key,
  given_name        text not null,
  family_name       text not null,
  grade             text,
  joined_on         date,
  used_by           uuid references public.members(id) on delete set null,
  created_at        timestamptz not null default now()
);
alter table public.legacy_register enable row level security;
revoke all on public.legacy_register from public, anon, authenticated;
comment on table public.legacy_register is
  'The register from the previous AMI website, kept so each member keeps their number and joining date. '
  'Read only by the load. used_by is the membership that took the number.';

-- A first name with its usual short forms brought to one.
create or replace function app.given_key(p text) returns text
language sql immutable set search_path = ''
as $$
  select case k
    when 'rick' then 'richard' when 'ricky' then 'richard' when 'rich' then 'richard' when 'dick' then 'richard'
    when 'rob' then 'robert' when 'robbie' then 'robert' when 'bob' then 'robert' when 'bobby' then 'robert'
    when 'mick' then 'michael' when 'mike' then 'michael' when 'mickey' then 'michael'
    when 'chris' then 'christopher'
    when 'tony' then 'anthony' when 'antony' then 'anthony'
    when 'dan' then 'daniel' when 'danny' then 'daniel'
    when 'andy' then 'andrew' when 'drew' then 'andrew'
    when 'steve' then 'stephen' when 'steven' then 'stephen' when 'stevie' then 'stephen'
    when 'phil' then 'phillip' when 'philip' then 'phillip'
    when 'seb' then 'sebastian'
    when 'doug' then 'douglas'
    when 'jen' then 'jennifer' when 'jenny' then 'jennifer'
    when 'tom' then 'thomas' when 'tommy' then 'thomas'
    when 'matt' then 'matthew' when 'mathew' then 'matthew'
    when 'nick' then 'nicholas' when 'nicky' then 'nicholas'
    when 'dave' then 'david'
    when 'pete' then 'peter'
    when 'tim' then 'timothy'
    when 'ed' then 'edward' when 'eddie' then 'edward'
    when 'jim' then 'james' when 'jimmy' then 'james'
    else k end
  from (select app.name_key(p) as k) x;
$$;

-- The next number for a month: 01 more than the highest used, then MMYY.
create or replace function app.next_membership_number(p_on date) returns text
language sql stable security definer set search_path = ''
as $$
  select lpad((coalesce(max(left(n, length(n) - 4)::int), 0) + 1)::text, 2, '0') || to_char(p_on, 'MMYY')
    from (select membership_number as n from public.members
          union all
          select membership_number from public.legacy_register) x
   where n ~ ('^[0-9]{2,3}' || to_char(p_on, 'MMYY') || '$');
$$;

create or replace function public.next_membership_number() returns text
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.is_membership_staff() then
    raise exception 'Membership numbers are given by membership staff.' using errcode = '42501';
  end if;
  return app.next_membership_number(current_date);
end;
$$;
revoke all on function public.next_membership_number() from public, anon;
grant execute on function public.next_membership_number() to authenticated;

-- 0056's version goes; this one takes no prefix.
drop function if exists public.dynamics_members_load(text, integer, integer, boolean);

create or replace function public.dynamics_members_load(p_go boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  r        record;
  l        public.legacy_register;
  v_n      integer;
  v_seq    integer;
  v_month  text := to_char(current_date, 'MMYY');
  v_num    text;
  v_joined date;
  v_how    text;
  v_pid    uuid;
  v_mid    uuid;
  v_made   integer := 0;
  v_kept   integer := 0;
  v_new    integer := 0;
  v_plan   jsonb := '[]'::jsonb;
  v_left   jsonb := '[]'::jsonb;
  v_renum  jsonb := '[]'::jsonb;
  v_absent jsonb := '[]'::jsonb;
begin
  if not app.is_super_user() then
    raise exception 'Loading members is for a super user.' using errcode = '42501';
  end if;
  if p_go and coalesce(app.setting('dynamics_member_load'), 'off') <> 'on' then
    raise exception 'Loading members is switched off (dynamics_member_load). It stays off until the security test has been done.'
      using errcode = '42501';
  end if;

  -- the highest number already used this month, so new ones follow on
  select coalesce(max(left(n, length(n) - 4)::int), 0) into v_seq
    from (select membership_number as n from public.members
          union all select membership_number from public.legacy_register) x
   where n ~ ('^[0-9]{2,3}' || v_month || '$');

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

    -- On the current register?
    l := null;
    select * into l from public.legacy_register lr
     where lr.used_by is null
       and not exists (select 1 from public.members m where upper(m.membership_number) = upper(lr.membership_number))
       and app.name_key(lr.family_name) = app.name_key(r.family_name)
       and app.given_key(lr.given_name) = app.given_key(r.given_name)
     limit 1;
    if l.membership_number is not null then
      select count(*) into v_n from public.dynamics_members_seen s2
       where app.name_key(s2.family_name) = app.name_key(l.family_name)
         and app.given_key(s2.given_name) = app.given_key(l.given_name);
      if v_n > 1 then
        v_left := v_left || jsonb_build_object('name', r.given_name || ' ' || r.family_name,
                    'why', v_n || ' records in Dynamics match ' || l.given_name || ' ' || l.family_name
                           || ' (' || l.membership_number || '). Merge them in Dynamics, or untick AMI Member? on the spare ones.');
        continue;
      end if;
      v_num := l.membership_number; v_joined := coalesce(l.joined_on, current_date); v_how := 'kept';
    else
      v_seq := v_seq + 1;
      v_num := lpad(v_seq::text, 2, '0') || v_month; v_joined := current_date; v_how := 'new';
    end if;

    if p_go then
      insert into public.people (given_name, family_name, email, alt_email, dynamics_contact_id)
      values (r.given_name, r.family_name, r.email, r.email2, r.contact_id)
      returning id into v_pid;
      insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status, activated_at)
      values (v_pid, v_num, r.grade_id, v_joined, true, 'current', now())
      returning id into v_mid;
      insert into public.member_preferences (member_id) values (v_mid);
      update public.dynamics_members_seen set person_id = v_pid, problem = null where contact_id = r.contact_id;
      if v_how = 'kept' then
        update public.legacy_register set used_by = v_mid where membership_number = v_num;
      end if;
    end if;
    v_made := v_made + 1;
    if v_how = 'kept' then v_kept := v_kept + 1; else v_new := v_new + 1; end if;
    v_plan := v_plan || jsonb_build_object('number', v_num, 'name', r.given_name || ' ' || r.family_name,
                                           'grade', r.grade_name, 'email', r.email, 'how', v_how,
                                           'joined', to_char(v_joined, 'DD Mon YYYY'));
  end loop;

  -- A website member already linked to Dynamics, still on a TEST- number,
  -- takes their register number.
  for r in
    select m.id as member_id, m.membership_number, p.given_name, p.family_name
      from public.members m join public.people p on p.id = m.person_id
     where p.dynamics_contact_id is not null and m.membership_number like 'TEST-%'
  loop
    l := null;
    select * into l from public.legacy_register lr
     where lr.used_by is null
       and app.name_key(lr.family_name) = app.name_key(r.family_name)
       and app.given_key(lr.given_name) = app.given_key(r.given_name)
     limit 1;
    continue when l.membership_number is null
              or exists (select 1 from public.members where membership_number = l.membership_number);
    if p_go then
      update public.members set membership_number = l.membership_number, joined_on = coalesce(l.joined_on, joined_on)
       where id = r.member_id;
      update public.legacy_register set used_by = r.member_id where membership_number = l.membership_number;
    end if;
    v_renum := v_renum || jsonb_build_object('name', r.given_name || ' ' || r.family_name,
                                             'from', r.membership_number, 'to', l.membership_number);
  end loop;

  -- Register entries Dynamics does not list at all.
  select coalesce(jsonb_agg(jsonb_build_object('number', lr.membership_number,
                                               'name', lr.given_name || ' ' || lr.family_name, 'grade', lr.grade)
                            order by lr.family_name, lr.given_name), '[]'::jsonb)
    into v_absent
    from public.legacy_register lr
   where lr.used_by is null
     and not exists (select 1 from public.dynamics_members_seen s
                      where app.name_key(s.family_name) = app.name_key(lr.family_name)
                        and app.given_key(s.given_name) = app.given_key(lr.given_name))
     and not exists (select 1 from jsonb_array_elements(v_renum) x where x ->> 'to' = lr.membership_number);

  return jsonb_build_object('go', p_go, 'count', v_made, 'kept', v_kept, 'new', v_new,
                            'first', v_plan, 'left_out', v_left, 'renumbered', v_renum,
                            'not_in_dynamics', v_absent,
                            'register', (select count(*) from public.legacy_register),
                            'allowed', coalesce(app.setting('dynamics_member_load'), 'off') = 'on');
end;
$$;
revoke all on function public.dynamics_members_load(boolean) from public, anon;
grant execute on function public.dynamics_members_load(boolean) to authenticated;
