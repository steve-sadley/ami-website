-- =============================================================================
-- 0049  Two email addresses, matched every time
--
-- Steve, 31 October 2026: "some use their personal email rather than company
-- email so we need to check a match against both every time we match emails."
--
-- So, on both sides:
--
--   AMI: a person may hold a second address, people.alt_email, typically the
--   personal one when the main one is the company's. Set by the office, as the
--   main address is: an address is what CPD is matched by, so a member cannot
--   add one to their own record.
--
--   Dynamics: a feed may name a second email column (dynamics_feeds.email2_field,
--   the contact's Email Address 2), and a booking carries both.
--
-- THE RULE, one function for Zoom and Dynamics alike (app.feed_who):
--   every address the attendee came with is compared with both addresses of
--   every member. A remembered link on any of the attendee's addresses wins,
--   unless two of them are linked to different members, which is for the
--   office. Otherwise it is a match only when exactly one current membership
--   holds any of the addresses. Still never a guess.
--
-- An address cannot be one person's main address and another's second one, or
-- two people's second address: a match by address only means anything if an
-- address belongs to one person.
--
-- Linking from People to match remembers every address the attendee came with,
-- and Not a member is remembered for all of them.
--
-- zoom_decide is restated to ask feed_who, so Zoom gains the second AMI address
-- too. Test 25 still holds it, unchanged.
--
-- Safe to run twice, and safe whether or not 0048 has been run before it is
-- (it must have been run: this builds on its tables).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. A second address on the person
-- -----------------------------------------------------------------------------
alter table public.people add column if not exists alt_email text;

comment on column public.people.alt_email is
  'A second address, usually the personal one when email is the company''s. '
  'Attendance from Zoom and ARCA''s records matches either. Set by the office.';

create unique index if not exists people_alt_email_lower_key on public.people (lower(alt_email))
  where alt_email is not null;

create or replace function app.people_addresses_distinct() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.alt_email := nullif(lower(btrim(coalesce(new.alt_email, ''))), '');
  if new.alt_email is not null then
    if new.alt_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception '"%" is not an email address.', new.alt_email using errcode = '22023';
    end if;
    if new.alt_email = lower(btrim(new.email)) then
      new.alt_email := null;
    elsif exists (select 1 from public.people p
                   where p.id <> new.id and lower(btrim(p.email)) = new.alt_email) then
      raise exception '% is somebody else''s main email address.', new.alt_email using errcode = '23505';
    end if;
  end if;
  if exists (select 1 from public.people p
              where p.id <> new.id and p.alt_email = lower(btrim(new.email))) then
    raise exception '% is somebody else''s second email address.', lower(btrim(new.email)) using errcode = '23505';
  end if;
  return new;
end;
$$;
revoke all on function app.people_addresses_distinct() from public;

drop trigger if exists people_addresses_distinct on public.people;
create trigger people_addresses_distinct before insert or update of email, alt_email on public.people
  for each row execute function app.people_addresses_distinct();

-- A member may not set it on their own record: restated from 0028 with
-- alt_email added to the columns only the office changes.
create or replace function app.people_own_row_column_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select app.is_staff()) then
    return new;
  end if;
  if (select app.person_id()) is distinct from new.id then
    return new;
  end if;
  if new.given_name    is distinct from old.given_name
  or new.family_name   is distinct from old.family_name
  or new.post_nominals is distinct from old.post_nominals
  or new.email         is distinct from old.email
  or new.alt_email     is distinct from old.alt_email
  or new.id            is distinct from old.id
  or new.created_at    is distinct from old.created_at then
    raise exception
      'A member may change their telephone number, their addresses and their photograph. '
      'Everything else on this record is changed by the AMI office.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function app.people_own_row_column_guard() from public;


-- -----------------------------------------------------------------------------
-- 2. A second email column from Dynamics
-- -----------------------------------------------------------------------------
alter table public.dynamics_feeds add column if not exists email2_field text;
comment on column public.dynamics_feeds.email2_field is
  'Optional. A second email column, such as the contact''s Email Address 2. Both are matched.';
grant update (email2_field) on public.dynamics_feeds to authenticated;

alter table public.dynamics_attendance add column if not exists email2 text;
create index if not exists dynamics_attendance_email2 on public.dynamics_attendance (email2) where email2 is not null;

create or replace function app.dynamics_feed_rules() returns trigger
language plpgsql security invoker set search_path = ''
as $$
declare
  f text;
begin
  foreach f in array array[new.email_field, new.email2_field, new.name_field, new.event_field,
                           new.code_field, new.date_field] loop
    if f is not null and btrim(f) <> '' and btrim(f) !~ '^[A-Za-z_][A-Za-z0-9_.]{0,99}$' then
      raise exception '"%" is not a Dynamics column name. Copy it exactly from the list the sync found.', f
        using errcode = '22023';
    end if;
  end loop;
  new.email_field  := nullif(btrim(coalesce(new.email_field, '')), '');
  new.email2_field := nullif(btrim(coalesce(new.email2_field, '')), '');
  new.name_field   := nullif(btrim(coalesce(new.name_field, '')), '');
  new.event_field  := nullif(btrim(coalesce(new.event_field, '')), '');
  new.code_field   := nullif(btrim(coalesce(new.code_field, '')), '');
  new.date_field   := nullif(btrim(coalesce(new.date_field, '')), '');
  new.view_name    := btrim(new.view_name);
  new.updated_at   := now();
  return new;
end;
$$;

drop trigger if exists dynamics_feeds_audit on public.dynamics_feeds;
create trigger dynamics_feeds_audit
  after insert or delete or update of view_name, email_field, email2_field, name_field, event_field,
                                      code_field, date_field, active
  on public.dynamics_feeds
  for each row execute function app.audit_row();


-- -----------------------------------------------------------------------------
-- 3. The rule
-- -----------------------------------------------------------------------------
create or replace function app.feed_who(p_emails text[],
  out member_id uuid, out matched_by text, out outcome text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_em   text[];
  v_link uuid[];
  v_open text[];
  v_n    int;
begin
  select coalesce(array_agg(distinct e), '{}') into v_em
    from (select lower(btrim(x)) as e from unnest(coalesce(p_emails, '{}')) x) q
   where e is not null and e <> '';
  if cardinality(v_em) = 0 then
    outcome := 'no_email'; return;
  end if;

  -- Remembered links. Two addresses linked to two different members is not
  -- something to choose between.
  select coalesce(array_agg(distinct l.member_id), '{}') into v_link
    from public.cpd_feed_links l where l.email = any(v_em) and l.member_id is not null;
  if cardinality(v_link) = 1 then
    member_id := v_link[1]; matched_by := 'link'; outcome := 'ok'; return;
  elsif cardinality(v_link) > 1 then
    outcome := 'unmatched'; return;
  end if;

  -- The addresses the office has not said are not a member's.
  select coalesce(array_agg(e), '{}') into v_open
    from unnest(v_em) e
   where not exists (select 1 from public.cpd_feed_links l where l.email = e and l.not_member);
  if cardinality(v_open) = 0 then
    outcome := 'not_member'; return;
  end if;

  select count(distinct m.id), (array_agg(distinct m.id))[1] into v_n, member_id
    from public.members m join public.people p on p.id = m.person_id
   where m.is_active
     and (lower(btrim(p.email)) = any(v_open) or p.alt_email = any(v_open));
  if v_n = 1 then
    matched_by := 'email'; outcome := 'ok'; return;
  end if;
  member_id := null;
  if v_n = 0 then
    select (array_agg(m.id))[1] into member_id
      from public.members m join public.people p on p.id = m.person_id
     where lower(btrim(p.email)) = any(v_open) or p.alt_email = any(v_open);
    if member_id is not null then
      matched_by := 'email'; outcome := 'not_current'; return;
    end if;
  end if;
  outcome := 'unmatched';
end;
$$;
revoke all on function app.feed_who(text[]) from public;

-- 0048's one address form, kept as a door to the same rule.
create or replace function app.feed_who(p_email text,
  out member_id uuid, out matched_by text, out outcome text)
language sql stable security definer set search_path = ''
as $$ select * from app.feed_who(array[p_email]); $$;
revoke all on function app.feed_who(text) from public;


-- -----------------------------------------------------------------------------
-- 4. Zoom asks the same rule
-- -----------------------------------------------------------------------------
create or replace function app.zoom_decide(p_row uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a       public.zoom_attendance;
  s       public.zoom_sessions;
  w       record;
  v_mem   uuid;
  v_by    text;
  v_entry uuid;
  v_out   text;
begin
  select * into a from public.zoom_attendance where id = p_row for update;
  select * into s from public.zoom_sessions where id = a.session_id;

  if a.matched_by = 'office' then
    v_mem := a.member_id; v_by := 'office';
  elsif a.outcome = 'not_member' and a.decided_by is not null then
    return 'not_member';
  else
    select * into w from app.feed_who(array[a.email]);
    if w.outcome <> 'ok' then
      update public.zoom_attendance
         set member_id = w.member_id, matched_by = w.matched_by, outcome = w.outcome
       where id = a.id;
      return w.outcome;
    end if;
    v_mem := w.member_id; v_by := w.matched_by;
  end if;

  if not exists (select 1 from public.members where id = v_mem and is_active) then
    v_out := 'not_current';
  elsif a.entry_id is not null and exists (
          select 1 from public.cpd_entries where id = a.entry_id and status <> 'rejected') then
    v_out := 'awarded';
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
-- 5. Dynamics: both addresses read, both matched
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

  if a.matched_by = 'office' then
    v_mem := a.member_id; v_by := 'office';
  elsif a.outcome = 'not_member' and a.decided_by is not null and a.email is null and a.email2 is null then
    return 'not_member';
  else
    select * into w from app.feed_who(array[a.email, a.email2]);
    if w.outcome <> 'ok' then
      update public.dynamics_attendance
         set member_id = w.member_id, matched_by = w.matched_by, outcome = w.outcome
       where id = a.id;
      return w.outcome;
    end if;
    v_mem := w.member_id; v_by := w.matched_by;
  end if;

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
  v_email2 text;
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
    v_id     := nullif(btrim(coalesce(r ->> '_ami_id', '')), '');
    v_email  := lower(btrim(coalesce(app.dyn_text(r, f.email_field), '')));
    v_email  := case when v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email end;
    v_email2 := lower(btrim(coalesce(app.dyn_text(r, f.email2_field), '')));
    v_email2 := case when v_email2 ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email2 end;
    -- One address held twice is one address. And the first column empty with
    -- the second filled is the second, so the queue always shows an address.
    if v_email2 = v_email then v_email2 := null; end if;
    if v_email is null then v_email := v_email2; v_email2 := null; end if;
    v_name  := app.dyn_text(r, f.name_field);
    v_event := app.dyn_text(r, f.event_field);
    v_code  := app.dyn_text(r, f.code_field);
    v_on    := app.dyn_date(r, f.date_field);
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
      insert into public.dynamics_attendance (feed, dynamics_id, session_id, email, email2, name, raw)
      values (f.code, v_id, v_sess, v_email, v_email2, v_name, r)
      returning id into v_row;
      v_touch := v_touch || v_row;
    else
      if v_old.raw is distinct from r or v_old.email2 is distinct from v_email2 then
        update public.dynamics_attendance
           set raw = r,
               email  = case when outcome = 'awarded' then email  else v_email  end,
               email2 = case when outcome = 'awarded' then email2 else v_email2 end,
               name = v_name,
               session_id = case when outcome = 'awarded' then session_id else v_sess end
         where id = v_old.id;
      end if;
      if v_old.outcome <> 'awarded'
         and (v_old.email is distinct from v_email or v_old.email2 is distinct from v_email2
              or v_old.session_id <> v_sess
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


-- -----------------------------------------------------------------------------
-- 6. The office: every address remembered at once
-- -----------------------------------------------------------------------------
create or replace function public.feed_link(p_row uuid, p_membership_number text)
returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a     public.zoom_attendance;
  d     public.dynamics_attendance;
  v_em  text[];
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
  select coalesce(array_agg(e), '{}') into v_em
    from unnest(array[a.email, d.email, d.email2]) e where e is not null;

  if cardinality(v_em) > 0 then
    insert into public.cpd_feed_links (email, member_id, not_member, linked_by)
    select e, v_mem, false, v_by from unnest(v_em) e
    on conflict (email) do update
       set member_id = excluded.member_id, not_member = false,
           linked_by = excluded.linked_by, linked_at = now();
    update public.zoom_attendance
       set matched_by = null, decided_by = v_by, decided_at = now(),
           outcome = case when outcome = 'not_member' then 'unmatched' else outcome end
     where email = any(v_em) and coalesce(matched_by, '') <> 'office';
    update public.dynamics_attendance
       set matched_by = null, decided_by = v_by, decided_at = now(),
           outcome = case when outcome = 'not_member' then 'unmatched' else outcome end
     where (email = any(v_em) or email2 = any(v_em)) and coalesce(matched_by, '') <> 'office';
    for o in select id from public.zoom_attendance
              where email = any(v_em) and coalesce(matched_by, '') <> 'office' and id <> p_row loop
      perform app.zoom_decide(o.id);
    end loop;
    for o in select id from public.dynamics_attendance
              where (email = any(v_em) or email2 = any(v_em))
                and coalesce(matched_by, '') <> 'office' and id <> p_row loop
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
  a     public.zoom_attendance;
  d     public.dynamics_attendance;
  v_em  text[];
  v_by  uuid := app.person_id();
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
  if coalesce(a.outcome, d.outcome) = 'awarded' then
    raise exception 'Points have already been awarded for this. Reject the entry in CPD to review if they should not have been.'
      using errcode = '22023';
  end if;
  select coalesce(array_agg(e), '{}') into v_em
    from unnest(array[a.email, d.email, d.email2]) e where e is not null;
  insert into public.cpd_feed_links (email, member_id, not_member, linked_by)
  select e, null, true, v_by from unnest(v_em) e
  on conflict (email) do update
     set member_id = null, not_member = true, linked_by = excluded.linked_by, linked_at = now();
  update public.zoom_attendance
     set member_id = null, matched_by = null, outcome = 'not_member',
         decided_by = v_by, decided_at = now()
   where id = p_row
      or (email = any(v_em) and outcome in ('unmatched', 'not_member'));
  update public.dynamics_attendance
     set member_id = null, matched_by = null, outcome = 'not_member',
         decided_by = v_by, decided_at = now()
   where id = p_row
      or ((email = any(v_em) or email2 = any(v_em)) and outcome in ('unmatched', 'not_member'));
  return 'not_member';
end;
$$;
revoke all on function public.feed_dismiss(uuid) from public;
grant execute on function public.feed_dismiss(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 7. The queue shows the second address
-- -----------------------------------------------------------------------------
create or replace view public.admin_cpd_feed_queue
with (security_invoker = true) as
  select a.id, 'Zoom'::text as source, a.session_id, s.title as session, s.held_on,
         s.min_percent, s.counted_minutes,
         a.email, a.name, a.minutes, a.percent, a.outcome, a.matched_by, a.decided_at,
         a.updated_at,
         m.membership_number, p.given_name, p.family_name,
         'zoom'::text as feed, null::text as email2
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
         a.feed, a.email2
    from public.dynamics_attendance a
    join public.dynamics_sessions s on s.id = a.session_id
    left join public.members m on m.id = a.member_id
    left join public.people p on p.id = m.person_id;
revoke all on public.admin_cpd_feed_queue from public, anon;
grant select on public.admin_cpd_feed_queue to authenticated;
