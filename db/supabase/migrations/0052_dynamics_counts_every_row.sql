-- =============================================================================
-- 0052  What a sync reports is where every row it read stands
--
-- Found on staging, 31 October: the AGM read 337 rows and reported "307 not
-- matched", which read as though 30 had been matched. They had not: the 30
-- had no email, and only rows decided afresh were being counted. Now every row
-- read is counted by where it stands, whether or not it was decided again.
-- dynamics_record is restated from 0049 with that one change.
--
-- Safe to run twice.
-- =============================================================================

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
                                          'decided', coalesce(v_counts, '{}'::jsonb))
   where code = f.code;

  return jsonb_build_object('feed', f.code, 'ready', true, 'read', v_read, 'unreadable', v_bad,
                            'decided', coalesce(v_counts, '{}'::jsonb));
end;
$$;
revoke all on function public.dynamics_record(uuid, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.dynamics_record(uuid, text, jsonb, jsonb) to service_role;
