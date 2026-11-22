-- =============================================================================
-- 0062  Members see and ask to change their emails, choose which AMI uses,
--       and the office sees every change a member makes to their own record
--
-- Steve, 1 November 2026: show both emails on the member's own details, let the
-- member change them and pick the one AMI writes to, and give the admin app a
-- record of every edit members make to their records.
--
-- THE EMAILS STAY DYNAMICS'. Steve chose "request, office applies": a member
-- asks for a change; the request waits for the office, who changes the contact
-- in ARCA's Dynamics; the next sync brings the new addresses in, and the
-- request closes itself the moment the website's addresses match what was
-- asked for. Dynamics remains the one source, and the sync never has to fight
-- a member's edit.
--
--   email_change_requests     one row per request: what was asked for, what
--                             was held at the time, and what became of it
--                             (pending, done, declined, withdrawn, superseded)
--   request_my_email_change   the member asks; any earlier pending request is
--                             superseded; at most five a day
--   withdraw_my_email_change  the member takes a pending request back
--   set_my_preferred_email    the member picks work or private (0061), which
--                             the website owns, so it changes at once
--   email_change_decide       membership staff: decline with a reason, or,
--                             for somebody not linked to Dynamics, apply it
--                             here. A linked person's request is applied in
--                             Dynamics and closes itself on the next sync.
--
-- THE RECORD OF CHANGES. people and member_preferences were never audited;
-- they are now, with the same app.audit_row as every other audited table, and
-- so is email_change_requests. admin_member_changes lists, newest first, every
-- change a member made to their own record (the actor is the person whose row
-- it is), field by field, before and after, leaving out timestamps and the
-- unsubscribe token. Changes the office or the sync made are in the audit log
-- too but are not "edits members make", so they are not on this list.
-- admin_email_change_requests is the office's queue.
--
-- Both admin views carry the 0057 staff gate, narrowed to membership staff,
-- because they show members' addresses.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Requests
-- -----------------------------------------------------------------------------
create table if not exists public.email_change_requests (
  id             uuid primary key default gen_random_uuid(),
  person_id      uuid not null references public.people(id) on delete cascade,
  work_email     text,
  private_email  text,
  old_work       text,
  old_private    text,
  status         text not null default 'pending'
                 check (status in ('pending', 'done', 'declined', 'withdrawn', 'superseded')),
  requested_at   timestamptz not null default now(),
  decided_at     timestamptz,
  decided_by     uuid references public.people(id),
  note           text
);
-- A running number, because requested_at is the transaction's time and two
-- requests in one transaction would otherwise tie for "the latest".
alter table public.email_change_requests add column if not exists seq bigint generated always as identity;
create index if not exists email_change_requests_person on public.email_change_requests (person_id, seq desc);
create unique index if not exists email_change_requests_one_pending
  on public.email_change_requests (person_id) where status = 'pending';

alter table public.email_change_requests enable row level security;
revoke all on public.email_change_requests from anon, authenticated;
grant select on public.email_change_requests to authenticated;

drop policy if exists email_change_requests_own on public.email_change_requests;
create policy email_change_requests_own on public.email_change_requests
  for select to authenticated using (person_id = (select app.person_id()));
drop policy if exists email_change_requests_staff on public.email_change_requests;
create policy email_change_requests_staff on public.email_change_requests
  for select to authenticated using ((select app.is_membership_staff()));

comment on table public.email_change_requests is
  'A member asking for their work or private email to change. Applied by the office in Dynamics; '
  'closes itself when the sync brings the addresses in (0062).';

-- An address, tidied, or null. Refuses anything that is not plainly one.
create or replace function app.clean_email(p text) returns text
language plpgsql immutable set search_path = ''
as $$
declare v text := lower(btrim(coalesce(p, '')));
begin
  if v = '' then return null; end if;
  if length(v) > 254 or v !~ '^[^@\s<>,;"]+@[^@\s<>,;"]+\.[^@\s<>,;"]+$' then
    raise exception '"%" does not look like an email address.', btrim(p) using errcode = '22023';
  end if;
  return v;
end;
$$;

create or replace function public.request_my_email_change(p_work text, p_private text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_pid  uuid := app.person_id();
  v_w    text := app.clean_email(p_work);
  v_p    text := app.clean_email(p_private);
  pe     public.people;
  v_id   uuid;
begin
  if v_pid is null or not exists (select 1 from public.members where person_id = v_pid) then
    raise exception 'Only a member can ask to change their emails.' using errcode = '42501';
  end if;
  select * into pe from public.people where id = v_pid;
  if v_w is null and v_p is null then
    raise exception 'Give at least one email address.' using errcode = '22023';
  end if;
  if v_w = v_p then
    raise exception 'The work and private emails are the same. Leave the private one empty instead.' using errcode = '22023';
  end if;
  if v_w is not distinct from lower(btrim(pe.email)) and v_p is not distinct from nullif(lower(btrim(coalesce(pe.alt_email, ''))), '') then
    raise exception 'Those are the emails AMI already holds.' using errcode = '22023';
  end if;
  if (select count(*) from public.email_change_requests
       where person_id = v_pid and requested_at > now() - interval '1 day') >= 5 then
    raise exception 'That is five requests today. Please try again tomorrow, or contact the office.' using errcode = '54000';
  end if;

  update public.email_change_requests set status = 'superseded', decided_at = now()
   where person_id = v_pid and status = 'pending';

  insert into public.email_change_requests (person_id, work_email, private_email, old_work, old_private)
  values (v_pid, v_w, v_p, pe.email, pe.alt_email)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'status', 'pending', 'work_email', v_w, 'private_email', v_p);
end;
$$;
revoke all on function public.request_my_email_change(text, text) from public;
grant execute on function public.request_my_email_change(text, text) to authenticated;

create or replace function public.withdraw_my_email_change() returns boolean
language plpgsql volatile security definer set search_path = ''
as $$
begin
  update public.email_change_requests set status = 'withdrawn', decided_at = now()
   where person_id = app.person_id() and status = 'pending';
  return found;
end;
$$;
revoke all on function public.withdraw_my_email_change() from public;
grant execute on function public.withdraw_my_email_change() to authenticated;

create or replace function public.set_my_preferred_email(p_choice text) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_pid uuid := app.person_id();
  v     text := lower(btrim(coalesce(p_choice, '')));
begin
  if v_pid is null or not exists (select 1 from public.members where person_id = v_pid) then
    raise exception 'Only a member can choose this.' using errcode = '42501';
  end if;
  if v not in ('work', 'private') then
    raise exception 'Choose work or private.' using errcode = '22023';
  end if;
  if v = 'private' and not exists (select 1 from public.people
       where id = v_pid and nullif(btrim(coalesce(alt_email, '')), '') is not null) then
    raise exception 'AMI holds no private email for you yet. Ask for one to be added first.' using errcode = '22023';
  end if;
  update public.people set preferred_email = v where id = v_pid and preferred_email is distinct from v;
  return app.contact_email(v_pid);
end;
$$;
revoke all on function public.set_my_preferred_email(text) from public;
grant execute on function public.set_my_preferred_email(text) to authenticated;

create or replace function public.email_change_decide(p_id uuid, p_action text, p_note text default null)
returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  r      public.email_change_requests;
  pe     public.people;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not app.is_membership_staff() then
    raise exception 'Deciding email changes is for membership staff.' using errcode = '42501';
  end if;
  select * into r from public.email_change_requests where id = p_id for update;
  if not found or r.status <> 'pending' then
    raise exception 'That request is not waiting any more.' using errcode = '22023';
  end if;
  select * into pe from public.people where id = r.person_id;

  if p_action = 'decline' then
    if v_note is null then
      raise exception 'Say why, because the member reads it.' using errcode = '22023';
    end if;
    update public.email_change_requests
       set status = 'declined', decided_at = now(), decided_by = app.person_id(), note = v_note
     where id = r.id;
    return 'declined';
  elsif p_action = 'apply' then
    if pe.dynamics_contact_id is not null then
      raise exception 'This member''s emails come from Dynamics. Change them there (Email and Email Address 2); the request closes itself on the next sync.'
        using errcode = '22023';
    end if;
    if exists (select 1 from public.people o
                where o.id <> r.person_id
                  and (lower(o.email) in (r.work_email, r.private_email)
                       or lower(o.alt_email) in (r.work_email, r.private_email))) then
      raise exception 'One of those addresses is on somebody else''s record, and an address can belong to one person only. Sort that out first, or decline the request.'
        using errcode = '23505';
    end if;
    update public.people
       set email = coalesce(r.work_email, email), alt_email = r.private_email,
           preferred_email = case when r.private_email is null then 'work' else preferred_email end
     where id = r.person_id;
    update public.email_change_requests
       set status = 'done', decided_at = now(), decided_by = app.person_id(), note = coalesce(v_note, note)
     where id = r.id;
    return 'done';
  else
    raise exception 'Apply or decline.' using errcode = '22023';
  end if;
end;
$$;
revoke all on function public.email_change_decide(uuid, text, text) from public;
grant execute on function public.email_change_decide(uuid, text, text) to authenticated;

-- When the addresses arrive (from the sync, or the office), the request closes.
create or replace function app.email_request_arrived() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.email_change_requests q
     set status = 'done', decided_at = now(),
         note = coalesce(q.note, 'The new emails arrived from ARCA''s records.')
   where q.person_id = new.id and q.status = 'pending'
     and (q.work_email is null or lower(btrim(coalesce(new.email, ''))) = q.work_email)
     and coalesce(lower(btrim(new.alt_email)), '') = coalesce(q.private_email, '');
  return new;
end;
$$;
drop trigger if exists people_email_request_arrived on public.people;
create trigger people_email_request_arrived
  after update of email, alt_email on public.people
  for each row execute function app.email_request_arrived();

-- -----------------------------------------------------------------------------
-- 2. Audit what was never audited
-- -----------------------------------------------------------------------------
drop trigger if exists audit_people on public.people;
create trigger audit_people
  after insert or update or delete on public.people
  for each row execute function app.audit_row();
drop trigger if exists audit_member_preferences on public.member_preferences;
create trigger audit_member_preferences
  after insert or update or delete on public.member_preferences
  for each row execute function app.audit_row();
drop trigger if exists audit_email_change_requests on public.email_change_requests;
create trigger audit_email_change_requests
  after insert or update or delete on public.email_change_requests
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- 3. The member's own view
-- -----------------------------------------------------------------------------
create or replace view public.my_profile
with (security_invoker = true) as
select
  m.id                        as member_id,
  p.id                        as person_id,
  m.membership_number,
  p.given_name,
  p.family_name,
  p.post_nominals,
  p.email,
  p.mobile,
  p.home_address,
  p.business_address,
  p.photo_path,
  p.photo_strip_path,
  p.photo_consent,
  g.name                      as grade,
  g.post_nominals             as grade_post_nominals,
  g.is_assessed,
  g.requires_cpd,
  o.name                      as employer,
  m.current_job_title,
  m.joined_on,
  m.is_active,
  m.status,
  pr.list_on_register,
  pr.public_profile,
  pr.photo_on_public_page,
  pr.forum_notifications,
  pr.email_newsletter,
  pr.email_events,
  s.slug,
  coalesce(r.core_required, 5)     as cpd_required_core,
  coalesce(r.non_core_required, 5) as cpd_required_non_core,
  (select max(y.year) from public.membership_years y where y.member_id = m.id) as last_year_recorded,
  (select w.issued_at from public.wallet_passes w
    where w.member_id = m.id and w.revoked_at is null
    order by w.issued_at desc limit 1) as card_issued_at,
  -- New at the end, and only at the end.
  pr.cpd_reminders,
  pr.cpd_receipts,
  pr.unsubscribe_token,
  -- 0062: both emails, which AMI writes to, and any change the member asked for
  p.alt_email,
  p.preferred_email,
  app.contact_email(p.id)          as contact_email,
  er.status                        as email_request_status,
  er.work_email                    as email_request_work,
  er.private_email                 as email_request_private,
  er.requested_at                  as email_request_at,
  er.note                          as email_request_note
from public.members m
join public.people p              on p.id = m.person_id
join public.membership_grades g   on g.id = m.grade_id
join public.member_preferences pr on pr.member_id = m.id
left join public.organisations o   on o.id = m.employer_id
left join public.register_slugs s  on s.member_id = m.id and s.retired_at is null
left join public.cpd_requirements r
       on r.grade_id = m.grade_id
      and r.year = extract(year from current_date)::int
left join lateral (
  select q.status, q.work_email, q.private_email, q.requested_at, q.note
    from public.email_change_requests q
   where q.person_id = p.id
     and (q.status = 'pending' or q.decided_at > now() - interval '30 days')
     and q.status <> 'superseded'
   order by q.seq desc
   limit 1) er on true;

grant select on public.my_profile to authenticated;

-- -----------------------------------------------------------------------------
-- 4. The office's views
-- -----------------------------------------------------------------------------
create or replace view public.admin_email_change_requests
with (security_invoker = true) as
select q.* from (
  select r.id, r.status, r.requested_at, r.decided_at, r.note,
         r.work_email, r.private_email, r.old_work, r.old_private,
         p.id as person_id, p.given_name, p.family_name,
         p.email as current_work, p.alt_email as current_private,
         p.dynamics_contact_id is not null as in_dynamics,
         (select string_agg(m.membership_number, ', ') from public.members m where m.person_id = p.id) as membership_number,
         exists (select 1 from public.people o
                  where o.id <> p.id
                    and (lower(o.email) in (r.work_email, r.private_email)
                         or lower(o.alt_email) in (r.work_email, r.private_email))) as address_on_another_record
    from public.email_change_requests r
    join public.people p on p.id = r.person_id
) q, lateral (select app.is_membership_staff() as staff_gate) g
where g.staff_gate;
grant select on public.admin_email_change_requests to authenticated;

create or replace view public.admin_member_changes
with (security_invoker = true) as
select q.* from (
  select a.id, a.occurred_at, a.action,
         case a.table_name when 'people' then 'Details'
                           when 'member_preferences' then 'Switches'
                           when 'email_change_requests' then 'Email request'
                           else a.table_name end as area,
         p.id as person_id, p.given_name, p.family_name,
         (select string_agg(m.membership_number, ', ') from public.members m where m.person_id = p.id) as membership_number,
         (select jsonb_object_agg(k.key, jsonb_build_object('before', a.before -> k.key, 'after', a.after -> k.key))
            from jsonb_object_keys(coalesce(a.after, a.before)) k(key)
           where k.key not in ('id', 'updated_at', 'created_at', 'unsubscribe_token', 'person_id', 'member_id',
                               'requested_at', 'old_work', 'old_private', 'seq')
             and (a.before -> k.key) is distinct from (a.after -> k.key)) as changes
    from public.audit_log a
    join public.people p on p.id = a.actor_id
   where a.table_name in ('people', 'member_preferences', 'email_change_requests')
     and (   (a.table_name = 'people' and a.row_id = p.id::text)
          or (a.table_name = 'member_preferences' and exists (select 1 from public.members m
                where m.person_id = p.id and m.id::text = coalesce(a.after, a.before) ->> 'member_id'))
          or (a.table_name = 'email_change_requests' and coalesce(a.after, a.before) ->> 'person_id' = p.id::text))
) q, lateral (select app.is_membership_staff() as staff_gate) g
where g.staff_gate and q.changes is not null;
grant select on public.admin_member_changes to authenticated;

comment on view public.admin_member_changes is
  'Every change a member made to their own record: details, switches and email requests, field by field. '
  'Membership staff only (0062).';
