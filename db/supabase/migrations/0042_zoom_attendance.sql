-- =============================================================================
-- 0042  Zoom attendance: CPD for being there
--
-- The plan agreed on 30 October 2026 (claude/ami-cpd-automation-plan.md), item 3
-- in the order of work:
--
--   Attendance is read from Zoom after each webinar or meeting. Anybody present
--   for at least 75% of the session gets the points. A person who drops out and
--   rejoins appears more than once and their times are put together. People are
--   matched by email; anybody who cannot be matched goes into a queue for the
--   office to link once, and the link is remembered. Nothing is backdated: no
--   award for a session held before 1 January 2027.
--
-- HOW IT FITS TOGETHER
--
--   The office writes the session down first (zoom_sessions): the Zoom number,
--   the date, what it counts as. Then presses Fetch attendance in the admin app.
--   The admin app asks the site's Worker, carrying the staff member's own sign
--   in. The Worker asks the database whether this person may import this
--   session (zoom_import_begin, as them), reads the report from Zoom with AMI's
--   own Zoom credentials, and hands the report to the database
--   (zoom_record_attendance, as the service role). The database does all the
--   arithmetic and every decision. So the 75% rule, the matching and the
--   once per event rule each live in exactly one place, and that place is
--   tested.
--
-- FOUR THINGS THAT MUST HOLD, and test 25 holds them:
--
--   ATTENDANCE COMES FROM ZOOM AND NOWHERE ELSE. The function that records it is
--   granted to the service role only, and it accepts a report only for a
--   session a member of staff began importing in the last ten minutes. A staff
--   member's browser cannot write attendance, and the Worker cannot import a
--   session nobody asked for.
--
--   TIMES ARE PUT TOGETHER AS A UNION, NOT A SUM. The plan says rejoins are
--   added together, and for somebody who leaves and comes back that is what a
--   union gives. Somebody on a laptop and a phone at once appears twice OVER
--   THE SAME MINUTES, and summing would credit them double. A union counts
--   each minute once, which is the only reading under which "present for 75%"
--   means anything.
--
--   ONE EVENT, ONE AWARD. Every award goes through app.award_cpd with the
--   session's event key, so importing twice, or attending live and then passing
--   the recording's questions, awards once.
--
--   A MATCH IS NEVER A GUESS. Email only, and only when exactly one current
--   membership carries it. A display name is never matched, because two members can
--   share one and "iPhone" is a common name on Zoom. The office links the rest
--   by membership number.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. When the feeds start counting
-- -----------------------------------------------------------------------------
-- A setting rather than a constant, so staging can be tested with a real Zoom
-- meeting in November. ON THE LIVE DATABASE IT STAYS 2027-01-01: nothing is
-- backdated.
insert into public.system_settings (key, value, note) values
  ('cpd_feeds_from', '2027-01-01',
   'The first day attendance from Zoom (and later ARCA''s records) earns CPD. '
   'Sessions before it are read and recorded but award nothing. 2027-01-01 on '
   'the live site. On staging it can be set earlier to test with a real meeting, '
   'and must be put back.')
on conflict (key) do nothing;

create or replace function app.cpd_feeds_from() returns date
language sql stable security definer set search_path = ''
as $$ select coalesce(nullif(app.setting('cpd_feeds_from'), '')::date, date '2027-01-01'); $$;


-- -----------------------------------------------------------------------------
-- 2. The sessions
-- -----------------------------------------------------------------------------
create table if not exists public.zoom_sessions (
  id                  uuid primary key default gen_random_uuid(),
  title               text not null check (length(btrim(title)) >= 3),
  kind                text not null default 'meeting' check (kind in ('meeting', 'webinar')),
  zoom_id             text not null,
  zoom_uuid           text,
  held_on             date not null,
  activity_type_id    uuid not null references public.cpd_activity_types(id),
  points              numeric(4,1),
  length_minutes      integer check (length_minutes is null or length_minutes between 10 and 600),
  min_percent         integer not null default 75 check (min_percent between 1 and 100),
  event_key           text not null,
  status              text not null default 'waiting' check (status in ('waiting', 'imported')),
  -- What Zoom said, kept so a challenge can be answered from the record.
  zoom_topic          text,
  zoom_started_at     timestamptz,
  zoom_ended_at       timestamptz,
  counted_minutes     integer,
  last_result         jsonb,
  imported_at         timestamptz,
  imported_by         uuid references public.people(id),
  import_requested_by uuid references public.people(id),
  import_requested_at timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create unique index if not exists zoom_sessions_event_key on public.zoom_sessions (event_key);

comment on table public.zoom_sessions is
  'A Zoom webinar or meeting that earns CPD. The office writes it down, then '
  'presses Fetch attendance; the report is read from Zoom by the Worker and '
  'decided here. For a MEETING Zoom only gives an attendee''s email when the '
  'meeting requires registration, so every meeting that earns CPD must have it on.';
comment on column public.zoom_sessions.length_minutes is
  'How long the session was meant to be. 75% is measured against this. Left '
  'empty, the length Zoom recorded is used, which is longer than it should be '
  'when a host leaves the meeting open afterwards.';
comment on column public.zoom_sessions.event_key is
  'Give the recording''s read and watch item the same key, so attending live and '
  'passing the recording award once. Filled in from the activity and the date '
  'when left empty.';
comment on column public.zoom_sessions.zoom_uuid is
  'Only for a meeting number used more than once on the same day. Otherwise the '
  'occurrence is found from the date.';

drop trigger if exists zoom_sessions_updated on public.zoom_sessions;
create trigger zoom_sessions_updated before update on public.zoom_sessions
  for each row execute function app.set_updated_at();

create or replace function app.zoom_session_rules() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  t public.cpd_activity_types;
begin
  -- People paste the number as Zoom shows it, "812 3456 7890".
  new.zoom_id := regexp_replace(coalesce(new.zoom_id, ''), '[^0-9]', '', 'g');
  if new.zoom_id !~ '^[0-9]{9,12}$' then
    raise exception 'The Zoom number is the 9 to 12 digits in the meeting or webinar ID.'
      using errcode = '22023';
  end if;
  new.zoom_uuid := nullif(btrim(coalesce(new.zoom_uuid, '')), '');

  select * into t from public.cpd_activity_types where id = new.activity_type_id;
  if t.id is null then
    raise exception 'Choose the CPD activity this counts as.' using errcode = '22023';
  end if;
  -- The value is the activity's, exactly as for read and watch items (0041).
  if t.points is not null then
    new.points := t.points;
  elsif new.points is null or new.points < t.points_min or new.points > t.points_max then
    raise exception '% is valued session by session: set the points, between % and %.', t.name,
      app.cpd_num(t.points_min), app.cpd_num(t.points_max) using errcode = '22023';
  end if;

  new.event_key := lower(btrim(coalesce(new.event_key, '')));
  if new.event_key = '' then
    new.event_key := replace(t.code, '_', '-') || '-' || to_char(new.held_on, 'YYYY-MM-DD');
  end if;

  -- Once attendance has been read, what the points were FOR is settled. Changing
  -- the activity, the value, the date or the key afterwards would leave awards
  -- on members' records that no longer match the session that made them.
  if tg_op = 'UPDATE' and old.status = 'imported'
     and (new.activity_type_id, new.points, new.held_on, new.event_key)
         is distinct from (old.activity_type_id, old.points, old.held_on, old.event_key) then
    raise exception 'Attendance has already been read for this session, so what it counts as, its points, its date and its event key are fixed.'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists zoom_session_rules on public.zoom_sessions;
create trigger zoom_session_rules before insert or update on public.zoom_sessions
  for each row execute function app.zoom_session_rules();

alter table public.zoom_sessions enable row level security;
revoke all on public.zoom_sessions from anon, authenticated;
grant select, insert, update, delete on public.zoom_sessions to authenticated;

drop policy if exists zoom_sessions_staff on public.zoom_sessions;
create policy zoom_sessions_staff on public.zoom_sessions
  for all to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));


-- -----------------------------------------------------------------------------
-- 3. Who was there
-- -----------------------------------------------------------------------------
create table if not exists public.zoom_attendance (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.zoom_sessions(id) on delete cascade,
  -- The email, lower case, or for somebody Zoom gave no email for, 'name:' and
  -- their display name. One row per identity per session.
  identity    text not null,
  email       text,
  name        text,
  intervals   jsonb not null default '[]'::jsonb,
  minutes     integer not null default 0,
  percent     integer not null default 0,
  member_id   uuid references public.members(id),
  matched_by  text check (matched_by in ('email', 'link', 'office')),
  outcome     text not null default 'unmatched' check (outcome in (
                'awarded',          -- points on the record
                'already_counted',  -- this event was already on their record
                'too_short',        -- present, but under the session's percentage
                'before_scheme',    -- held before the feeds start counting
                'not_current',      -- matched to a membership that is not active
                'unmatched',        -- an email no single current member holds
                'no_email',         -- Zoom gave a display name only
                'not_member')),     -- the office said so
  entry_id    uuid references public.cpd_entries(id),
  decided_by  uuid references public.people(id),
  decided_at  timestamptz,
  updated_at  timestamptz not null default now(),
  unique (session_id, identity)
);
create index if not exists zoom_attendance_email on public.zoom_attendance (email) where email is not null;

comment on table public.zoom_attendance is
  'One row per person per session, written only by zoom_record_attendance. The '
  'intervals are what Zoom reported; minutes is their union within the session.';

drop trigger if exists zoom_attendance_updated on public.zoom_attendance;
create trigger zoom_attendance_updated before update on public.zoom_attendance
  for each row execute function app.set_updated_at();

alter table public.zoom_attendance enable row level security;
revoke all on public.zoom_attendance from anon, authenticated;
-- Read only. Every change is a function call that decides as well as writes.
grant select on public.zoom_attendance to authenticated;

drop policy if exists zoom_attendance_staff on public.zoom_attendance;
create policy zoom_attendance_staff on public.zoom_attendance
  for select to authenticated using ((select app.is_membership_staff()));


-- -----------------------------------------------------------------------------
-- 4. Remembered links: an address the office has said belongs to somebody
-- -----------------------------------------------------------------------------
-- Shared by every feed, Zoom now and ARCA's records later, because an address
-- a member uses at work belongs to them whichever system it turned up in.
create table if not exists public.cpd_feed_links (
  email       text primary key check (email = lower(btrim(email)) and email like '%_@_%'),
  member_id   uuid references public.members(id),
  not_member  boolean not null default false,
  linked_by   uuid references public.people(id),
  linked_at   timestamptz not null default now(),
  check ((member_id is null) = not_member)
);

comment on table public.cpd_feed_links is
  'An address the office has linked to a member, or said is not a member, so '
  'the next session from the same address is matched without asking again. '
  'Deleting a row stops future matching; it takes no points away.';

alter table public.cpd_feed_links enable row level security;
revoke all on public.cpd_feed_links from anon, authenticated;
-- Select and delete only. A link is made by feed_link, which decides as it goes.
grant select, delete on public.cpd_feed_links to authenticated;

drop policy if exists feed_links_read on public.cpd_feed_links;
create policy feed_links_read on public.cpd_feed_links
  for select to authenticated using ((select app.is_membership_staff()));
drop policy if exists feed_links_delete on public.cpd_feed_links;
create policy feed_links_delete on public.cpd_feed_links
  for delete to authenticated using ((select app.is_membership_staff()));


-- Every office decision on these three tables is in the audit log, as every
-- CPD decision is.
drop trigger if exists zoom_sessions_audit on public.zoom_sessions;
create trigger zoom_sessions_audit after insert or update or delete on public.zoom_sessions
  for each row execute function app.audit_row();
drop trigger if exists zoom_attendance_audit on public.zoom_attendance;
create trigger zoom_attendance_audit after insert or update or delete on public.zoom_attendance
  for each row execute function app.audit_row();
drop trigger if exists cpd_feed_links_audit on public.cpd_feed_links;
create trigger cpd_feed_links_audit after insert or update or delete on public.cpd_feed_links
  for each row execute function app.audit_row();


-- -----------------------------------------------------------------------------
-- 5. Deciding one row
-- -----------------------------------------------------------------------------
-- Called after every import and every link. Safe to call any number of times:
-- the award is once per member per event whatever happens here.
create or replace function app.zoom_decide(p_row uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a       public.zoom_attendance;
  s       public.zoom_sessions;
  lk      public.cpd_feed_links;
  v_mem   uuid;
  v_by    text;
  v_n     int;
  v_entry uuid;
  v_out   text;
begin
  select * into a from public.zoom_attendance where id = p_row for update;
  select * into s from public.zoom_sessions where id = a.session_id;

  -- WHO. An office decision about this one row stands; anything matched by
  -- email or by a remembered link is worked out again, so a link the office
  -- has since deleted stops applying.
  if a.matched_by = 'office' then
    v_mem := a.member_id; v_by := 'office';
  elsif a.outcome = 'not_member' and a.decided_by is not null then
    return 'not_member';
  elsif a.email is null then
    update public.zoom_attendance set member_id = null, matched_by = null, outcome = 'no_email'
     where id = a.id;
    return 'no_email';
  else
    select * into lk from public.cpd_feed_links where email = a.email;
    if lk.email is not null and lk.not_member then
      update public.zoom_attendance set member_id = null, matched_by = null, outcome = 'not_member'
       where id = a.id;
      return 'not_member';
    elsif lk.member_id is not null then
      v_mem := lk.member_id; v_by := 'link';
    else
      -- Exactly one CURRENT membership with this address, or no match at all.
      -- people.email is unique, so more than one means one person holding two
      -- active memberships, which is for the office to settle, not for a guess.
      select count(*), (array_agg(m.id))[1] into v_n, v_mem
        from public.members m join public.people p on p.id = m.person_id
       where m.is_active and lower(btrim(p.email)) = a.email;
      if v_n = 1 then
        v_by := 'email';
      elsif v_n = 0 then
        -- No current member. A lapsed one with the address is said so, rather
        -- than left looking like a stranger.
        select (array_agg(m.id))[1] into v_mem
          from public.members m join public.people p on p.id = m.person_id
         where lower(btrim(p.email)) = a.email;
        if v_mem is not null then
          update public.zoom_attendance set member_id = v_mem, matched_by = 'email', outcome = 'not_current'
           where id = a.id;
          return 'not_current';
        end if;
        v_mem := null;
      else
        v_mem := null;
      end if;
      if v_mem is null then
        update public.zoom_attendance set member_id = null, matched_by = null, outcome = 'unmatched'
         where id = a.id;
        return 'unmatched';
      end if;
    end if;
  end if;

  -- WHETHER IT COUNTS.
  if not exists (select 1 from public.members where id = v_mem and is_active) then
    v_out := 'not_current';
  elsif a.entry_id is not null and exists (
          select 1 from public.cpd_entries where id = a.entry_id and status <> 'rejected') then
    v_out := 'awarded';               -- a second import of the same session
  elsif s.held_on < app.cpd_feeds_from() then
    v_out := 'before_scheme';
  elsif a.percent < s.min_percent then
    v_out := 'too_short';
  else
    v_entry := app.award_cpd(v_mem, s.activity_type_id, s.points, s.title, s.held_on,
                             s.id, a.id, s.event_key,
                             'You were at it on Zoom for ' || a.minutes || ' minutes.');
    v_out := case when v_entry is null then 'already_counted' else 'awarded' end;
  end if;

  update public.zoom_attendance
     set member_id = v_mem, matched_by = v_by, outcome = v_out,
         entry_id = coalesce(v_entry, entry_id)
   where id = a.id;
  return v_out;
end;
$$;
revoke all on function app.zoom_decide(uuid) from public;


-- -----------------------------------------------------------------------------
-- 6. Beginning an import: asked by a member of staff, as themselves
-- -----------------------------------------------------------------------------
create or replace function public.zoom_import_begin(p_session uuid) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  s public.zoom_sessions;
  v_by uuid := app.person_id();
begin
  if not app.is_membership_staff() or v_by is null then
    raise exception 'Reading attendance from Zoom is for membership staff.' using errcode = '42501';
  end if;
  select * into s from public.zoom_sessions where id = p_session;
  if s.id is null then
    raise exception 'There is no such session.' using errcode = '22023';
  end if;
  if s.held_on > current_date then
    raise exception 'That session has not happened yet.' using errcode = '22023';
  end if;
  update public.zoom_sessions
     set import_requested_by = v_by, import_requested_at = now()
   where id = s.id;
  return jsonb_build_object('kind', s.kind, 'zoom_id', s.zoom_id, 'zoom_uuid', s.zoom_uuid,
                            'held_on', s.held_on, 'by', v_by);
end;
$$;
revoke all on function public.zoom_import_begin(uuid) from public;
grant execute on function public.zoom_import_begin(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 7. Recording what Zoom said: the Worker, as the service role
-- -----------------------------------------------------------------------------
-- One line per join, as Zoom reported it, with the address lower cased so that
-- Jane@ and jane@ are one person. Time in the waiting room is not time in the
-- session, and a line with no leave time (somebody still connected when the
-- report was cut) is left out rather than guessed at.
create or replace function app.zoom_lines(p_report jsonb)
returns table (identity text, email text, name text, j timestamptz, l timestamptz)
language sql stable set search_path = ''
as $$
  select coalesce(x.email, 'name:' || lower(coalesce(x.name, 'unknown'))), x.email, x.name, x.j, x.l
    from (select nullif(lower(btrim(coalesce(p ->> 'email', p ->> 'user_email', ''))), '') as email,
                 nullif(btrim(coalesce(p ->> 'name', p ->> 'user_name', '')), '') as name,
                 nullif(p ->> 'join_time', '')::timestamptz as j,
                 nullif(p ->> 'leave_time', '')::timestamptz as l,
                 coalesce(p ->> 'status', 'in_meeting') as st
            from jsonb_array_elements(coalesce(p_report -> 'participants', '[]'::jsonb)) p) x
   where x.st <> 'in_waiting_room' and x.j is not null and x.l is not null and x.l > x.j;
$$;
revoke all on function app.zoom_lines(jsonb) from public;

-- p_report: { uuid, topic, start_time, end_time, participants: [ { email, name,
-- join_time, leave_time, status } ] }, the participants exactly as Zoom gave
-- them, one line per join. All of the arithmetic is here.
create or replace function public.zoom_record_attendance(p_session uuid, p_report jsonb, p_by uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  s        public.zoom_sessions;
  v_start  timestamptz;
  v_end    timestamptz;
  v_len    int;
  r        record;
  v_counts jsonb;
begin
  select * into s from public.zoom_sessions where id = p_session for update;
  if s.id is null then
    raise exception 'There is no such session.' using errcode = '22023';
  end if;
  -- Only an import somebody on the staff began, in the last ten minutes. The
  -- grant keeps browsers out; this keeps the Worker to what it was asked.
  if p_by is null or s.import_requested_by is distinct from p_by
     or s.import_requested_at < now() - interval '10 minutes' then
    raise exception 'Nobody on the staff asked for this import just now.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_report -> 'participants') <> 'array' then
    raise exception 'The report from Zoom is not in the expected shape.' using errcode = '22023';
  end if;

  v_start := coalesce((p_report ->> 'start_time')::timestamptz, (select min(j) from app.zoom_lines(p_report)));
  v_end   := coalesce((p_report ->> 'end_time')::timestamptz,   (select max(l) from app.zoom_lines(p_report)));
  if v_start is null or v_end is null or v_end <= v_start then
    raise exception 'Zoom reported nobody in that session, or no start and end to it.' using errcode = '22023';
  end if;
  v_len := coalesce(s.length_minutes, ceil(extract(epoch from (v_end - v_start)) / 60)::int);

  -- The union of each person's time within the session, in whole minutes.
  for r in
    select identity, max(email) as email, max(name) as name,
           jsonb_agg(jsonb_build_array(j, l) order by j) as intervals,
           coalesce((select floor(sum(extract(epoch from (upper(u) - lower(u)))) / 60)::int
                       from unnest(range_agg(tstzrange(j, l))
                                   * tstzmultirange(tstzrange(v_start, v_end))) u), 0) as minutes
      from app.zoom_lines(p_report)
     group by identity
  loop
    insert into public.zoom_attendance (session_id, identity, email, name, intervals, minutes, percent)
    values (s.id, r.identity, r.email, r.name, r.intervals, r.minutes,
            least(100, floor(100.0 * r.minutes / v_len))::int)
    on conflict (session_id, identity) do update
       set email = excluded.email, name = excluded.name, intervals = excluded.intervals,
           minutes = excluded.minutes, percent = excluded.percent;
  end loop;

  perform app.zoom_decide(id) from public.zoom_attendance where session_id = s.id;

  select jsonb_object_agg(outcome, n) into v_counts
    from (select outcome, count(*) as n from public.zoom_attendance
           where session_id = s.id group by outcome) c;

  update public.zoom_sessions
     set status = 'imported', imported_at = now(), imported_by = p_by,
         import_requested_by = null, import_requested_at = null,
         zoom_topic = left(p_report ->> 'topic', 300), zoom_uuid = coalesce(zoom_uuid, nullif(p_report ->> 'uuid', '')),
         zoom_started_at = v_start, zoom_ended_at = v_end, counted_minutes = v_len,
         last_result = coalesce(v_counts, '{}'::jsonb)
   where id = s.id;

  return jsonb_build_object('length_minutes', v_len, 'counts', coalesce(v_counts, '{}'::jsonb),
                            'before_scheme', s.held_on < app.cpd_feeds_from());
end;
$$;
revoke all on function public.zoom_record_attendance(uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.zoom_record_attendance(uuid, jsonb, uuid) to service_role;


-- -----------------------------------------------------------------------------
-- 8. The office settling the queue
-- -----------------------------------------------------------------------------
-- Linked by MEMBERSHIP NUMBER, which is unambiguous and printed on every card,
-- rather than by choosing a name from a list.
create or replace function public.feed_link(p_row uuid, p_membership_number text)
returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a     public.zoom_attendance;
  v_mem uuid;
  v_by  uuid := app.person_id();
  v_out text;
  o     record;
begin
  if not app.is_membership_staff() then
    raise exception 'Linking attendance is for membership staff.' using errcode = '42501';
  end if;
  select * into a from public.zoom_attendance where id = p_row;
  if a.id is null then
    raise exception 'There is no such attendance.' using errcode = '22023';
  end if;
  select id into v_mem from public.members
   where upper(btrim(membership_number)) = upper(btrim(coalesce(p_membership_number, '')));
  if v_mem is null then
    raise exception 'No member has the membership number %.', btrim(p_membership_number)
      using errcode = '22023';
  end if;

  if a.email is not null then
    -- Remembered, and every other session waiting on the same address is
    -- settled in the same breath.
    insert into public.cpd_feed_links (email, member_id, not_member, linked_by)
    values (a.email, v_mem, false, v_by)
    on conflict (email) do update
       set member_id = excluded.member_id, not_member = false,
           linked_by = excluded.linked_by, linked_at = now();
    update public.zoom_attendance
       set matched_by = null, decided_by = v_by, decided_at = now(),
           outcome = case when outcome = 'not_member' then 'unmatched' else outcome end
     where email = a.email and coalesce(matched_by, '') <> 'office';
    for o in select id from public.zoom_attendance
              where email = a.email and coalesce(matched_by, '') <> 'office' and id <> a.id loop
      perform app.zoom_decide(o.id);
    end loop;
  else
    -- No address to remember: this row, this once.
    update public.zoom_attendance
       set member_id = v_mem, matched_by = 'office', decided_by = v_by, decided_at = now()
     where id = a.id;
  end if;
  v_out := app.zoom_decide(a.id);
  return v_out;
end;
$$;
revoke all on function public.feed_link(uuid, text) from public;
grant execute on function public.feed_link(uuid, text) to authenticated;

create or replace function public.feed_dismiss(p_row uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a    public.zoom_attendance;
  v_by uuid := app.person_id();
begin
  if not app.is_membership_staff() then
    raise exception 'Settling attendance is for membership staff.' using errcode = '42501';
  end if;
  select * into a from public.zoom_attendance where id = p_row;
  if a.id is null then
    raise exception 'There is no such attendance.' using errcode = '22023';
  end if;
  if a.outcome = 'awarded' then
    raise exception 'Points have already been awarded for this. Reject the entry in CPD to review if they should not have been.'
      using errcode = '22023';
  end if;
  if a.email is not null then
    insert into public.cpd_feed_links (email, member_id, not_member, linked_by)
    values (a.email, null, true, v_by)
    on conflict (email) do update
       set member_id = null, not_member = true, linked_by = excluded.linked_by, linked_at = now();
  end if;
  update public.zoom_attendance
     set member_id = null, matched_by = null, outcome = 'not_member',
         decided_by = v_by, decided_at = now()
   where id = a.id
      or (a.email is not null and email = a.email and outcome in ('unmatched', 'not_member'));
  return 'not_member';
end;
$$;
revoke all on function public.feed_dismiss(uuid) from public;
grant execute on function public.feed_dismiss(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 9. What the admin app reads
-- -----------------------------------------------------------------------------
-- One view for the queue and for a session's own list. Named for the feeds
-- rather than for Zoom, because ARCA's records join it at item 5 of the plan.
create or replace view public.admin_cpd_feed_queue
with (security_invoker = true) as
  select a.id, 'Zoom'::text as source, a.session_id, s.title as session, s.held_on,
         s.min_percent, s.counted_minutes,
         a.email, a.name, a.minutes, a.percent, a.outcome, a.matched_by, a.decided_at,
         a.updated_at,
         m.membership_number, p.given_name, p.family_name
    from public.zoom_attendance a
    join public.zoom_sessions s on s.id = a.session_id
    left join public.members m on m.id = a.member_id
    left join public.people p on p.id = m.person_id;

revoke all on public.admin_cpd_feed_queue from public, anon;
grant select on public.admin_cpd_feed_queue to authenticated;
