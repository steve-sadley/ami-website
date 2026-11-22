-- =============================================================================
-- 0061  A work email, a private email, and which one AMI writes to
--
-- Steve, 1 November 2026: "on the member details can we have one email as work
-- email and one email as private email and some way of selecting which is the
-- primary email to use for communications".
--
-- The two addresses already exist and come from ARCA's Dynamics (0049, 0054):
--   people.email      Dynamics "Email"            shown as the WORK email
--   people.alt_email  Dynamics "Email Address 2"  shown as the PRIVATE email
-- Dynamics still owns both, so they are still changed in Dynamics.
--
-- What is new is people.preferred_email, 'work' or 'private', which the
-- website owns. 'work' by default, so nothing changes for anybody until the
-- office chooses otherwise. app.contact_email(person) answers which address to
-- use: the private one when it is chosen AND there is one, otherwise the work
-- one, otherwise whatever there is.
--
-- ONE PLACE DECIDES. Every email the database queues for a person goes through
-- app.queue_message: decision letters, CPD receipts and notices, the monthly
-- CPD email, bulletins and the daily digest. So the choice is applied there,
-- once, rather than in each of the six callers, where one would be missed.
-- The rule: when a message names a person AND is addressed to one of that
-- person's own addresses, it goes to their chosen address instead. A message
-- to some other address (a test bulletin to whatever the office typed) is left
-- exactly as it was. The suppression list is checked on the address it will
-- actually go to.
--
-- On staging, the bulletin, the digest and the monthly CPD email only reach
-- the addresses in bulletin_allow, checked by each before it queues. So for
-- those three, a switch to the chosen address happens only if that address is
-- on the list too; otherwise the message stays on the allowed one. Staging can
-- never be made to write to a member it was told not to.
--
-- The emails the site sends directly from a form (the contact form, the
-- application acknowledgement) go to the address typed into the form, as now.
-- Signing in is not affected: the address a member signs in with is their
-- account's, and is a separate question already on the handover's list.
--
-- update_member_details (0060) gains p_preferred_email, so the office sets it
-- in Edit details. It is DROPPED and recreated rather than overloaded: a second
-- version nobody calls is how 0027 once lost an email hook.
--
-- Safe to run twice.
-- =============================================================================

alter table public.people
  add column if not exists preferred_email text not null default 'work';

do $$
begin
  alter table public.people add constraint people_preferred_email_check
    check (preferred_email in ('work', 'private'));
exception when duplicate_object then null;
end $$;

comment on column public.people.preferred_email is
  'Which address AMI writes to: work (Dynamics Email, people.email) or private '
  '(Dynamics Email Address 2, people.alt_email). Owned by the website (0061).';

-- -----------------------------------------------------------------------------
-- Which address to use
-- -----------------------------------------------------------------------------
create or replace function app.contact_email(p_person uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select lower(btrim(case
           when p.preferred_email = 'private' and nullif(btrim(coalesce(p.alt_email, '')), '') is not null
             then p.alt_email
           else coalesce(nullif(btrim(coalesce(p.email, '')), ''), p.alt_email)
         end))
    from public.people p
   where p.id = p_person;
$$;
revoke all on function app.contact_email(uuid) from public;
-- The staff only members list calls it as the caller, so signed in users need
-- execute. The app schema is not reachable from a browser, and the list is gated.
grant execute on function app.contact_email(uuid) to authenticated, service_role;

comment on function app.contact_email(uuid) is
  'The address AMI writes to for this person: the private one when chosen and '
  'held, otherwise the work one (0061).';

-- -----------------------------------------------------------------------------
-- The one place every queued email passes through
-- -----------------------------------------------------------------------------
create or replace function app.queue_message(
  p_code      text,
  p_subject   text,
  p_html      text,
  p_to_email  text,
  p_to_name   text,
  p_person_id uuid default null,
  p_reply_to  text default null,
  p_context   jsonb default '{}'::jsonb
) returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_id     uuid;
  v_status text := 'queued';
  v_to     text := lower(btrim(coalesce(p_to_email, '')));
  v_chosen text;
begin
  if v_to = '' then
    raise exception 'An email needs somewhere to go.';
  end if;

  -- 0061: to the person's chosen address, when it is addressed to one of theirs.
  if p_person_id is not null then
    select app.contact_email(p.id) into v_chosen
      from public.people p
     where p.id = p_person_id
       and v_to in (lower(btrim(coalesce(p.email, ''))), lower(btrim(coalesce(p.alt_email, ''))));
    if v_chosen is not null and v_chosen <> '' and v_chosen <> v_to then
      if p_code in ('bulletin', 'content_digest', 'cpd_monthly')
         and coalesce(app.setting('environment'), '') <> 'live'
         and not (v_chosen = any (array(
               select lower(btrim(x)) from unnest(string_to_array(coalesce(app.setting('bulletin_allow'), ''), ',')) x))) then
        null;   -- staging: stay on the address that was allowed
      else
        v_to := v_chosen;
      end if;
    end if;
  end if;

  if exists (select 1 from public.suppression_list where lower(email) = v_to) then
    v_status := 'suppressed';
  end if;

  insert into public.email_outbox
    (template_code, to_email, to_name, subject, html, reply_to,
     person_id, context, status, from_email)
  values
    (p_code, v_to, p_to_name, p_subject, p_html, p_reply_to,
     p_person_id, coalesce(p_context, '{}'::jsonb), v_status,
     app.from_address_for(p_code))
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function app.queue_message(text, text, text, text, text, uuid, text, jsonb)
  from public;

-- The monthly CPD preview says where it would really go.
create or replace function public.cpd_monthly_preview(p_member uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  pp record;
begin
  if not app.is_membership_staff() then
    raise exception 'Previewing the monthly CPD email is for membership staff.' using errcode = '42501';
  end if;
  select * into pp from app.cpd_monthly_parts(p_member, current_date);
  if pp.subject is null then
    raise exception 'There is no such member.' using errcode = '22023';
  end if;
  return jsonb_build_object('subject', pp.subject, 'html', pp.html,
    'to', coalesce(app.contact_email(pp.person_id), pp.to_email),
    'missed', pp.missed, 'to_earn', pp.to_earn,
    'next', app.first_working_day((date_trunc('month', current_date) + interval '1 month')::date));
end;
$$;
revoke all on function public.cpd_monthly_preview(uuid) from public;
grant execute on function public.cpd_monthly_preview(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Edit details sets it
-- -----------------------------------------------------------------------------
drop function if exists public.update_member_details(uuid, text, date, text, text);

create or replace function public.update_member_details(
  p_member_id         uuid,
  p_membership_number text,
  p_joined_on         date,
  p_current_job_title text default null,
  p_employer          text default null,
  p_preferred_email   text default null
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  m        public.members;
  v_family text;
  v_alt    text;
  v_num    text := upper(btrim(coalesce(p_membership_number, '')));
  v_title  text := nullif(btrim(coalesce(p_current_job_title, '')), '');
  v_emp    text := nullif(btrim(regexp_replace(coalesce(p_employer, ''), '\s+', ' ', 'g')), '');
  v_pref   text := nullif(lower(btrim(coalesce(p_preferred_email, ''))), '');
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
  select family_name, nullif(btrim(coalesce(alt_email, '')), '') into v_family, v_alt
    from public.people where id = m.person_id;

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

  -- which email (0061); null leaves it as it is
  if v_pref is not null and v_pref not in ('work', 'private') then
    raise exception 'The email to use is work or private.' using errcode = '22023';
  end if;
  if v_pref = 'private' and v_alt is null then
    raise exception 'There is no private email for this member. Add it in Dynamics as Email Address 2 first.'
      using errcode = '22023';
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

  if v_pref is not null then
    update public.people set preferred_email = v_pref
     where id = m.person_id and preferred_email is distinct from v_pref;
  end if;

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
    'employer',          v_emp,
    'contact_email',     app.contact_email(m.person_id));
end;
$$;

revoke all on function public.update_member_details(uuid, text, date, text, text, text) from public;
grant execute on function public.update_member_details(uuid, text, date, text, text, text) to authenticated, service_role;

comment on function public.update_member_details(uuid, text, date, text, text, text) is
  'The things only the website holds about a member: number, joining date, job title, employer, '
  'and which of their two emails AMI writes to. Membership staff only (0060, 0061).';

-- -----------------------------------------------------------------------------
-- The members list shows the choice, still staff only
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
         p.alt_email,
         p.preferred_email,
         app.contact_email(p.id) as contact_email
    from public.members m
    join public.people p on p.id = m.person_id
    join public.membership_grades g on g.id = m.grade_id
    left join public.organisations o on o.id = m.employer_id
) q, lateral (select app.is_staff() as staff_gate) g
where g.staff_gate;
