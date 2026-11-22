-- =============================================================================
-- 0047  The monthly CPD email
--
-- The plan agreed on 30 October 2026 (claude/ami-cpd-automation-plan.md), item 6:
--
--   First working day of each month, to members of grades that require CPD
--   only, and members cannot switch it off. It replaces the monthly reminder
--   rather than adding a second email. It says:
--     where the member stands this year, core and non core
--     the AMI webinars and ARCA regional meetings held last month that they
--       did not attend, each with a link to its recording and questions
--       where there is one
--     the ARCA AGM is NOT listed as missed, but the email says that attending
--       it earns CPD points
--     where on the site they can earn the points they still need
--
-- HOW IT RUNS. A pg_cron job calls app.queue_cpd_monthly() every morning. It
-- does nothing unless today is the first working day of the month: a weekday
-- that is not in non_working_days, with no earlier such day this month. The
-- office keeps that table (bank holidays for 2026 to 2028 are in it). So 1
-- January 2027, a Friday and a bank holiday, sends nothing, and Monday 4
-- January sends. cpd_monthly_log is written BEFORE each letter and the letter
-- depends on the insert, exactly as 0029 did, so a second run the same month
-- sends nobody anything twice.
--
-- THE OLD REMINDER IS NOT SCHEDULED, and must not be. app.queue_cpd_reminders
-- (0029, 0034) is left as it was, with its tests, because nothing calls it:
-- schedule this, not that.
--
-- Staging reaches only the addresses in bulletin_allow, as the bulletins and
-- the digest do, and counts the rest as withheld.
--
-- "Missed" covers sessions from Zoom today; ARCA's regional meetings join when
-- the Dynamics feeds are built (item 5), through cpd_feed_sessions below.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Working days
-- -----------------------------------------------------------------------------
create table if not exists public.non_working_days (
  id    uuid primary key default gen_random_uuid(),
  day   date not null unique,
  name  text not null check (length(btrim(name)) >= 2)
);
comment on table public.non_working_days is
  'Bank holidays and office closures. The monthly CPD email goes on the first '
  'weekday of the month that is not in here. Add next year''s each autumn.';

alter table public.non_working_days enable row level security;
revoke all on public.non_working_days from anon, authenticated;
grant select, insert, update, delete on public.non_working_days to authenticated;
drop policy if exists non_working_days_staff on public.non_working_days;
create policy non_working_days_staff on public.non_working_days
  for all to authenticated
  using ((select app.is_membership_staff())) with check ((select app.is_membership_staff()));

-- England and Wales, from gov.uk's published lists.
insert into public.non_working_days (day, name) values
  ('2026-12-25', 'Christmas Day'), ('2026-12-28', 'Boxing Day (substitute day)'),
  ('2027-01-01', 'New Year''s Day'), ('2027-03-26', 'Good Friday'), ('2027-03-29', 'Easter Monday'),
  ('2027-05-03', 'Early May bank holiday'), ('2027-05-31', 'Spring bank holiday'),
  ('2027-08-30', 'Summer bank holiday'), ('2027-12-27', 'Christmas Day (substitute day)'),
  ('2027-12-28', 'Boxing Day (substitute day)'),
  ('2028-01-03', 'New Year''s Day (substitute day)'), ('2028-04-14', 'Good Friday'),
  ('2028-04-17', 'Easter Monday'), ('2028-05-01', 'Early May bank holiday'),
  ('2028-05-29', 'Spring bank holiday'), ('2028-08-28', 'Summer bank holiday'),
  ('2028-12-25', 'Christmas Day'), ('2028-12-26', 'Boxing Day')
on conflict (day) do nothing;

create or replace function app.is_working_day(p_day date) returns boolean
language sql stable security definer set search_path = ''
as $$
  select extract(isodow from p_day) < 6
     and not exists (select 1 from public.non_working_days where day = p_day);
$$;

create or replace function app.first_working_day(p_month date) returns date
language sql stable security definer set search_path = ''
as $$
  select min(d)::date from generate_series(date_trunc('month', p_month)::date,
                                           (date_trunc('month', p_month) + interval '14 days')::date,
                                           interval '1 day') d
   where app.is_working_day(d::date);
$$;


-- -----------------------------------------------------------------------------
-- 2. Sessions a member could have attended
-- -----------------------------------------------------------------------------
-- One place that says "this event happened, on this day, and earns CPD by
-- attending". Zoom now; Dynamics regional meetings are added here at item 5.
-- The ARCA AGM is never listed as missed, by its activity code.
create or replace view public.cpd_feed_sessions
with (security_invoker = true) as
  select s.event_key, s.title, s.held_on, t.code as activity_code, t.name as activity, s.points, t.is_core,
         'zoom'::text as source
    from public.zoom_sessions s
    join public.cpd_activity_types t on t.id = s.activity_type_id;
revoke all on public.cpd_feed_sessions from public, anon;
grant select on public.cpd_feed_sessions to authenticated;


-- -----------------------------------------------------------------------------
-- 3. The template, worded for the office to change
-- -----------------------------------------------------------------------------
-- The two lists are built here, escaped, and put where the markers stand.
-- The markers are HTML comments, which a member's name cannot become: values
-- are escaped before they go in, so "<!--" in a name arrives as "&lt;!--".
insert into public.email_templates (code, name, subject, html, is_service) values
(
  'cpd_monthly',
  'Monthly CPD summary',
  'Your CPD for {{year}}: where you stand in {{month_name}}',
  '<p>Dear {{given_name}},</p>
   <p>Here is where your CPD stands for {{year}}.</p>
   <table cellpadding="0" cellspacing="0" style="margin:0 0 16px;font-size:15px">
     <tr><td style="padding:4px 24px 4px 0">Core</td><td><b>{{core_points}} of {{core_required}}</b> points</td></tr>
     <tr><td style="padding:4px 24px 4px 0">Non core</td><td><b>{{non_core_points}} of {{non_core_required}}</b> points</td></tr>
   </table>
   <p>{{outstanding}}</p>
   <!--missed-->
   <!--earn-->
   <p>Attending the ARCA AGM also earns CPD points, and they arrive on your record on their own.</p>
   <p>You can see your full record at any time by signing in and going to My CPD.</p>
   <p style="font-size:13px;color:#888">CPD is a condition of your grade, so this summary comes on the first
      working day of every month to every member whose grade requires CPD.</p>',
  true
)
on conflict (code) do nothing;


-- -----------------------------------------------------------------------------
-- 4. Building one member's email
-- -----------------------------------------------------------------------------
create or replace function app.cpd_monthly_parts(p_member uuid, p_on date default current_date)
returns table (subject text, html text, to_email text, to_name text, person_id uuid, missed int, to_earn int)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_year   int := extract(year from p_on)::int;
  v_from   date := (date_trunc('month', p_on) - interval '1 month')::date;
  v_to     date := (date_trunc('month', p_on) - interval '1 day')::date;
  v_site   text := rtrim(app.setting('site_url'), '/');
  m        record;
  t        public.email_templates;
  rr       record;
  v_missed text := '';
  v_earn   text := '';
  n_missed int := 0;
  n_earn   int := 0;
  x        record;
begin
  select p.id as person_id, p.given_name, p.family_name, lower(btrim(coalesce(p.email, ''))) as email,
         coalesce(s.core_points, 0) as core_points, coalesce(s.non_core_points, 0) as non_core_points,
         coalesce(q.core_required, 0) as core_required, coalesce(q.non_core_required, 0) as non_core_required
    into m
    from public.members mm
    join public.people p on p.id = mm.person_id
    left join public.cpd_year_summaries s on s.member_id = mm.id and s.year = v_year
    left join public.cpd_requirements q on q.grade_id = mm.grade_id and q.year = v_year
   where mm.id = p_member;
  if not found then return; end if;

  -- What they missed last month: sessions that count, held since the scheme
  -- began, not the ARCA AGM, with no entry of theirs for that event.
  for x in
    select fs.event_key, fs.title, fs.held_on, fs.points,
           (select li.id from public.cpd_learning_items li
             where li.event_key = fs.event_key and li.status = 'published' and li.published_at <= now()
             limit 1) as recording
      from public.cpd_feed_sessions fs
     where fs.held_on between v_from and v_to
       and fs.held_on >= app.cpd_feeds_from()
       and fs.activity_code <> 'arca_agm'
       and not exists (select 1 from public.cpd_entries e
                        where e.member_id = p_member and e.event_key = fs.event_key and e.status <> 'rejected')
     order by fs.held_on
  loop
    n_missed := n_missed + 1;
    v_missed := v_missed || '<li style="margin:0 0 8px"><b>' || app.html_escape(x.title) || '</b>, '
      || to_char(x.held_on, 'FMDD Month YYYY') || '. '
      || case when x.recording is not null
              then '<a href="' || app.html_escape(v_site || '/learn') || '">Watch the recording and answer its questions</a> to earn the '
                   || app.cpd_num(x.points) || case when x.points = 1 then ' point' else ' points' end || '.'
              else 'The recording is not online yet.' end
      || '</li>';
  end loop;
  if n_missed > 0 then
    v_missed := '<p><b>Last month you missed</b></p><ul style="padding-left:20px;margin:0 0 16px">'
                || v_missed || '</ul>';
  end if;

  -- Where to earn what they still need: published read and watch items they
  -- have not passed and whose event is not already on their record.
  for x in
    select li.title, li.points, t2.is_core
      from public.cpd_learning_items li
      join public.cpd_activity_types t2 on t2.id = li.activity_type_id
     where li.status = 'published' and li.published_at <= now()
       and not exists (select 1 from public.cpd_learning_attempts a
                        where a.item_id = li.id and a.member_id = p_member and a.passed)
       and not exists (select 1 from public.cpd_entries e
                        where e.member_id = p_member and e.status <> 'rejected'
                          and e.event_key = coalesce(li.event_key, 'learning:' || li.id::text))
     order by li.published_at desc
     limit 5
  loop
    n_earn := n_earn + 1;
    v_earn := v_earn || '<li style="margin:0 0 6px">' || app.html_escape(x.title) || ', '
      || app.cpd_num(x.points) || case when x.points = 1 then ' point' else ' points' end
      || case when x.is_core then ' core' else ' non core' end || '</li>';
  end loop;
  if n_earn > 0 or m.core_points < m.core_required or m.non_core_points < m.non_core_required then
    v_earn := '<p><b>Earning points on the AMI site</b></p>'
      || case when n_earn > 0
              then '<p>Ready to read or watch now, each with a few questions:</p><ul style="padding-left:20px;margin:0 0 10px">'
                   || v_earn || '</ul>' else '' end
      || '<p><a href="' || app.html_escape(v_site || '/learn') || '">Earn CPD on the site</a>, or '
      || '<a href="' || app.html_escape(v_site || '/cpd') || '">log an activity</a> you have done elsewhere.</p>';
  else
    v_earn := '';
  end if;

  select * into t from public.email_templates where code = 'cpd_monthly';
  select * into rr from app.render_parts(t.subject, t.html, jsonb_build_object(
    'given_name',        m.given_name,
    'year',              v_year::text,
    'month_name',        to_char(p_on, 'FMMonth'),
    'core_points',       app.cpd_num(m.core_points),
    'non_core_points',   app.cpd_num(m.non_core_points),
    'core_required',     app.cpd_num(m.core_required),
    'non_core_required', app.cpd_num(m.non_core_required),
    'outstanding',       app.cpd_outstanding_sentence(m.core_points, m.core_required,
                                                      m.non_core_points, m.non_core_required)));

  subject  := rr.subject;
  html     := replace(replace(rr.html, '<!--missed-->', v_missed), '<!--earn-->', v_earn);
  to_email := m.email;
  to_name  := btrim(m.given_name || ' ' || m.family_name);
  person_id := m.person_id;
  missed   := n_missed;
  to_earn  := n_earn;
  return next;
end;
$$;
revoke all on function app.cpd_monthly_parts(uuid, date) from public;


-- -----------------------------------------------------------------------------
-- 5. Sending it
-- -----------------------------------------------------------------------------
create table if not exists public.cpd_monthly_log (
  member_id  uuid not null references public.members(id) on delete cascade,
  year       int  not null,
  month      int  not null check (month between 1 and 12),
  outcome    text not null default 'queued' check (outcome in ('queued', 'withheld')),
  created_at timestamptz not null default now(),
  primary key (member_id, year, month)
);
alter table public.cpd_monthly_log enable row level security;
revoke all on public.cpd_monthly_log from anon, authenticated;
grant select on public.cpd_monthly_log to authenticated;
drop policy if exists cpd_monthly_log_staff on public.cpd_monthly_log;
create policy cpd_monthly_log_staff on public.cpd_monthly_log
  for select to authenticated using ((select app.is_membership_staff()));

-- Returns how many were queued and how many staging held back. p_force skips
-- the first working day test, for a first test on staging; it does NOT skip
-- once a month.
create or replace function app.queue_cpd_monthly(p_on date default current_date, p_force boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_year     int := extract(year from p_on)::int;
  v_month    int := extract(month from p_on)::int;
  v_env      text := app.setting('environment');
  v_allow    text[] := array(select lower(btrim(x)) from unnest(string_to_array(app.setting('bulletin_allow'), ',')) x
                             where btrim(x) <> '');
  v_queued   int := 0;
  v_withheld int := 0;
  r          record;
  pp         record;
begin
  if not p_force and p_on is distinct from app.first_working_day(p_on) then
    return jsonb_build_object('sent', false, 'reason', 'not the first working day of the month',
                              'first_working_day', app.first_working_day(p_on));
  end if;

  for r in
    select m.id as member_id, lower(btrim(coalesce(p.email, ''))) as email
      from public.members m
      join public.people p on p.id = m.person_id
      join public.membership_grades g on g.id = m.grade_id
      join public.cpd_requirements q on q.grade_id = g.id and q.year = v_year
     where m.is_active
       and g.requires_cpd
       and (q.core_required > 0 or q.non_core_required > 0)
       and coalesce(p.email, '') <> ''
  loop
    -- The log row FIRST, and the letter depends on it having gone in.
    insert into public.cpd_monthly_log (member_id, year, month, outcome)
    values (r.member_id, v_year, v_month,
            case when v_env <> 'live' and not (r.email = any (v_allow)) then 'withheld' else 'queued' end)
    on conflict do nothing;
    continue when not found;

    if v_env <> 'live' and not (r.email = any (v_allow)) then
      v_withheld := v_withheld + 1;
      continue;
    end if;

    select * into pp from app.cpd_monthly_parts(r.member_id, p_on);
    perform app.queue_message('cpd_monthly', pp.subject, pp.html, pp.to_email, pp.to_name, pp.person_id,
      null, jsonb_build_object('kind', 'cpd_monthly', 'year', v_year, 'month', v_month,
                               'missed', pp.missed, 'to_earn', pp.to_earn));
    v_queued := v_queued + 1;
  end loop;

  return jsonb_build_object('sent', true, 'queued', v_queued, 'withheld', v_withheld);
end;
$$;
revoke all on function app.queue_cpd_monthly(date, boolean) from public;

comment on function app.queue_cpd_monthly(date, boolean) is
  'The monthly CPD email. Schedule it every morning; it sends only on the first '
  'working day. It replaces app.queue_cpd_reminders, which must not be scheduled.';

-- What the office sees before anything goes: one member's email as it would
-- be today. Membership staff only.
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
  return jsonb_build_object('subject', pp.subject, 'html', pp.html, 'to', pp.to_email,
    'missed', pp.missed, 'to_earn', pp.to_earn,
    'next', app.first_working_day((date_trunc('month', current_date) + interval '1 month')::date));
end;
$$;
revoke all on function public.cpd_monthly_preview(uuid) from public;
grant execute on function public.cpd_monthly_preview(uuid) to authenticated;
