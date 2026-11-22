-- =============================================================================
-- 0053  Keep only what can be about a member
--
-- Steve, 31 October, on seeing nearly 5,000 of ARCA's contacts in People to
-- match: "if it can't match on an email address and the name is not similar
-- to an existing member then it is ignored; the only ones to match are those
-- that have a name similar to an existing member."
--
-- So a row read from Dynamics is stored only when:
--   either of its emails matches either of a member's (as 0049), or
--   a CURRENT member has the same surname and the same first initial
--     ("J Sheldon" and John Sheldon), shown in People to match with the
--     member named, for the office to link or dismiss.
-- Anybody else is read, counted as not kept, and not stored. The next sync
-- reads them again, so a person who becomes a member, or a member whose second
-- email is added, is picked up then.
--
-- Same surname and first initial rather than a looser likeness: it can be
-- explained in a sentence, and a fuzzy match on names would offer the office
-- hundreds of near misses.
--
-- The change history no longer records what the sync reads in, only changes
-- to a row, so a non-member's details are never kept there either. What staging
-- already holds for people who fit neither rule is removed, history included.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Names
-- -----------------------------------------------------------------------------
-- Letters only, lower case: "O'Brien", "o brien" and "OBrien" are one surname.
create or replace function app.name_key(p text) returns text
language sql immutable set search_path = ''
as $$ select nullif(regexp_replace(lower(coalesce(p, '')), '[^a-z]', '', 'g'), ''); $$;

-- A full name as Dynamics holds it, split into first initial and surname,
-- leaving out a title in front.
create or replace function app.name_parts(p_full text, out initial text, out surname text)
language plpgsql immutable set search_path = ''
as $$
declare
  w text[];
begin
  w := regexp_split_to_array(btrim(regexp_replace(coalesce(p_full, ''), '\s+', ' ', 'g')), ' ');
  if cardinality(w) > 1 and lower(regexp_replace(w[1], '[^A-Za-z]', '', 'g'))
       in ('mr', 'mrs', 'ms', 'miss', 'mx', 'dr', 'prof', 'sir') then
    w := w[2:];
  end if;
  if cardinality(w) < 2 then return; end if;
  initial := left(app.name_key(w[1]), 1);
  surname := app.name_key(w[cardinality(w)]);
end;
$$;

create or replace function app.dyn_name_candidates(p_full text) returns uuid[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(m.id order by m.membership_number), '{}')
    from app.name_parts(p_full) n
    join public.people p on app.name_key(p.family_name) = n.surname
                        and left(app.name_key(p.given_name), 1) = n.initial
    join public.members m on m.person_id = p.id and m.is_active
   where n.surname is not null and n.initial is not null;
$$;
revoke all on function app.dyn_name_candidates(text) from public;

create or replace function app.dyn_name_candidates_text(p_full text) returns text
language sql stable security definer set search_path = ''
as $$
  select string_agg(p.given_name || ' ' || p.family_name || ' (' || m.membership_number || ')', ', '
                    order by m.membership_number)
    from unnest(app.dyn_name_candidates(p_full)) c
    join public.members m on m.id = c
    join public.people p on p.id = m.person_id;
$$;
revoke all on function app.dyn_name_candidates_text(text) from public;
grant execute on function app.dyn_name_candidates_text(text) to authenticated;


-- -----------------------------------------------------------------------------
-- 2. Reading: dynamics_record restated from 0052, with the rule above
-- -----------------------------------------------------------------------------
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
  v_all    uuid[] := '{}';
  v_skip   int := 0;
  w        record;
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

    -- Kept only if it can be about a member: an email that matches, or a name
    -- like a current member's. Anybody else is not stored (0053). A row the
    -- office has already decided about is always kept.
    if v_old.id is null or (v_old.matched_by is distinct from 'office' and v_old.decided_by is null
                            and v_old.outcome <> 'awarded') then
      select * into w from app.feed_who(array[v_email, v_email2]);
      if w.outcome in ('unmatched', 'no_email') and cardinality(app.dyn_name_candidates(v_name)) = 0 then
        if v_old.id is not null then
          delete from public.dynamics_attendance where id = v_old.id;
        end if;
        v_skip := v_skip + 1;
        continue;
      end if;
    end if;
    if v_old.id is null then
      insert into public.dynamics_attendance (feed, dynamics_id, session_id, email, email2, name, raw)
      values (f.code, v_id, v_sess, v_email, v_email2, v_name, r)
      returning id into v_row;
      v_touch := v_touch || v_row;
      v_all := v_all || v_row;
    else
      v_all := v_all || v_old.id;
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
           where a.id = any(v_all) group by a.outcome) c;

  update public.dynamics_feeds
     set last_result = jsonb_build_object('read', v_read, 'unreadable', v_bad,
                                          'decided', coalesce(v_counts, '{}'::jsonb) || jsonb_build_object('not_kept', v_skip))
   where code = f.code;

  return jsonb_build_object('feed', f.code, 'ready', true, 'read', v_read, 'unreadable', v_bad,
                            'decided', coalesce(v_counts, '{}'::jsonb) || jsonb_build_object('not_kept', v_skip));
end;
$$;
revoke all on function public.dynamics_record(uuid, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.dynamics_record(uuid, text, jsonb, jsonb) to service_role;


-- -----------------------------------------------------------------------------
-- 3. The change history records changes, not what the sync reads in
-- -----------------------------------------------------------------------------
drop trigger if exists dynamics_attendance_audit on public.dynamics_attendance;
create trigger dynamics_attendance_audit after update or delete on public.dynamics_attendance
  for each row execute function app.audit_row();


-- -----------------------------------------------------------------------------
-- 4. What is already held for people who fit neither rule
-- -----------------------------------------------------------------------------
-- Removed without recording each removal (the record would hold the very
-- details being removed), and the sync's earlier entries for them go too. The
-- history is append only by design; this is the one place it is opened, for
-- this table and these rows only, and closed again in the same breath.
drop table if exists pg_temp.dyn_gone;
create temporary table dyn_gone as
  select a.id::text as id from public.dynamics_attendance a
   where a.outcome in ('unmatched', 'no_email')
     and a.matched_by is distinct from 'office' and a.decided_by is null
     and cardinality(app.dyn_name_candidates(a.name)) = 0
     and (app.feed_who(array[a.email, a.email2])).outcome in ('unmatched', 'no_email');

alter table public.dynamics_attendance disable trigger dynamics_attendance_audit;
delete from public.dynamics_attendance where id::text in (select id from dyn_gone);
alter table public.dynamics_attendance enable trigger dynamics_attendance_audit;

alter table public.audit_log disable trigger audit_log_append_only;
delete from public.audit_log
 where table_name = 'dynamics_attendance'
   and (row_id in (select id from dyn_gone)
        or (action = 'INSERT' and row_id not in (select id::text from public.dynamics_attendance)));
alter table public.audit_log enable trigger audit_log_append_only;
drop table if exists pg_temp.dyn_gone;


-- -----------------------------------------------------------------------------
-- 5. The queue names the possible member
-- -----------------------------------------------------------------------------
create or replace view public.admin_cpd_feed_queue
with (security_invoker = true) as
  select a.id, 'Zoom'::text as source, a.session_id, s.title as session, s.held_on,
         s.min_percent, s.counted_minutes,
         a.email, a.name, a.minutes, a.percent, a.outcome, a.matched_by, a.decided_at,
         a.updated_at,
         m.membership_number, p.given_name, p.family_name,
         'zoom'::text as feed, null::text as email2, null::text as possible
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
         a.feed, a.email2,
         case when a.outcome in ('unmatched', 'no_email') then app.dyn_name_candidates_text(a.name) end
    from public.dynamics_attendance a
    join public.dynamics_sessions s on s.id = a.session_id
    left join public.members m on m.id = a.member_id
    left join public.people p on p.id = m.person_id;
revoke all on public.admin_cpd_feed_queue from public, anon;
grant select on public.admin_cpd_feed_queue to authenticated;
