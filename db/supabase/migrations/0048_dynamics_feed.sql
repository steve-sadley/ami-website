-- =============================================================================
-- 0048  ARCA's records: CPD from Dynamics
--
-- The plan agreed on 30 October 2026 (claude/ami-cpd-automation-plan.md), item 5
-- in the order of work, as Steve settled it on 31 October:
--
--   The data comes out of Dynamics the same way it does for AuditFlow: a
--   scheduled sync with its own read-only app registration, reading three
--   system views that ARCA's Dynamics admin sets up and names:
--
--     AMI Sync: Regional meetings     who attended which ARCA regional meeting
--     AMI Sync: ARCA AGM              who attended the ARCA AGM
--     AMI Sync: Training completions  who completed which ARCA training course
--
--   Attendance earns the activity's points, matched by email exactly as Zoom
--   is, through the same People to match queue and the same remembered links.
--   A training course earns points only once the office has said that course
--   counts. Nothing before 1 January 2027 is awarded.
--
-- HOW IT FITS TOGETHER
--
--   A small Worker of its own, ami-dynamics-sync, runs three times each weekday
--   and when the office presses Sync now. It signs in to Dynamics, finds each
--   view by its name, reads every row in it and hands the rows to this
--   database exactly as Dynamics gave them. The Worker understands nothing
--   about the rows: which column is the email, which is the date and so on is
--   written down here, in dynamics_feeds, by the office, from the column names
--   the Worker reports. So every decision lives in one place, and that place
--   is tested (test 39).
--
-- WHAT MUST HOLD
--
--   ATTENDANCE COMES FROM DYNAMICS AND NOWHERE ELSE. dynamics_record is granted
--   to the service role only, and accepts rows only into a run that is
--   running, begun in the last twenty minutes.
--
--   A MATCH IS NEVER A GUESS. The same rule as Zoom, from the same function
--   now: an email held by exactly one current membership, or a link the office
--   made by membership number. An address linked for Zoom is linked for
--   Dynamics, and the other way round.
--
--   ONE EVENT, ONE AWARD. Every award goes through app.award_cpd with the
--   session's event key, so a row read on every run, or a meeting attended
--   and its recording passed, awards once.
--
--   NOTHING IS TAKEN AWAY BY A SYNC. A row that later disappears from a view,
--   or changes, leaves any points it earned where they are. Points are taken
--   away by a person rejecting the entry, as for every other automatic award.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The three feeds, and which column is which
-- -----------------------------------------------------------------------------
create table if not exists public.dynamics_feeds (
  code          text primary key check (code in ('regional_meetings', 'arca_agm', 'arca_training')),
  title         text not null,
  view_name     text not null check (length(btrim(view_name)) between 3 and 100),
  activity_code text not null,
  -- The column names in the view, as Dynamics reports them. Empty until the
  -- office fills them in from the names the first run reports.
  email_field   text,
  name_field    text,
  event_field   text,
  code_field    text,
  date_field    text,
  active        boolean not null default true,
  -- What the last run saw, so the office can fill the fields in without
  -- anybody opening Dynamics.
  seen_entity   text,
  seen_fields   jsonb not null default '[]'::jsonb,
  last_run_at   timestamptz,
  last_result   jsonb,
  updated_at    timestamptz not null default now()
);

comment on table public.dynamics_feeds is
  'The three Dynamics views AMI reads, and which column in each is the email, '
  'the name, the event or course, its code and the date. The Worker reads the '
  'view by its name and reports the column names it found in seen_fields.';
comment on column public.dynamics_feeds.event_field is
  'The meeting, or for training the course. For the ARCA AGM it may be left '
  'empty: the AGM is one event a day.';
comment on column public.dynamics_feeds.code_field is
  'Optional. A code or number that tells two meetings with the same name apart.';

insert into public.dynamics_feeds (code, title, view_name, activity_code) values
  ('regional_meetings', 'ARCA regional meetings', 'AMI Sync: Regional meetings',    'regional_meeting_2027'),
  ('arca_agm',          'ARCA AGM',               'AMI Sync: ARCA AGM',             'arca_agm'),
  ('arca_training',     'ARCA training courses',  'AMI Sync: Training completions', 'arca_training')
on conflict (code) do nothing;

create or replace function app.dynamics_feed_rules() returns trigger
language plpgsql security invoker set search_path = ''
as $$
declare
  f text;
begin
  -- A column name is a Dynamics logical name: letters, digits, underscores,
  -- and a dot for a column from a linked table. Nothing else, so a field name
  -- can never be anything but a key to look up.
  foreach f in array array[new.email_field, new.name_field, new.event_field, new.code_field, new.date_field] loop
    if f is not null and btrim(f) <> '' and btrim(f) !~ '^[A-Za-z_][A-Za-z0-9_.]{0,99}$' then
      raise exception '"%" is not a Dynamics column name. Copy it exactly from the list the sync found.', f
        using errcode = '22023';
    end if;
  end loop;
  new.email_field := nullif(btrim(coalesce(new.email_field, '')), '');
  new.name_field  := nullif(btrim(coalesce(new.name_field, '')), '');
  new.event_field := nullif(btrim(coalesce(new.event_field, '')), '');
  new.code_field  := nullif(btrim(coalesce(new.code_field, '')), '');
  new.date_field  := nullif(btrim(coalesce(new.date_field, '')), '');
  new.view_name   := btrim(new.view_name);
  new.updated_at  := now();
  return new;
end;
$$;
drop trigger if exists dynamics_feed_rules on public.dynamics_feeds;
create trigger dynamics_feed_rules before insert or update on public.dynamics_feeds
  for each row execute function app.dynamics_feed_rules();

alter table public.dynamics_feeds enable row level security;
revoke all on public.dynamics_feeds from anon, authenticated;
grant select on public.dynamics_feeds to authenticated;
-- The office sets which column is which, and can pause a feed. What the run
-- saw, and which activity a feed earns, are not theirs to type.
grant update (view_name, email_field, name_field, event_field, code_field, date_field, active)
  on public.dynamics_feeds to authenticated;

drop policy if exists dynamics_feeds_read on public.dynamics_feeds;
create policy dynamics_feeds_read on public.dynamics_feeds
  for select to authenticated using ((select app.is_membership_staff()));
drop policy if exists dynamics_feeds_write on public.dynamics_feeds;
create policy dynamics_feeds_write on public.dynamics_feeds
  for update to authenticated
  using ((select app.is_membership_staff())) with check ((select app.is_membership_staff()));

drop trigger if exists dynamics_feeds_audit on public.dynamics_feeds;
-- Only what the office changes. Each run writes what it saw, and that is not
-- history anybody will have to explain.
create trigger dynamics_feeds_audit
  after insert or delete or update of view_name, email_field, name_field, event_field, code_field, date_field, active
  on public.dynamics_feeds
  for each row execute function app.audit_row();

-- A feed is ready when the columns it cannot work without are named.
create or replace function app.dynamics_feed_ready(f public.dynamics_feeds) returns boolean
language sql stable set search_path = ''
as $$
  select f.active and f.email_field is not null and f.date_field is not null
     and (f.code = 'arca_agm' or f.event_field is not null);
$$;


-- -----------------------------------------------------------------------------
-- 2. Runs
-- -----------------------------------------------------------------------------
create table if not exists public.dynamics_runs (
  id            uuid primary key default gen_random_uuid(),
  trigger       text not null check (trigger in ('schedule', 'office')),
  status        text not null default 'running'
                check (status in ('requested', 'running', 'ok', 'failed', 'skipped')),
  requested_by  uuid references public.people(id),
  requested_at  timestamptz,
  started_at    timestamptz,
  finished_at   timestamptz,
  result        jsonb not null default '{}'::jsonb,
  error         text
);
create index if not exists dynamics_runs_started on public.dynamics_runs (started_at desc);

comment on table public.dynamics_runs is
  'Every sync, scheduled or pressed for, with what it read and any error.';

alter table public.dynamics_runs enable row level security;
revoke all on public.dynamics_runs from anon, authenticated;
grant select on public.dynamics_runs to authenticated;
drop policy if exists dynamics_runs_read on public.dynamics_runs;
create policy dynamics_runs_read on public.dynamics_runs
  for select to authenticated using ((select app.is_membership_staff()));


-- -----------------------------------------------------------------------------
-- 3. Sessions, courses and who was there
-- -----------------------------------------------------------------------------
create table if not exists public.dynamics_sessions (
  id                uuid primary key default gen_random_uuid(),
  feed              text not null references public.dynamics_feeds(code),
  ref               text not null,
  title             text not null,
  held_on           date not null,
  activity_type_id  uuid not null references public.cpd_activity_types(id),
  points            numeric(4,1) not null,
  event_key         text not null,
  course_id         uuid,
  created_at        timestamptz not null default now(),
  unique (feed, ref)
);
create unique index if not exists dynamics_sessions_event_key on public.dynamics_sessions (event_key);

comment on table public.dynamics_sessions is
  'A meeting, an AGM, or a course on a date, as ARCA''s records name it. Made '
  'by the sync the first time a row for it is read. The event key is what a '
  'recording of the same meeting should be given, so nobody earns it twice.';

create table if not exists public.dynamics_courses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  name_key    text generated always as (lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))) stored unique,
  counts      boolean,
  decided_by  uuid references public.people(id),
  decided_at  timestamptz,
  first_seen  timestamptz not null default now()
);

comment on table public.dynamics_courses is
  'Every ARCA training course the sync has seen. Completions earn CPD only once '
  'the office has said the course counts; until then they wait.';

alter table public.dynamics_sessions
  drop constraint if exists dynamics_sessions_course_fk;
alter table public.dynamics_sessions
  add constraint dynamics_sessions_course_fk foreign key (course_id) references public.dynamics_courses(id);

create table if not exists public.dynamics_attendance (
  id           uuid primary key default gen_random_uuid(),
  feed         text not null references public.dynamics_feeds(code),
  dynamics_id  text not null,
  session_id   uuid not null references public.dynamics_sessions(id),
  email        text,
  name         text,
  raw          jsonb not null,
  member_id    uuid references public.members(id),
  matched_by   text check (matched_by in ('email', 'link', 'office')),
  outcome      text not null default 'unmatched' check (outcome in (
                 'awarded', 'already_counted', 'before_scheme', 'not_current',
                 'unmatched', 'no_email', 'not_member',
                 'course_waiting',      -- the office has not said whether the course counts
                 'course_not_counted')),-- the office said it does not
  entry_id     uuid references public.cpd_entries(id),
  decided_by   uuid references public.people(id),
  decided_at   timestamptz,
  first_seen   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (feed, dynamics_id)
);
create index if not exists dynamics_attendance_email on public.dynamics_attendance (email) where email is not null;
create index if not exists dynamics_attendance_session on public.dynamics_attendance (session_id);

comment on table public.dynamics_attendance is
  'One row per Dynamics record, written only by dynamics_record. raw is the '
  'row exactly as Dynamics gave it, so a challenge can be answered from it.';

drop trigger if exists dynamics_attendance_updated on public.dynamics_attendance;
create trigger dynamics_attendance_updated before update on public.dynamics_attendance
  for each row execute function app.set_updated_at();

alter table public.dynamics_sessions   enable row level security;
alter table public.dynamics_courses    enable row level security;
alter table public.dynamics_attendance enable row level security;
revoke all on public.dynamics_sessions, public.dynamics_courses, public.dynamics_attendance
  from anon, authenticated;
-- Read only. Every change is a function call that decides as well as writes.
grant select on public.dynamics_sessions, public.dynamics_courses, public.dynamics_attendance
  to authenticated;

drop policy if exists dynamics_sessions_read on public.dynamics_sessions;
create policy dynamics_sessions_read on public.dynamics_sessions
  for select to authenticated using ((select app.is_membership_staff()));
drop policy if exists dynamics_courses_read on public.dynamics_courses;
create policy dynamics_courses_read on public.dynamics_courses
  for select to authenticated using ((select app.is_membership_staff()));
drop policy if exists dynamics_attendance_read on public.dynamics_attendance;
create policy dynamics_attendance_read on public.dynamics_attendance
  for select to authenticated using ((select app.is_membership_staff()));

drop trigger if exists dynamics_courses_audit on public.dynamics_courses;
create trigger dynamics_courses_audit after insert or update or delete on public.dynamics_courses
  for each row execute function app.audit_row();
drop trigger if exists dynamics_attendance_audit on public.dynamics_attendance;
create trigger dynamics_attendance_audit after insert or update or delete on public.dynamics_attendance
  for each row execute function app.audit_row();


-- -----------------------------------------------------------------------------
-- 4. Reading a value out of a row
-- -----------------------------------------------------------------------------
-- Dynamics gives a lookup or a choice as an id or a number, with the words in
-- an annotation beside it. The words are what a person would read, so they
-- win when they are there.
create or replace function app.dyn_text(p_raw jsonb, p_field text) returns text
language sql immutable set search_path = ''
as $$
  select case when p_field is null then null else
    left(coalesce(nullif(btrim(p_raw ->> (p_field || '@OData.Community.Display.V1.FormattedValue')), ''),
                  nullif(btrim(p_raw ->> p_field), '')), 300) end;
$$;

-- A date is read from the value itself, never the words, which are formatted
-- for whoever set the system up. A date and time is turned into the London
-- date it fell on: a meeting at 9am on 4 March is 4 March, whatever the clocks.
create or replace function app.dyn_date(p_raw jsonb, p_field text) returns date
language plpgsql stable set search_path = ''
as $$
declare
  v text := btrim(coalesce(p_raw ->> p_field, ''));
begin
  if p_field is null or v = '' then return null; end if;
  if v ~ '^\d{4}-\d{2}-\d{2}$' then return v::date; end if;
  return (v::timestamptz at time zone 'Europe/London')::date;
exception when others then
  return null;
end;
$$;

create or replace function app.dyn_slug(p text) returns text
language sql immutable set search_path = ''
as $$
  select left(trim(both '-' from regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '-', 'g')), 40);
$$;


-- -----------------------------------------------------------------------------
-- 5. Who is this? One answer for every feed
-- -----------------------------------------------------------------------------
-- The rule Zoom has used since 0042, taken out so Dynamics asks it the same
-- way: a remembered link first, then exactly one current membership holding
-- the address. zoom_decide is left as it was, and test 25 still holds it.
create or replace function app.feed_who(p_email text,
  out member_id uuid, out matched_by text, out outcome text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  lk  public.cpd_feed_links;
  v_n int;
begin
  if p_email is null then
    outcome := 'no_email'; return;
  end if;
  select * into lk from public.cpd_feed_links where email = p_email;
  if lk.email is not null and lk.not_member then
    outcome := 'not_member'; return;
  elsif lk.member_id is not null then
    member_id := lk.member_id; matched_by := 'link'; outcome := 'ok'; return;
  end if;
  select count(*), (array_agg(m.id))[1] into v_n, member_id
    from public.members m join public.people p on p.id = m.person_id
   where m.is_active and lower(btrim(p.email)) = p_email;
  if v_n = 1 then
    matched_by := 'email'; outcome := 'ok'; return;
  end if;
  member_id := null;
  if v_n = 0 then
    select (array_agg(m.id))[1] into member_id
      from public.members m join public.people p on p.id = m.person_id
     where lower(btrim(p.email)) = p_email;
    if member_id is not null then
      matched_by := 'email'; outcome := 'not_current'; return;
    end if;
  end if;
  outcome := 'unmatched';
end;
$$;
revoke all on function app.feed_who(text) from public;


-- -----------------------------------------------------------------------------
-- 6. Deciding one row
-- -----------------------------------------------------------------------------
create or replace function app.dynamics_decide(p_row uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a       public.dynamics_attendance;
  s       public.dynamics_sessions;
  c       public.dynamics_courses;
  w       record;
  v_mem   uuid;
  v_by    text;
  v_entry uuid;
  v_out   text;
begin
  select * into a from public.dynamics_attendance where id = p_row for update;
  select * into s from public.dynamics_sessions where id = a.session_id;

  -- WHO, exactly as for Zoom: an office decision about this one row stands;
  -- anything else is worked out again.
  if a.matched_by = 'office' then
    v_mem := a.member_id; v_by := 'office';
  elsif a.outcome = 'not_member' and a.decided_by is not null and a.email is null then
    return 'not_member';
  else
    select * into w from app.feed_who(a.email);
    if w.outcome <> 'ok' then
      update public.dynamics_attendance
         set member_id = w.member_id, matched_by = w.matched_by, outcome = w.outcome
       where id = a.id;
      return w.outcome;
    end if;
    v_mem := w.member_id; v_by := w.matched_by;
  end if;

  -- WHETHER IT COUNTS.
  if s.course_id is not null then
    select * into c from public.dynamics_courses where id = s.course_id;
  end if;
  if not exists (select 1 from public.members where id = v_mem and is_active) then
    v_out := 'not_current';
  elsif a.entry_id is not null and exists (
          select 1 from public.cpd_entries where id = a.entry_id and status <> 'rejected') then
    v_out := 'awarded';
  elsif s.held_on < app.cpd_feeds_from() then
    v_out := 'before_scheme';
  elsif c.id is not null and c.counts is null then
    v_out := 'course_waiting';
  elsif c.id is not null and not c.counts then
    v_out := 'course_not_counted';
  else
    v_entry := app.award_cpd(v_mem, s.activity_type_id, s.points, s.title, s.held_on,
                             s.id, a.id, s.event_key,
                             case when s.feed = 'arca_training'
                                  then 'ARCA''s training records show you completed it.'
                                  else 'ARCA''s records show you were there.' end);
    v_out := case when v_entry is null then 'already_counted' else 'awarded' end;
  end if;

  update public.dynamics_attendance
     set member_id = v_mem, matched_by = v_by, outcome = v_out,
         entry_id = coalesce(v_entry, entry_id)
   where id = a.id;
  return v_out;
end;
$$;
revoke all on function app.dynamics_decide(uuid) from public;


-- -----------------------------------------------------------------------------
-- 7. A run: begun, fed, finished. The Worker, as the service role
-- -----------------------------------------------------------------------------
-- The office pressing Sync now, as themselves. The Worker then begins the run
-- it was asked for, within ten minutes.
create or replace function public.dynamics_sync_request() returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_by uuid := app.person_id();
  v_id uuid;
begin
  if not app.is_membership_staff() or v_by is null then
    raise exception 'Syncing ARCA''s records is for membership staff.' using errcode = '42501';
  end if;
  if exists (select 1 from public.dynamics_runs
              where status = 'running' and started_at > now() - interval '20 minutes') then
    raise exception 'A sync is running now. Give it a minute and look at the runs.' using errcode = '22023';
  end if;
  insert into public.dynamics_runs (trigger, status, requested_by, requested_at)
  values ('office', 'requested', v_by, now())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.dynamics_sync_request() from public;
grant execute on function public.dynamics_sync_request() to authenticated;

create or replace function public.dynamics_run_begin(p_request uuid default null) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_id   uuid;
  v_req  public.dynamics_runs;
begin
  -- Serialise beginnings, so two at once cannot both decide nothing is running.
  perform pg_advisory_xact_lock(hashtext('ami.dynamics_run'));

  -- A run that never finished is not left blocking every run after it.
  update public.dynamics_runs
     set status = 'failed', finished_at = now(), error = 'Stopped without finishing.'
   where status = 'running' and started_at <= now() - interval '20 minutes';
  update public.dynamics_runs
     set status = 'skipped', finished_at = now(), error = 'Asked for, but never begun.'
   where status = 'requested' and requested_at <= now() - interval '10 minutes';

  if p_request is not null then
    select * into v_req from public.dynamics_runs where id = p_request for update;
    if v_req.id is null or v_req.status <> 'requested' then
      raise exception 'Nobody on the staff asked for this sync just now.' using errcode = '42501';
    end if;
  end if;

  if exists (select 1 from public.dynamics_runs where status = 'running') then
    if p_request is not null then
      update public.dynamics_runs set status = 'skipped', finished_at = now(),
             error = 'Another sync was running.' where id = p_request;
    end if;
    return jsonb_build_object('skip', 'A sync is running already.');
  end if;

  if p_request is not null then
    update public.dynamics_runs set status = 'running', started_at = now() where id = p_request;
    v_id := p_request;
  else
    insert into public.dynamics_runs (trigger, status, started_at)
    values ('schedule', 'running', now()) returning id into v_id;
  end if;

  return jsonb_build_object('run', v_id,
    'feeds', coalesce((select jsonb_agg(jsonb_build_object('code', f.code, 'view', f.view_name) order by f.code)
                         from public.dynamics_feeds f where f.active), '[]'::jsonb));
end;
$$;
revoke all on function public.dynamics_run_begin(uuid) from public, anon, authenticated;
grant execute on function public.dynamics_run_begin(uuid) to service_role;

-- p_meta: { entity, fields: [column names] }. p_rows: the view's rows as
-- Dynamics gave them, each with "_ami_id", the record's own id, added by the
-- Worker. Everything else is decided here.
create or replace function public.dynamics_record(p_run uuid, p_feed text, p_meta jsonb, p_rows jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  rn       public.dynamics_runs;
  f        public.dynamics_feeds;
  t        public.cpd_activity_types;
  r        jsonb;
  v_id     text;
  v_email  text;
  v_name   text;
  v_event  text;
  v_code   text;
  v_on     date;
  v_ref    text;
  v_title  text;
  v_key    text;
  v_course uuid;
  v_sess   uuid;
  v_row    uuid;
  v_old    public.dynamics_attendance;
  v_read   int := 0;
  v_bad    int := 0;
  v_touch  uuid[] := '{}';
  v_counts jsonb;
begin
  select * into rn from public.dynamics_runs where id = p_run;
  if rn.id is null or rn.status <> 'running' or rn.started_at < now() - interval '20 minutes' then
    raise exception 'That sync is not running.' using errcode = '42501';
  end if;
  select * into f from public.dynamics_feeds where code = p_feed;
  if f.code is null or not f.active then
    raise exception 'There is no such feed, or it is paused.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'The rows from Dynamics are not in the expected shape.' using errcode = '22023';
  end if;

  -- What the view holds, for the office to name the columns from. Names only.
  update public.dynamics_feeds
     set seen_entity = left(p_meta ->> 'entity', 100),
         seen_fields = coalesce((select jsonb_agg(distinct x order by x)
                                   from jsonb_array_elements_text(coalesce(p_meta -> 'fields', '[]'::jsonb)) x
                                  where x ~ '^[A-Za-z_][A-Za-z0-9_.]{0,99}$'), '[]'::jsonb),
         last_run_at = now()
   where code = f.code;

  if not app.dynamics_feed_ready(f) then
    update public.dynamics_feeds
       set last_result = jsonb_build_object('read', jsonb_array_length(p_rows), 'waiting', 'the columns are not named yet')
     where code = f.code;
    return jsonb_build_object('feed', f.code, 'read', jsonb_array_length(p_rows), 'ready', false);
  end if;

  select * into t from public.cpd_activity_types where code = f.activity_code;
  if t.id is null then
    raise exception 'The activity % is missing.', f.activity_code using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_read := v_read + 1;
    v_id    := nullif(btrim(coalesce(r ->> '_ami_id', '')), '');
    v_email := lower(btrim(coalesce(app.dyn_text(r, f.email_field), '')));
    v_email := case when v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email end;
    v_name  := app.dyn_text(r, f.name_field);
    v_event := app.dyn_text(r, f.event_field);
    v_code  := app.dyn_text(r, f.code_field);
    v_on    := app.dyn_date(r, f.date_field);
    -- A row that cannot be placed is counted and left, never guessed at.
    if v_id is null or v_on is null or (f.code <> 'arca_agm' and v_event is null) then
      v_bad := v_bad + 1;
      continue;
    end if;

    v_course := null;
    if f.code = 'arca_training' then
      insert into public.dynamics_courses (name) values (v_event)
      on conflict (name_key) do nothing;
      select id into v_course from public.dynamics_courses
       where name_key = lower(regexp_replace(btrim(v_event), '\s+', ' ', 'g'));
    end if;

    if f.code = 'arca_agm' then
      v_ref   := 'agm|' || v_on;
      v_title := 'ARCA AGM ' || extract(year from v_on);
      v_key   := 'arca-agm-' || v_on;
    else
      v_ref   := lower(coalesce(v_code, v_event)) || '|' || v_on;
      v_title := v_event;
      v_key   := case when f.code = 'arca_training' then 'arca-training-' else 'regional-meeting-' end
                 || v_on || '-' || app.dyn_slug(coalesce(v_code, v_event))
                 || '-' || left(md5(v_ref), 6);
    end if;

    insert into public.dynamics_sessions (feed, ref, title, held_on, activity_type_id, points, event_key, course_id)
    values (f.code, v_ref, v_title, v_on, t.id, coalesce(t.points, t.points_min), v_key, v_course)
    on conflict (feed, ref) do nothing;
    select id into v_sess from public.dynamics_sessions where feed = f.code and ref = v_ref;

    select * into v_old from public.dynamics_attendance where feed = f.code and dynamics_id = v_id;
    if v_old.id is null then
      insert into public.dynamics_attendance (feed, dynamics_id, session_id, email, name, raw)
      values (f.code, v_id, v_sess, v_email, v_name, r)
      returning id into v_row;
      v_touch := v_touch || v_row;
    else
      -- Every row is read again on every run. Only one Dynamics has changed is
      -- written, so the audit log holds changes and not repetition; and an
      -- award already made is never moved to another person or meeting.
      if v_old.raw is distinct from r then
        update public.dynamics_attendance
           set raw = r,
               email = case when outcome = 'awarded' then email else v_email end,
               name = v_name,
               session_id = case when outcome = 'awarded' then session_id else v_sess end
         where id = v_old.id;
      end if;
      if v_old.outcome <> 'awarded'
         and (v_old.email is distinct from v_email or v_old.session_id <> v_sess
              or v_old.outcome in ('unmatched', 'not_current', 'course_waiting', 'before_scheme')) then
        v_touch := v_touch || v_old.id;
      end if;
    end if;
  end loop;

  perform app.dynamics_decide(x) from unnest(v_touch) x;

  select jsonb_object_agg(outcome, n) into v_counts
    from (select a.outcome, count(*) as n from public.dynamics_attendance a
           where a.id = any(v_touch) group by a.outcome) c;

  update public.dynamics_feeds
     set last_result = jsonb_build_object('read', v_read, 'unreadable', v_bad,
                                          'decided', coalesce(v_counts, '{}'::jsonb))
   where code = f.code;

  return jsonb_build_object('feed', f.code, 'ready', true, 'read', v_read, 'unreadable', v_bad,
                            'decided', coalesce(v_counts, '{}'::jsonb));
end;
$$;
revoke all on function public.dynamics_record(uuid, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.dynamics_record(uuid, text, jsonb, jsonb) to service_role;

create or replace function public.dynamics_run_finish(p_run uuid, p_result jsonb, p_error text default null)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  update public.dynamics_runs
     set status = case when p_error is null then 'ok' else 'failed' end,
         finished_at = now(), result = coalesce(p_result, '{}'::jsonb), error = left(p_error, 2000)
   where id = p_run and status = 'running';
end;
$$;
revoke all on function public.dynamics_run_finish(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.dynamics_run_finish(uuid, jsonb, text) to service_role;


-- -----------------------------------------------------------------------------
-- 8. The office: courses, and the shared People to match queue
-- -----------------------------------------------------------------------------
create or replace function public.dynamics_course_decide(p_course uuid, p_counts boolean) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_by uuid := app.person_id();
  c    public.dynamics_courses;
  x    uuid;
  v_counts jsonb;
begin
  if not app.is_membership_staff() then
    raise exception 'Deciding which courses count is for membership staff.' using errcode = '42501';
  end if;
  if p_counts is null then
    raise exception 'Say whether the course counts.' using errcode = '22023';
  end if;
  select * into c from public.dynamics_courses where id = p_course;
  if c.id is null then
    raise exception 'There is no such course.' using errcode = '22023';
  end if;
  if c.counts and not p_counts and exists (
       select 1 from public.dynamics_attendance a join public.dynamics_sessions s on s.id = a.session_id
        where s.course_id = c.id and a.outcome = 'awarded') then
    raise exception 'Points have already been awarded for this course. Reject those entries in CPD to review if they should not have been.'
      using errcode = '22023';
  end if;
  update public.dynamics_courses set counts = p_counts, decided_by = v_by, decided_at = now()
   where id = c.id;
  for x in select a.id from public.dynamics_attendance a join public.dynamics_sessions s on s.id = a.session_id
            where s.course_id = c.id and a.outcome in ('course_waiting', 'course_not_counted') loop
    perform app.dynamics_decide(x);
  end loop;
  select jsonb_object_agg(outcome, n) into v_counts
    from (select a.outcome, count(*) as n from public.dynamics_attendance a
            join public.dynamics_sessions s on s.id = a.session_id
           where s.course_id = c.id group by a.outcome) q;
  return coalesce(v_counts, '{}'::jsonb);
end;
$$;
revoke all on function public.dynamics_course_decide(uuid, boolean) from public;
grant execute on function public.dynamics_course_decide(uuid, boolean) to authenticated;

-- feed_link and feed_dismiss, restated so one queue settles both feeds. For a
-- Zoom row they do exactly what 0042 did; an address linked from either feed
-- settles every row waiting on it in both.
create or replace function public.feed_link(p_row uuid, p_membership_number text)
returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a     public.zoom_attendance;
  d     public.dynamics_attendance;
  v_email text;
  v_mem uuid;
  v_by  uuid := app.person_id();
  o     record;
begin
  if not app.is_membership_staff() then
    raise exception 'Linking attendance is for membership staff.' using errcode = '42501';
  end if;
  select * into a from public.zoom_attendance where id = p_row;
  if a.id is null then
    select * into d from public.dynamics_attendance where id = p_row;
  end if;
  if a.id is null and d.id is null then
    raise exception 'There is no such attendance.' using errcode = '22023';
  end if;
  select id into v_mem from public.members
   where upper(btrim(membership_number)) = upper(btrim(coalesce(p_membership_number, '')));
  if v_mem is null then
    raise exception 'No member has the membership number %.', btrim(p_membership_number)
      using errcode = '22023';
  end if;
  v_email := coalesce(a.email, d.email);

  if v_email is not null then
    insert into public.cpd_feed_links (email, member_id, not_member, linked_by)
    values (v_email, v_mem, false, v_by)
    on conflict (email) do update
       set member_id = excluded.member_id, not_member = false,
           linked_by = excluded.linked_by, linked_at = now();
    update public.zoom_attendance
       set matched_by = null, decided_by = v_by, decided_at = now(),
           outcome = case when outcome = 'not_member' then 'unmatched' else outcome end
     where email = v_email and coalesce(matched_by, '') <> 'office';
    update public.dynamics_attendance
       set matched_by = null, decided_by = v_by, decided_at = now(),
           outcome = case when outcome = 'not_member' then 'unmatched' else outcome end
     where email = v_email and coalesce(matched_by, '') <> 'office';
    for o in select id from public.zoom_attendance
              where email = v_email and coalesce(matched_by, '') <> 'office' and id <> p_row loop
      perform app.zoom_decide(o.id);
    end loop;
    for o in select id from public.dynamics_attendance
              where email = v_email and coalesce(matched_by, '') <> 'office' and id <> p_row loop
      perform app.dynamics_decide(o.id);
    end loop;
  elsif a.id is not null then
    update public.zoom_attendance
       set member_id = v_mem, matched_by = 'office', decided_by = v_by, decided_at = now()
     where id = a.id;
  else
    update public.dynamics_attendance
       set member_id = v_mem, matched_by = 'office', decided_by = v_by, decided_at = now()
     where id = d.id;
  end if;
  return case when a.id is not null then app.zoom_decide(a.id) else app.dynamics_decide(d.id) end;
end;
$$;
revoke all on function public.feed_link(uuid, text) from public;
grant execute on function public.feed_link(uuid, text) to authenticated;

create or replace function public.feed_dismiss(p_row uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a       public.zoom_attendance;
  d       public.dynamics_attendance;
  v_email text;
  v_out   text;
  v_by    uuid := app.person_id();
begin
  if not app.is_membership_staff() then
    raise exception 'Settling attendance is for membership staff.' using errcode = '42501';
  end if;
  select * into a from public.zoom_attendance where id = p_row;
  if a.id is null then
    select * into d from public.dynamics_attendance where id = p_row;
  end if;
  if a.id is null and d.id is null then
    raise exception 'There is no such attendance.' using errcode = '22023';
  end if;
  v_out := coalesce(a.outcome, d.outcome);
  if v_out = 'awarded' then
    raise exception 'Points have already been awarded for this. Reject the entry in CPD to review if they should not have been.'
      using errcode = '22023';
  end if;
  v_email := coalesce(a.email, d.email);
  if v_email is not null then
    insert into public.cpd_feed_links (email, member_id, not_member, linked_by)
    values (v_email, null, true, v_by)
    on conflict (email) do update
       set member_id = null, not_member = true, linked_by = excluded.linked_by, linked_at = now();
  end if;
  update public.zoom_attendance
     set member_id = null, matched_by = null, outcome = 'not_member',
         decided_by = v_by, decided_at = now()
   where id = p_row
      or (v_email is not null and email = v_email and outcome in ('unmatched', 'not_member'));
  update public.dynamics_attendance
     set member_id = null, matched_by = null, outcome = 'not_member',
         decided_by = v_by, decided_at = now()
   where id = p_row
      or (v_email is not null and email = v_email and outcome in ('unmatched', 'not_member'));
  return 'not_member';
end;
$$;
revoke all on function public.feed_dismiss(uuid) from public;
grant execute on function public.feed_dismiss(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 9. What the admin app reads
-- -----------------------------------------------------------------------------
-- The queue gains ARCA's records. Columns appended at the end only, so 0042's
-- readers see what they always saw.
create or replace view public.admin_cpd_feed_queue
with (security_invoker = true) as
  select a.id, 'Zoom'::text as source, a.session_id, s.title as session, s.held_on,
         s.min_percent, s.counted_minutes,
         a.email, a.name, a.minutes, a.percent, a.outcome, a.matched_by, a.decided_at,
         a.updated_at,
         m.membership_number, p.given_name, p.family_name,
         'zoom'::text as feed
    from public.zoom_attendance a
    join public.zoom_sessions s on s.id = a.session_id
    left join public.members m on m.id = a.member_id
    left join public.people p on p.id = m.person_id
  union all
  select a.id, 'ARCA records'::text, a.session_id, s.title, s.held_on,
         null::integer, null::integer,
         a.email, a.name, null::integer, null::integer, a.outcome, a.matched_by, a.decided_at,
         a.updated_at,
         m.membership_number, p.given_name, p.family_name,
         a.feed
    from public.dynamics_attendance a
    join public.dynamics_sessions s on s.id = a.session_id
    left join public.members m on m.id = a.member_id
    left join public.people p on p.id = m.person_id;
revoke all on public.admin_cpd_feed_queue from public, anon;
grant select on public.admin_cpd_feed_queue to authenticated;

create or replace view public.admin_dynamics_sessions
with (security_invoker = true) as
  select s.id, s.feed, f.title as feed_title, s.title, s.held_on, s.points, s.event_key,
         c.name as course, c.counts as course_counts,
         count(a.id)::int as people,
         count(a.id) filter (where a.outcome = 'awarded')::int as awarded,
         count(a.id) filter (where a.outcome in ('unmatched', 'no_email'))::int as to_match,
         count(a.id) filter (where a.outcome = 'course_waiting')::int as waiting,
         count(a.id) filter (where a.outcome = 'before_scheme')::int as before_scheme,
         s.created_at
    from public.dynamics_sessions s
    join public.dynamics_feeds f on f.code = s.feed
    left join public.dynamics_courses c on c.id = s.course_id
    left join public.dynamics_attendance a on a.session_id = s.id
   group by s.id, f.title, c.name, c.counts;
revoke all on public.admin_dynamics_sessions from public, anon;
grant select on public.admin_dynamics_sessions to authenticated;

create or replace view public.admin_dynamics_courses
with (security_invoker = true) as
  select c.id, c.name, c.counts, c.first_seen, c.decided_at,
         p.given_name || ' ' || p.family_name as decided_by_name,
         count(a.id)::int as completions,
         count(a.id) filter (where a.outcome = 'course_waiting')::int as waiting,
         count(a.id) filter (where a.outcome = 'awarded')::int as awarded
    from public.dynamics_courses c
    left join public.people p on p.id = c.decided_by
    left join public.dynamics_sessions s on s.course_id = c.id
    left join public.dynamics_attendance a on a.session_id = s.id
   group by c.id, p.given_name, p.family_name;
revoke all on public.admin_dynamics_courses from public, anon;
grant select on public.admin_dynamics_courses to authenticated;

-- The monthly email's "last month you missed" (0047) gains ARCA's regional
-- meetings. Training is somebody's own course, never something everybody
-- missed, so it is not here; and the AGM is excluded by its code already.
create or replace view public.cpd_feed_sessions
with (security_invoker = true) as
  select s.event_key, s.title, s.held_on, t.code as activity_code, t.name as activity, s.points, t.is_core,
         'zoom'::text as source
    from public.zoom_sessions s
    join public.cpd_activity_types t on t.id = s.activity_type_id
  union all
  select s.event_key, s.title, s.held_on, t.code, t.name, s.points, t.is_core,
         'dynamics'::text
    from public.dynamics_sessions s
    join public.cpd_activity_types t on t.id = s.activity_type_id
   where s.feed in ('regional_meetings', 'arca_agm');
revoke all on public.cpd_feed_sessions from public, anon;
grant select on public.cpd_feed_sessions to authenticated;
