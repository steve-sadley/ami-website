-- =============================================================================
-- 0064  Booking the professional interview
--
-- Steve, 3 November 2026. Applicants book the professional interview that is
-- part of joining. Until now that was a Doodle poll linked to his Outlook
-- calendar. It moves onto the site:
--
--   1. The office puts up interview times on the Interview slots screen. Each
--      is 75 minutes unless it says otherwise.
--   2. The office presses Invite to interview on an application. The applicant
--      is emailed a private link. Only somebody holding that link can see the
--      times, and the link books for that one application.
--   3. The applicant chooses a time. The site checks Steve's Outlook calendar
--      at that moment (the Worker does that, not the database), puts the
--      interview in it as a Teams meeting with the applicant invited, and both
--      sides are emailed.
--   4. Any slot that clashes with something else in the Outlook calendar is not
--      offered. That check is also the Worker's, because only the Worker holds
--      the Microsoft key. The database decides everything else.
--
-- What decides what, so it is set down once:
--
--   The DATABASE decides who may book (the link, the application still open),
--   which slots exist, that a slot is held by one applicant at a time, the
--   notice period, and every email.
--   The WORKER decides whether Outlook is free, and writes and cancels the
--   Outlook event. It is the only thing that calls the service role functions
--   here, and it never decides a booking on its own.
--
-- The link is a token of 32 random bytes. Only its SHA-256 is stored, exactly
-- as the wallet pass does (0026), so a copy of the database is not a way in.
-- The page reads it from the part of the address after #, which a browser never
-- sends to a server, so it does not land in anybody's logs either.
--
-- Holding a slot. Between the database saying "yes, that slot is yours" and
-- Outlook confirming, the booking is HOLDING. A unique index lets only one
-- holding or booked row exist per slot, so two applicants pressing at the same
-- second cannot both have it. A hold that is never confirmed (the Worker died,
-- Microsoft did not answer) lapses after five minutes, so a slot cannot be lost
-- for good to a failure halfway through.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The times the office offers
-- -----------------------------------------------------------------------------
create table if not exists public.interview_slots (
  id          uuid primary key default gen_random_uuid(),
  starts_at   timestamptz not null,
  minutes     integer not null default 75 check (minutes between 15 and 240),
  -- Filled in by the trigger below from starts_at and minutes. Held as a column
  -- so the overlap rule can be a constraint: timestamptz plus an interval is not
  -- immutable, so it cannot go into an index expression directly.
  ends_at     timestamptz not null,
  note        text,
  withdrawn   boolean not null default false,
  created_by  uuid references public.people(id) default app.person_id(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create or replace function app.interview_slot_rules() returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.ends_at := new.starts_at + make_interval(mins => new.minutes);

  if tg_op = 'UPDATE' and exists (
       select 1 from public.interview_bookings b
        where b.slot_id = old.id and b.status in ('holding', 'booked'))
     and (new.starts_at is distinct from old.starts_at
          or new.minutes is distinct from old.minutes
          or (new.withdrawn and not old.withdrawn)) then
    raise exception 'Somebody is booked into this slot. Cancel their interview first, '
                    'then change or withdraw the slot.' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function app.interview_slot_delete_rule() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if exists (select 1 from public.interview_bookings b where b.slot_id = old.id) then
    raise exception 'This slot has a booking on its record, so it is withdrawn rather than '
                    'deleted. Tick Withdrawn instead.' using errcode = '23514';
  end if;
  return old;
end;
$$;

-- Two slots that overlap would let Steve be booked twice at once.
do $$
begin
  alter table public.interview_slots
    add constraint interview_slots_no_overlap
    exclude using gist (tstzrange(starts_at, ends_at) with &&) where (not withdrawn);
exception when duplicate_object or duplicate_table then null;
end $$;

create index if not exists interview_slots_when on public.interview_slots (starts_at);

comment on table public.interview_slots is
  'Interview times the office offers applicants (0064). A slot that clashes with '
  'something in the interviewer''s Outlook calendar is still here, and is simply '
  'not offered; the Worker checks Outlook every time the page is opened.';


-- -----------------------------------------------------------------------------
-- 2. The invitation: one private link per application
-- -----------------------------------------------------------------------------
create table if not exists public.interview_invitations (
  application_id uuid primary key references public.membership_applications(id) on delete cascade,
  token_hash     text not null unique,
  invited_at     timestamptz not null default now(),
  invited_by     uuid references public.people(id),
  expires_at     timestamptz not null
);

comment on table public.interview_invitations is
  'The private booking link sent to an applicant (0064). Only the SHA-256 of the '
  'token is held. Sending the invitation again issues a new link and the old one '
  'stops working.';


-- -----------------------------------------------------------------------------
-- 3. The bookings
-- -----------------------------------------------------------------------------
create table if not exists public.interview_bookings (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.membership_applications(id) on delete cascade,
  slot_id        uuid not null references public.interview_slots(id),
  status         text not null default 'holding' check (status in (
                   'holding',    -- the database said yes, Outlook not yet written
                   'booked',     -- in the calendar, both sides emailed
                   'changed',    -- replaced by a later booking for the same application
                   'cancelled',  -- by the applicant or the office
                   'expired',    -- a hold that was never confirmed
                   'failed')),   -- Outlook refused, so the hold was let go
  event_id       text,
  join_url       text,
  held_at        timestamptz not null default now(),
  booked_at      timestamptz,
  ended_at       timestamptz,
  ended_by       text check (ended_by in ('applicant', 'office', 'system')),
  reason         text
);

-- One live booking per slot and one per application. These two indexes are
-- what make a race harmless: the second insert fails rather than both landing.
create unique index if not exists interview_bookings_one_per_slot
  on public.interview_bookings (slot_id) where status in ('holding', 'booked');
create unique index if not exists interview_bookings_one_hold_per_application
  on public.interview_bookings (application_id) where status = 'holding';
create unique index if not exists interview_bookings_one_booked_per_application
  on public.interview_bookings (application_id) where status = 'booked';

drop trigger if exists interview_slot_rules on public.interview_slots;
create trigger interview_slot_rules before insert or update on public.interview_slots
  for each row execute function app.interview_slot_rules();
drop trigger if exists interview_slot_delete_rule on public.interview_slots;
create trigger interview_slot_delete_rule before delete on public.interview_slots
  for each row execute function app.interview_slot_delete_rule();
drop trigger if exists interview_slots_updated on public.interview_slots;
create trigger interview_slots_updated before update on public.interview_slots
  for each row execute function app.set_updated_at();


-- -----------------------------------------------------------------------------
-- 4. Who may touch what
-- -----------------------------------------------------------------------------
-- Slots: membership staff write them on their screen. Nobody else reads them;
-- applicants see times only through the Worker, which asks with the link.
alter table public.interview_slots enable row level security;
revoke all on public.interview_slots from anon, authenticated;
grant select, insert, update, delete on public.interview_slots to authenticated;
drop policy if exists interview_slots_staff on public.interview_slots;
create policy interview_slots_staff on public.interview_slots
  for all to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

-- Invitations and bookings: read only for staff. Every change is a function
-- that decides as well as writes.
alter table public.interview_invitations enable row level security;
revoke all on public.interview_invitations from anon, authenticated;
grant select on public.interview_invitations to authenticated;
drop policy if exists interview_invitations_staff on public.interview_invitations;
create policy interview_invitations_staff on public.interview_invitations
  for select to authenticated using ((select app.is_membership_staff()));

alter table public.interview_bookings enable row level security;
revoke all on public.interview_bookings from anon, authenticated;
grant select on public.interview_bookings to authenticated;
drop policy if exists interview_bookings_staff on public.interview_bookings;
create policy interview_bookings_staff on public.interview_bookings
  for select to authenticated using ((select app.is_membership_staff()));


-- -----------------------------------------------------------------------------
-- 5. Settings
-- -----------------------------------------------------------------------------
insert into public.system_settings (key, value, note) values
  ('interview_notice_hours', '24',
   'How many hours ahead an applicant must book, change or cancel an interview. '
   'Inside this they are asked to email instead.'),
  ('interview_days_ahead', '90',
   'How far ahead the booking page offers interview times.'),
  ('interview_notify', 'steve.sadley@arca.org.uk',
   'Who is emailed when an interview is booked, changed or cancelled. Comma '
   'separated for more than one. The interview also goes into the Outlook '
   'calendar named by the site''s MS_CALENDAR setting.')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- 6. The emails
-- -----------------------------------------------------------------------------
-- Service letters: about somebody's own application, so an editor may not
-- reword them (0027) and no preference switches them off.
insert into public.email_templates (code, name, subject, html, is_service) values
(
  'interview_invite',
  'Interview: invitation to book',
  'Book your AMI professional interview',
  '<p>Dear {{given_name}},</p>
   <p>Thank you for your application to the Asbestos Management Institute,
      reference <b>{{reference}}</b>. The next step is a professional interview,
      held online by Microsoft Teams and lasting about {{minutes_text}}.</p>
   <p>Please choose a time that suits you:</p>
   <p><a href="{{link}}">Book your interview</a></p>
   <p>The link is personal to your application, so please do not pass it on. You
      can use it again to change or cancel your interview up to {{notice_hours}}
      hours beforehand. It works until {{expires}}.</p>
   <p>If none of the times suit you, reply to this email and we will find
      another.</p>',
  true
),
(
  'interview_booked',
  'Interview: booked, to the applicant',
  'Your AMI interview: {{when}}',
  '<p>Dear {{given_name}},</p>
   <p>Your professional interview is booked for <b>{{when}}</b>, for {{minutes_text}}.</p>
   <p>{{replaces}}</p>
   <p>It is held on Microsoft Teams. You will also receive a calendar invitation
      with the joining link, so it goes straight into your diary.</p>
   <p><a href="{{join_url}}">Join the interview on Teams</a></p>
   <p>To change or cancel it, use the link in your invitation email up to
      {{notice_hours}} hours beforehand. After that, please reply to this email.</p>',
  true
),
(
  'interview_booked_office',
  'Interview: booked, to the office',
  'Interview booked: {{applicant}}, {{when}}',
  '<p>{{applicant}} has booked their professional interview for <b>{{when}}</b>,
      {{minutes_text}}.</p>
   <p>Application <b>{{reference}}</b>, applying for {{grade}}.<br>
      Email: {{email}}</p>
   <p>{{replaces}}</p>
   <p>It is in the Outlook calendar as a Teams meeting with the applicant invited.</p>
   <p><a href="{{join_url}}">Join on Teams</a></p>',
  true
),
(
  'interview_cancelled',
  'Interview: cancelled, to the applicant',
  'Your AMI interview has been cancelled',
  '<p>Dear {{given_name}},</p>
   <p>Your professional interview on <b>{{when}}</b> has been cancelled.</p>
   <p>{{reason}}</p>
   <p>{{rebook}}</p>',
  true
),
(
  'interview_cancelled_office',
  'Interview: cancelled, to the office',
  'Interview cancelled: {{applicant}}, {{when}}',
  '<p>The professional interview for {{applicant}} on <b>{{when}}</b> has been
      cancelled {{by_whom}}.</p>
   <p>Application <b>{{reference}}</b>. The slot is open again for somebody else.</p>
   <p>{{reason}}</p>',
  true
)
on conflict (code) do nothing;


-- -----------------------------------------------------------------------------
-- 7. Helpers
-- -----------------------------------------------------------------------------
-- An interview time as people say it, in London time whatever the server's.
create or replace function app.interview_when(p_at timestamptz) returns text
language sql stable set search_path = ''
as $$
  select trim(to_char(p_at at time zone 'Europe/London', 'FMDay FMDD FMMonth YYYY'))
         || ' at ' || to_char(p_at at time zone 'Europe/London', 'HH24:MI');
$$;

create or replace function app.minutes_text(p_minutes integer) returns text
language sql immutable set search_path = ''
as $$
  select case
    when p_minutes % 60 = 0 and p_minutes = 60 then '1 hour'
    when p_minutes % 60 = 0 then (p_minutes / 60) || ' hours'
    when p_minutes > 60 then (p_minutes / 60) || ' hour' || case when p_minutes >= 120 then 's' else '' end
                              || ' ' || (p_minutes % 60) || ' minutes'
    else p_minutes || ' minutes' end;
$$;

create or replace function app.interview_notice() returns interval
language sql stable set search_path = ''
as $$
  select make_interval(hours => coalesce(nullif(app.setting('interview_notice_hours'), '')::int, 24));
$$;

-- The application a link belongs to, or a refusal in words. Every applicant
-- facing function starts here, so the rule about whose link it is has one home.
create or replace function app.interview_application(p_token text)
returns public.membership_applications
language plpgsql stable security definer set search_path = ''
as $$
declare
  a public.membership_applications;
  i public.interview_invitations;
begin
  if coalesce(p_token, '') !~ '^[A-Za-z0-9_-]{40,64}$' then
    raise exception 'This booking link is not complete. Please open it again from your email.'
      using errcode = '22023';
  end if;
  select * into i from public.interview_invitations
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then
    raise exception 'This booking link is not recognised. If you were sent a newer one, '
                    'please use that.' using errcode = 'P0002';
  end if;
  if i.expires_at < now() then
    raise exception 'This booking link has expired. Please reply to your invitation email '
                    'and we will send another.' using errcode = 'P0002';
  end if;
  select * into a from public.membership_applications where id = i.application_id;
  if a.status not in ('submitted', 'under_review') then
    raise exception 'Your application has been decided, so there is no interview to book.'
      using errcode = 'P0002';
  end if;
  return a;
end;
$$;
revoke all on function app.interview_application(text) from public;

-- Holds older than five minutes were never confirmed. Let them go.
create or replace function app.interview_expire_holds() returns void
language sql volatile security definer set search_path = ''
as $$
  update public.interview_bookings
     set status = 'expired', ended_at = now(), ended_by = 'system',
         reason = 'Never confirmed in Outlook'
   where status = 'holding' and held_at < now() - interval '5 minutes';
$$;
revoke all on function app.interview_expire_holds() from public;

-- Who the office notices go to.
create or replace function app.interview_notify_list() returns text[]
language sql stable set search_path = ''
as $$
  select coalesce(array_agg(x), '{}') from (
    select lower(btrim(x)) as x
      from unnest(string_to_array(app.setting('interview_notify'), ',')) x
     where btrim(x) <> '') s;
$$;


-- -----------------------------------------------------------------------------
-- 8. The office invites
-- -----------------------------------------------------------------------------
-- Returns the link as well as emailing it, so the admin app can show it for
-- the office to copy into a reply if the email goes astray. The office can
-- already resend it, so seeing it gives them nothing new.
create or replace function public.interview_invite(p_application_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a        public.membership_applications;
  v_token  text;
  v_link   text;
  v_exp    timestamptz := now() + interval '60 days';
  v_mins   integer;
  r        record;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may invite an applicant to interview.' using errcode = '42501';
  end if;
  select * into a from public.membership_applications where id = p_application_id for update;
  if not found then
    raise exception 'There is no such application.' using errcode = 'P0002';
  end if;
  if a.status not in ('submitted', 'under_review') then
    raise exception 'Application % is %, so there is no interview to book.', a.reference, a.status
      using errcode = '22023';
  end if;

  -- 32 random bytes, written so they can travel in an address untouched.
  v_token := translate(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), '+/', '-_');
  insert into public.interview_invitations (application_id, token_hash, invited_by, expires_at)
  values (a.id, encode(extensions.digest(v_token, 'sha256'), 'hex'), app.person_id(), v_exp)
  on conflict (application_id) do update
     set token_hash = excluded.token_hash, invited_at = now(),
         invited_by = excluded.invited_by, expires_at = excluded.expires_at;

  v_link := rtrim(app.setting('site_url'), '/') || '/interview#t=' || v_token;
  select coalesce(mode() within group (order by minutes), 75) into v_mins
    from public.interview_slots where not withdrawn and starts_at > now();

  select * into r from app.render_email('interview_invite', jsonb_build_object(
    'given_name', a.given_name, 'reference', a.reference, 'link', v_link,
    'minutes_text', app.minutes_text(v_mins),
    'notice_hours', coalesce(nullif(app.setting('interview_notice_hours'), ''), '24'),
    'expires', trim(to_char(v_exp at time zone 'Europe/London', 'FMDD FMMonth YYYY'))));
  perform app.queue_message('interview_invite', r.subject, r.html, a.email,
    a.given_name || ' ' || a.family_name, null, null,
    jsonb_build_object('application_id', a.id));

  return jsonb_build_object('to', a.email, 'link', v_link, 'expires_at', v_exp);
end;
$$;
revoke all on function public.interview_invite(uuid) from public;
grant execute on function public.interview_invite(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 9. What the booking page shows (the Worker asks, with the link)
-- -----------------------------------------------------------------------------
create or replace function public.interview_page(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a      public.membership_applications;
  b      record;
  v_days integer := coalesce(nullif(app.setting('interview_days_ahead'), '')::int, 90);
begin
  a := app.interview_application(p_token);
  perform app.interview_expire_holds();

  select bk.id, s.starts_at, s.ends_at, s.minutes, bk.join_url
    into b
    from public.interview_bookings bk join public.interview_slots s on s.id = bk.slot_id
   where bk.application_id = a.id and bk.status = 'booked';

  return jsonb_build_object(
    'given_name', a.given_name,
    'reference', a.reference,
    'notice_hours', extract(epoch from app.interview_notice())::int / 3600,
    'booking', case when b.id is null then null else jsonb_build_object(
        'starts_at', b.starts_at, 'ends_at', b.ends_at, 'minutes', b.minutes,
        'join_url', b.join_url,
        'can_change', b.starts_at > now() + app.interview_notice()) end,
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'starts_at', s.starts_at,
                                          'ends_at', s.ends_at, 'minutes', s.minutes)
                       order by s.starts_at)
        from public.interview_slots s
       where not s.withdrawn
         and s.starts_at > now() + app.interview_notice()
         and s.starts_at < now() + make_interval(days => v_days)
         and not exists (select 1 from public.interview_bookings x
                          where x.slot_id = s.id and x.status in ('holding', 'booked'))
    ), '[]'::jsonb));
end;
$$;
revoke all on function public.interview_page(text) from public;
grant execute on function public.interview_page(text) to service_role;


-- -----------------------------------------------------------------------------
-- 10. Holding a slot, before Outlook is written
-- -----------------------------------------------------------------------------
create or replace function public.interview_hold(p_token text, p_slot uuid) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a     public.membership_applications;
  s     public.interview_slots;
  prev  record;
  v_id  uuid;
  v_grade text;
begin
  a := app.interview_application(p_token);
  perform app.interview_expire_holds();

  select * into s from public.interview_slots where id = p_slot for update;
  if not found or s.withdrawn then
    raise exception 'That time is no longer offered. Please choose another.' using errcode = 'P0002';
  end if;
  if s.starts_at <= now() + app.interview_notice() then
    raise exception 'That time is too soon to book online. Please choose a later one.'
      using errcode = '22023';
  end if;

  select bk.id, bk.slot_id, bk.event_id, sl.starts_at into prev
    from public.interview_bookings bk join public.interview_slots sl on sl.id = bk.slot_id
   where bk.application_id = a.id and bk.status = 'booked';
  if prev.id is not null then
    if prev.slot_id = s.id then
      raise exception 'That is already your interview time.' using errcode = '22023';
    end if;
    if prev.starts_at <= now() + app.interview_notice() then
      raise exception 'Your interview is too close to change online. Please reply to your '
                      'invitation email instead.' using errcode = '22023';
    end if;
  end if;

  if exists (select 1 from public.interview_bookings x
              where x.slot_id = s.id and x.status in ('holding', 'booked')) then
    raise exception 'Somebody has just booked that time. Please choose another.' using errcode = '23505';
  end if;

  -- A hold of their own from a moment ago (pressed twice, or changed their mind).
  update public.interview_bookings
     set status = 'expired', ended_at = now(), ended_by = 'system', reason = 'Replaced by a newer choice'
   where application_id = a.id and status = 'holding';

  insert into public.interview_bookings (application_id, slot_id) values (a.id, s.id)
  returning id into v_id;

  select g.name into v_grade from public.membership_grades g where g.id = a.grade_id;

  return jsonb_build_object(
    'booking', v_id, 'slot', s.id, 'starts_at', s.starts_at, 'ends_at', s.ends_at,
    'minutes', s.minutes,
    'given_name', a.given_name, 'family_name', a.family_name, 'email', a.email,
    'reference', a.reference, 'grade', v_grade,
    'previous', case when prev.id is null then null
                     else jsonb_build_object('booking', prev.id, 'event_id', prev.event_id,
                                             'starts_at', prev.starts_at) end);
exception when unique_violation then
  raise exception 'Somebody has just booked that time. Please choose another.' using errcode = '23505';
end;
$$;
revoke all on function public.interview_hold(text, uuid) from public;
grant execute on function public.interview_hold(text, uuid) to service_role;


-- -----------------------------------------------------------------------------
-- 11. Outlook said yes: the booking stands, and both sides are told
-- -----------------------------------------------------------------------------
create or replace function public.interview_confirm(p_booking uuid, p_event_id text, p_join_url text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  bk     public.interview_bookings;
  a      public.membership_applications;
  s      public.interview_slots;
  prev   record;
  v_grade text;
  v_join  text := nullif(btrim(coalesce(p_join_url, '')), '');
  v_repl  text := '';
  v_vars  jsonb;
  r       record;
  v_to    text;
begin
  select * into bk from public.interview_bookings where id = p_booking for update;
  if not found or bk.status <> 'holding' then
    raise exception 'That booking is not waiting to be confirmed.' using errcode = 'P0002';
  end if;
  -- Only a Teams address goes into an email as a link.
  if v_join is not null and v_join !~ '^https://teams\.(microsoft|live)\.com/' then
    v_join := null;
  end if;

  select * into a from public.membership_applications where id = bk.application_id;
  select * into s from public.interview_slots where id = bk.slot_id;
  select g.name into v_grade from public.membership_grades g where g.id = a.grade_id;

  select b2.id, b2.event_id, sl.starts_at into prev
    from public.interview_bookings b2 join public.interview_slots sl on sl.id = b2.slot_id
   where b2.application_id = a.id and b2.status = 'booked'
   for update of b2;
  if prev.id is not null then
    update public.interview_bookings
       set status = 'changed', ended_at = now(), ended_by = 'applicant',
           reason = 'Moved to ' || app.interview_when(s.starts_at)
     where id = prev.id;
    v_repl := 'This replaces the earlier time of ' || app.interview_when(prev.starts_at) || '.';
  end if;

  update public.interview_bookings
     set status = 'booked', booked_at = now(), event_id = nullif(btrim(coalesce(p_event_id, '')), ''),
         join_url = v_join
   where id = bk.id;

  v_vars := jsonb_build_object(
    'given_name', a.given_name, 'applicant', a.given_name || ' ' || a.family_name,
    'reference', a.reference, 'grade', coalesce(v_grade, 'a grade to be confirmed'),
    'email', a.email, 'when', app.interview_when(s.starts_at),
    'minutes_text', app.minutes_text(s.minutes),
    'notice_hours', coalesce(nullif(app.setting('interview_notice_hours'), ''), '24'),
    'replaces', v_repl,
    'join_url', coalesce(v_join, rtrim(app.setting('site_url'), '/') || '/interview'));

  select * into r from app.render_email('interview_booked', v_vars);
  perform app.queue_message('interview_booked', r.subject, r.html, a.email,
    a.given_name || ' ' || a.family_name, null, null,
    jsonb_build_object('application_id', a.id, 'booking', bk.id));

  select * into r from app.render_email('interview_booked_office', v_vars);
  foreach v_to in array app.interview_notify_list() loop
    perform app.queue_message('interview_booked_office', r.subject, r.html, v_to, null, null,
      a.email, jsonb_build_object('application_id', a.id, 'booking', bk.id));
  end loop;

  return jsonb_build_object('booked', true, 'starts_at', s.starts_at,
    'previous_event_id', prev.event_id);
end;
$$;
revoke all on function public.interview_confirm(uuid, text, text) from public;
grant execute on function public.interview_confirm(uuid, text, text) to service_role;


-- -----------------------------------------------------------------------------
-- 12. Outlook said no, or the slot clashed: let the hold go
-- -----------------------------------------------------------------------------
create or replace function public.interview_release(p_booking uuid, p_reason text) returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  update public.interview_bookings
     set status = 'failed', ended_at = now(), ended_by = 'system',
         reason = left(coalesce(p_reason, 'Not confirmed'), 300)
   where id = p_booking and status = 'holding';
end;
$$;
revoke all on function public.interview_release(uuid, text) from public;
grant execute on function public.interview_release(uuid, text) to service_role;


-- -----------------------------------------------------------------------------
-- 13. Cancelling
-- -----------------------------------------------------------------------------
-- Both routes end here, so the emails cannot differ between them.
create or replace function app.interview_end(p_booking uuid, p_by text, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  bk public.interview_bookings;
  a  public.membership_applications;
  s  public.interview_slots;
  v_vars jsonb;
  r  record;
  v_to text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into bk from public.interview_bookings where id = p_booking for update;
  if not found or bk.status <> 'booked' then
    raise exception 'There is no booked interview to cancel.' using errcode = 'P0002';
  end if;
  select * into a from public.membership_applications where id = bk.application_id;
  select * into s from public.interview_slots where id = bk.slot_id;

  update public.interview_bookings
     set status = 'cancelled', ended_at = now(), ended_by = p_by, reason = v_reason
   where id = bk.id;

  v_vars := jsonb_build_object(
    'given_name', a.given_name, 'applicant', a.given_name || ' ' || a.family_name,
    'reference', a.reference, 'when', app.interview_when(s.starts_at),
    'by_whom', case p_by when 'applicant' then 'by the applicant' else 'by the office' end,
    'reason', case when v_reason is null then '' else 'Reason: ' || v_reason end,
    'rebook', case when a.status in ('submitted', 'under_review')
                   then 'You can choose another time with the link in your invitation email.'
                   else '' end);

  select * into r from app.render_email('interview_cancelled', v_vars);
  perform app.queue_message('interview_cancelled', r.subject, r.html, a.email,
    a.given_name || ' ' || a.family_name, null, null,
    jsonb_build_object('application_id', a.id, 'booking', bk.id));

  select * into r from app.render_email('interview_cancelled_office', v_vars);
  foreach v_to in array app.interview_notify_list() loop
    perform app.queue_message('interview_cancelled_office', r.subject, r.html, v_to, null, null,
      a.email, jsonb_build_object('application_id', a.id, 'booking', bk.id));
  end loop;

  return jsonb_build_object('cancelled', true, 'event_id', bk.event_id);
end;
$$;
revoke all on function app.interview_end(uuid, text, text) from public;

-- The applicant, with their link. Not inside the notice period.
create or replace function public.interview_cancel(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a public.membership_applications;
  b record;
begin
  a := app.interview_application(p_token);
  select bk.id, s.starts_at into b
    from public.interview_bookings bk join public.interview_slots s on s.id = bk.slot_id
   where bk.application_id = a.id and bk.status = 'booked';
  if b.id is null then
    raise exception 'There is no booked interview to cancel.' using errcode = 'P0002';
  end if;
  if b.starts_at <= now() + app.interview_notice() then
    raise exception 'Your interview is too close to cancel online. Please reply to your '
                    'invitation email instead.' using errcode = '22023';
  end if;
  return app.interview_end(b.id, 'applicant', null);
end;
$$;
revoke all on function public.interview_cancel(text) from public;
grant execute on function public.interview_cancel(text) to service_role;

-- The office, at any time, with a reason the applicant is told.
create or replace function public.interview_office_cancel(p_booking uuid, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may cancel an interview.' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Cancelling needs a reason, because the applicant is told it.' using errcode = '22023';
  end if;
  return app.interview_end(p_booking, 'office', p_reason);
end;
$$;
revoke all on function public.interview_office_cancel(uuid, text) from public;
grant execute on function public.interview_office_cancel(uuid, text) to authenticated;


-- -----------------------------------------------------------------------------
-- 14. What the office sees
-- -----------------------------------------------------------------------------
-- Every slot, with whoever holds it. Gated in its own WHERE as well as by the
-- tables' policies, the way 0057 gates the admin views.
create or replace view public.admin_interview_slots
with (security_invoker = true) as
  select s.id, s.starts_at, s.ends_at, s.minutes, s.note, s.withdrawn,
         case when s.withdrawn then 'withdrawn'
              when bk.status = 'booked' then 'booked'
              when bk.status = 'holding' then 'being booked'
              when s.starts_at < now() then 'past'
              else 'open' end as state,
         bk.id as booking_id, bk.booked_at, bk.join_url,
         a.id as application_id, a.reference,
         a.given_name || ' ' || a.family_name as applicant, a.email
    from public.interview_slots s
    left join public.interview_bookings bk
           on bk.slot_id = s.id and bk.status in ('holding', 'booked')
    left join public.membership_applications a on a.id = bk.application_id
   where (select app.is_membership_staff());
grant select on public.admin_interview_slots to authenticated;

-- The application queue gains the interview, at the end so nothing that reads
-- it by position notices.
create or replace view public.admin_application_queue
with (security_invoker = true) as
  select a.id, a.reference, a.status,
         a.given_name, a.family_name, a.email, a.telephone,
         a.date_of_birth, a.private_address,
         a.employer_name, a.job_title, a.date_appointed,
         a.invoice_name, a.invoice_address,
         a.signed_name, a.signed_on, a.signature_path,
         g.name as grade, a.grade_id,
         a.submitted_at, a.created_at, a.decided_at, a.decision_note,
         (select count(*) from public.application_documents d where d.application_id = a.id) as documents,
         iv.invited_at as interview_invited_at,
         ib.id as interview_booking_id,
         ib.starts_at as interview_at,
         ib.minutes as interview_minutes,
         ib.join_url as interview_join_url
    from public.membership_applications a
    left join public.membership_grades g on g.id = a.grade_id
    left join public.interview_invitations iv on iv.application_id = a.id
    left join lateral (
      select bk.id, s.starts_at, s.minutes, bk.join_url
        from public.interview_bookings bk join public.interview_slots s on s.id = bk.slot_id
       where bk.application_id = a.id and bk.status = 'booked'
       limit 1) ib on true;
grant select on public.admin_application_queue to authenticated;
