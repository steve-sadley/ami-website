-- =============================================================================
-- 0041  Read and answer, watch and answer: CPD earned on the site
--
-- The plan agreed on 30 October 2026 (claude/ami-cpd-automation-plan.md):
--
--   A piece of text to read, or a video to watch, with questions after it.
--   Marked by the database, never in the browser. 80% passes. One retake, so
--   two attempts in all. A pass puts the points straight onto the member's
--   record, once, and sends a receipt. Nobody earns one event twice, so
--   attending a seminar live and later passing its recording counts once.
--
-- Technical Reviews (0.5 to 2 points, set per item), ARCA News Updates, and the
-- recordings of AMI Seminars and ARCA regional meetings all arrive this way.
--
-- THREE THINGS THAT MUST HOLD, and the tests that hold them (file 24):
--
--   THE ANSWERS NEVER REACH A BROWSER. They live in cpd_learning_items, which
--   only editors and staff can read. Members read the item through
--   my_learning, which carries the questions and their options and NOTHING
--   that says which option is right. Marking happens in submit_learning.
--
--   A POINT IS AWARDED BY ONE FUNCTION. app.award_cpd is the only writer of
--   automatic entries, here and for Zoom and Dynamics later, so "once per
--   event" and the receipt are one rule in one place.
--
--   AN AWARD IS ATTRIBUTED. An automatic entry already had to name its rule
--   and its source (0007). It now also carries an event key, unique per member,
--   which is what makes "not twice" a constraint rather than a hope.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Automatic entries: who decided, and once per event
-- -----------------------------------------------------------------------------
-- 0007 required every accepted entry to name the PERSON who accepted it. An
-- automatic award has no person: the rule and the source are its attribution,
-- and cpd_automatic_needs_rule_and_source already insists on both.
alter table public.cpd_entries drop constraint if exists cpd_decision_is_attributed;
alter table public.cpd_entries add constraint cpd_decision_is_attributed check (
  status = 'pending'
  or (reviewed_by is not null and reviewed_at is not null)
  or (how_recorded = 'automatic' and reviewed_at is not null)
);

alter table public.cpd_entries add column if not exists event_key text;
comment on column public.cpd_entries.event_key is
  'What the points were for, as one key per event: a seminar, a regional '
  'meeting, a Technical Review. Unique per member among entries that count, so '
  'attending something and passing its recording cannot both award.';

drop index if exists public.cpd_entries_one_per_event;
create unique index cpd_entries_one_per_event
  on public.cpd_entries (member_id, event_key)
  where event_key is not null and status <> 'rejected';


-- -----------------------------------------------------------------------------
-- 2. The receipt for an award
-- -----------------------------------------------------------------------------
insert into public.email_templates (code, name, subject, html, is_service) values
(
  'cpd_awarded',
  'CPD points awarded',
  'You have earned {{points}} CPD {{point_or_points}}',
  '<p>Dear {{given_name}},</p>
   <p>You have earned <b>{{points}} {{core_or_non}} CPD {{point_or_points}}</b> for
      <b>{{title}}</b>. {{how}}</p>
   <p>For {{year}} you are now on <b>{{core_points}} of {{core_required}}</b> core points
      and <b>{{non_core_points}} of {{non_core_required}}</b> non core points.</p>
   <p>{{outstanding}}</p>
   <p>You can see your full record at any time by signing in and going to My CPD.</p>',
  true
)
on conflict (code) do nothing;

-- Two templates promised a switch that no longer exists. "You can switch it
-- off on your preferences page" became untrue at 0039 for receipts and at 0034
-- for reminders. Replaced only where the old words are still there, so a
-- template the office has already reworded is left alone.
update public.email_templates
   set html = replace(html,
     'You are getting this because you asked for a receipt
      when you log CPD. You can switch it off on your preferences page.',
     'AMI sends a note like this for every CPD entry, so your record and your inbox
      always agree.')
 where code = 'cpd_logged' and html like '%You can switch it off on your preferences page%';

update public.email_templates
   set html = replace(html,
     'You can switch these reminders off on your
      preferences page. Decisions about your own entries will still reach you.',
     'CPD is a condition of your grade, so these reminders come to every member who
      still has points to find.')
 where code = 'cpd_reminder' and html like '%You can switch these reminders off%';


-- -----------------------------------------------------------------------------
-- 3. app.award_cpd: the one writer of automatic points
-- -----------------------------------------------------------------------------
-- Returns the new entry's id, or NULL when this member already has an entry
-- for this event that counts. NULL is an answer, not an error: somebody who
-- attended live and then watched the recording has done nothing wrong.
--
-- Granted to NOBODY. Its callers are this schema's own definer functions, each
-- of which checks who is asking. A browser reaching it directly could award
-- itself anything.
create or replace function app.award_cpd(
  p_member      uuid,
  p_type        uuid,
  p_points      numeric,
  p_title       text,
  p_occurred_on date,
  p_rule        uuid,
  p_source      uuid,
  p_event_key   text,
  p_how         text default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  t    public.cpd_activity_types;
  v_id uuid;
  v_yr integer := extract(year from p_occurred_on)::int;
  m    record;
begin
  select * into t from public.cpd_activity_types where id = p_type;
  if t.id is null then
    raise exception 'award_cpd: no such activity type' using errcode = '22023';
  end if;
  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception 'award_cpd: every award needs an event key' using errcode = '22023';
  end if;

  insert into public.cpd_entries
    (member_id, year, occurred_on, activity_type_id, title, points, is_core,
     how_recorded, status, rule_id, source_id, event_key, reviewed_at)
  values
    (p_member, v_yr, p_occurred_on, t.id, p_title, p_points, t.is_core,
     'automatic', 'accepted', p_rule, p_source, p_event_key, now())
  on conflict (member_id, event_key) where event_key is not null and status <> 'rejected'
  do nothing
  returning id into v_id;

  if v_id is null then
    return null;
  end if;

  select p.id as person_id, p.given_name, p.family_name,
         lower(btrim(coalesce(p.email, ''))) as email,
         coalesce(s.core_points, 0)       as core_points,
         coalesce(s.non_core_points, 0)   as non_core_points,
         coalesce(q.core_required, 0)     as core_required,
         coalesce(q.non_core_required, 0) as non_core_required
    into m
    from public.members mm
    join public.people p on p.id = mm.person_id
    left join public.cpd_year_summaries s on s.member_id = mm.id and s.year = v_yr
    left join public.cpd_requirements q on q.grade_id = mm.grade_id and q.year = v_yr
   where mm.id = p_member;

  -- A receipt for every point earned, and members cannot refuse it (0039), so
  -- the preference is not consulted. An address missing from the record is not
  -- a reason to take the award down.
  if found and m.email <> '' then
    perform app.queue_system_email(
      'cpd_awarded', m.email, btrim(m.given_name || ' ' || m.family_name),
      jsonb_build_object(
        'given_name',        m.given_name,
        'title',             p_title,
        'points',            app.cpd_num(p_points),
        'point_or_points',   case when p_points = 1 then 'point' else 'points' end,
        'core_or_non',       case when t.is_core then 'core' else 'non core' end,
        'how',               coalesce(p_how, 'It has been added to your record automatically.'),
        'year',              v_yr::text,
        'core_points',       app.cpd_num(m.core_points),
        'non_core_points',   app.cpd_num(m.non_core_points),
        'core_required',     app.cpd_num(m.core_required),
        'non_core_required', app.cpd_num(m.non_core_required),
        'outstanding',       app.cpd_outstanding_sentence(
                               m.core_points, m.core_required,
                               m.non_core_points, m.non_core_required)),
      m.person_id, null,
      jsonb_build_object('cpd_entry_id', v_id, 'kind', 'cpd_awarded'));
  end if;

  return v_id;
end;
$$;

revoke all on function app.award_cpd(uuid, uuid, numeric, text, date, uuid, uuid, text, text) from public;


-- -----------------------------------------------------------------------------
-- 4. The items
-- -----------------------------------------------------------------------------
create table if not exists public.cpd_learning_items (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title             text not null check (length(btrim(title)) >= 3),
  kind              text not null check (kind in ('read', 'watch')),
  activity_type_id  uuid not null references public.cpd_activity_types(id),
  points            numeric(4,1) not null check (points > 0 and points <= 10),
  summary           text,
  body              text,
  vimeo_id          text check (vimeo_id is null or vimeo_id ~ '^[0-9]{6,12}$'),
  min_watch_percent integer not null default 80 check (min_watch_percent between 0 and 100),
  questions         jsonb not null default '[]'::jsonb,
  pass_mark         integer not null default 80 check (pass_mark between 1 and 100),
  max_attempts      integer not null default 2 check (max_attempts between 1 and 5),
  event_key         text,
  status            public.content_status not null default 'draft',
  published_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table public.cpd_learning_items is
  'Something to read or watch, with questions. The questions column holds the '
  'right answers and is readable by staff only; members see an item through '
  'my_learning, which leaves the answers out.';
comment on column public.cpd_learning_items.event_key is
  'Set this to the same key as the live event when the item is its recording, '
  'for example seminar-2027-03-11, so attending and watching cannot both award. '
  'Left empty, the item is its own event.';

drop trigger if exists cpd_learning_items_updated on public.cpd_learning_items;
create trigger cpd_learning_items_updated before update on public.cpd_learning_items
  for each row execute function app.set_updated_at();

-- What an item must be before it can be published, said by the database so a
-- browser that skipped the form's checks cannot publish a broken one.
create or replace function app.cpd_learning_item_rules() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  t public.cpd_activity_types;
  q jsonb;
  n int := 0;
begin
  select * into t from public.cpd_activity_types where id = new.activity_type_id;
  if t.id is null then
    raise exception 'Choose the CPD activity this counts as.' using errcode = '22023';
  end if;
  -- The value is the activity's when it has one, and within its range when it
  -- is valued item by item. A recording of a seminar is worth what the seminar is.
  if t.points is not null then
    new.points := t.points;
  elsif new.points is null then
    raise exception '% is valued item by item: set the points, between % and %.', t.name,
      app.cpd_num(t.points_min), app.cpd_num(t.points_max) using errcode = '22023';
  elsif new.points < t.points_min or new.points > t.points_max then
    raise exception '% is worth between % and % points.', t.name,
      app.cpd_num(t.points_min), app.cpd_num(t.points_max) using errcode = '22023';
  end if;

  if jsonb_typeof(new.questions) <> 'array' then
    raise exception 'The questions are not in the right shape.' using errcode = '22023';
  end if;
  for q in select * from jsonb_array_elements(new.questions) loop
    n := n + 1;
    if jsonb_typeof(q) <> 'object'
       or length(btrim(coalesce(q ->> 'q', ''))) < 3
       or jsonb_typeof(q -> 'options') <> 'array'
       or jsonb_array_length(q -> 'options') not between 2 and 6
       or jsonb_typeof(q -> 'answer') <> 'number'
       or (q ->> 'answer')::int < 0
       or (q ->> 'answer')::int >= jsonb_array_length(q -> 'options')
       or exists (select 1 from jsonb_array_elements(q -> 'options') o
                   where jsonb_typeof(o) <> 'string' or btrim(o #>> '{}') = '') then
      raise exception 'Question % needs its wording, two to six answers, and which one is right.', n
        using errcode = '22023';
    end if;
  end loop;

  if new.status = 'published' then
    if n = 0 then
      raise exception 'An item needs at least one question before it can be published.'
        using errcode = '22023';
    end if;
    if new.kind = 'read' and length(btrim(coalesce(new.body, ''))) < 20 then
      raise exception 'Something to read needs the text to read.' using errcode = '22023';
    end if;
    if new.kind = 'watch' and new.vimeo_id is null then
      raise exception 'Something to watch needs its Vimeo number.' using errcode = '22023';
    end if;
    if new.published_at is null then
      new.published_at := now();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists cpd_learning_item_rules on public.cpd_learning_items;
create trigger cpd_learning_item_rules before insert or update on public.cpd_learning_items
  for each row execute function app.cpd_learning_item_rules();

alter table public.cpd_learning_items enable row level security;
revoke all on public.cpd_learning_items from anon, authenticated;
grant select, insert, update, delete on public.cpd_learning_items to authenticated;

drop policy if exists learning_items_staff on public.cpd_learning_items;
create policy learning_items_staff on public.cpd_learning_items
  for all to authenticated
  using ((select app.is_editor()) or (select app.is_membership_staff()))
  with check ((select app.is_editor()) or (select app.is_membership_staff()));


-- -----------------------------------------------------------------------------
-- 5. Attempts
-- -----------------------------------------------------------------------------
create table if not exists public.cpd_learning_attempts (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references public.cpd_learning_items(id) on delete cascade,
  member_id   uuid not null references public.members(id),
  answers     jsonb not null,
  correct     integer not null,
  total       integer not null,
  score       integer not null check (score between 0 and 100),
  passed      boolean not null,
  entry_id    uuid references public.cpd_entries(id),
  created_at  timestamptz not null default now()
);
create index if not exists cpd_learning_attempts_member
  on public.cpd_learning_attempts (member_id, item_id);

alter table public.cpd_learning_attempts enable row level security;
revoke all on public.cpd_learning_attempts from anon, authenticated;
-- Read only, for anybody. The one writer is submit_learning, as the owner.
grant select on public.cpd_learning_attempts to authenticated;

drop policy if exists learning_attempts_read on public.cpd_learning_attempts;
create policy learning_attempts_read on public.cpd_learning_attempts
  for select to authenticated
  using (member_id = (select app.member_id())
         or (select app.is_membership_staff()) or (select app.is_editor()));


-- -----------------------------------------------------------------------------
-- 6. What a member sees: everything but the answers
-- -----------------------------------------------------------------------------
-- security_invoker OFF, deliberately: a member holds no grant that lets them
-- read cpd_learning_items, and must not, because it holds the answers. The view
-- reads as its owner and its select list IS the rule about what leaves. The
-- WHERE confines it to a signed in, current member and to published items.
create or replace view public.my_learning
with (security_invoker = false) as
select
  i.id, i.slug, i.title, i.kind, i.summary, i.body, i.vimeo_id, i.min_watch_percent,
  i.points, t.name as activity_type, t.is_core, i.pass_mark, i.max_attempts, i.published_at,
  -- The questions with their options and WITHOUT the answer. Built key by key
  -- rather than by deleting 'answer', so a key added to the stored shape later
  -- does not leak by default.
  coalesce((select jsonb_agg(jsonb_build_object('q', q -> 'q', 'options', q -> 'options')
                             order by n)
              from jsonb_array_elements(i.questions) with ordinality as x(q, n)), '[]'::jsonb)
    as questions,
  (select count(*)::int from public.cpd_learning_attempts a
    where a.item_id = i.id and a.member_id = me.id) as attempts_used,
  exists (select 1 from public.cpd_learning_attempts a
           where a.item_id = i.id and a.member_id = me.id and a.passed) as passed,
  exists (select 1 from public.cpd_entries e
           where e.member_id = me.id and e.status <> 'rejected'
             and e.event_key = coalesce(i.event_key, 'learning:' || i.id::text)) as already_counted
from public.cpd_learning_items i
join public.cpd_activity_types t on t.id = i.activity_type_id
join public.members me on me.id = (select app.member_id()) and me.is_active
where i.status = 'published' and i.published_at <= now();

revoke all on public.my_learning from public;
grant select on public.my_learning to authenticated;


-- -----------------------------------------------------------------------------
-- 7. Answering
-- -----------------------------------------------------------------------------
-- p_answers is the index chosen for each question, in order. The reply says
-- how many were right and whether that passed. It does NOT say which ones were
-- wrong or what the right answers were: with a retake to come, that would be
-- handing over the answers to the second attempt.
create or replace function public.submit_learning(p_item uuid, p_answers int[])
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member uuid := app.member_id();
  i        public.cpd_learning_items;
  t        public.cpd_activity_types;
  v_used   int;
  v_total  int;
  v_right  int := 0;
  v_score  int;
  v_pass   boolean;
  v_att    uuid;
  v_entry  uuid;
  v_key    text;
  k        int;
begin
  if v_member is null or not exists (select 1 from public.members where id = v_member and is_active) then
    raise exception 'This is for current members of AMI.' using errcode = '42501';
  end if;

  select * into i from public.cpd_learning_items
   where id = p_item and status = 'published' and published_at <= now();
  if i.id is null then
    raise exception 'That is not available.' using errcode = '22023';
  end if;

  if exists (select 1 from public.cpd_learning_attempts
              where item_id = i.id and member_id = v_member and passed) then
    raise exception 'You have already passed this one.' using errcode = '22023';
  end if;
  select count(*) into v_used from public.cpd_learning_attempts
   where item_id = i.id and member_id = v_member;
  if v_used >= i.max_attempts then
    raise exception 'You have used both attempts at this one.' using errcode = '22023';
  end if;

  v_total := jsonb_array_length(i.questions);
  if p_answers is null or coalesce(array_length(p_answers, 1), 0) <> v_total then
    raise exception 'Please answer every question.' using errcode = '22023';
  end if;
  for k in 1 .. v_total loop
    if p_answers[k] = (i.questions -> (k - 1) ->> 'answer')::int then
      v_right := v_right + 1;
    end if;
  end loop;
  v_score := floor(100.0 * v_right / v_total)::int;
  v_pass  := v_score >= i.pass_mark;

  insert into public.cpd_learning_attempts (item_id, member_id, answers, correct, total, score, passed)
  values (i.id, v_member, to_jsonb(p_answers), v_right, v_total, v_score, v_pass)
  returning id into v_att;

  if v_pass then
    select * into t from public.cpd_activity_types where id = i.activity_type_id;
    v_key := coalesce(i.event_key, 'learning:' || i.id::text);
    v_entry := app.award_cpd(v_member, i.activity_type_id, i.points, i.title, current_date,
                             i.id, v_att, v_key,
                             case i.kind when 'watch' then 'You watched it and passed its questions.'
                                         else 'You read it and passed its questions.' end);
    update public.cpd_learning_attempts set entry_id = v_entry where id = v_att;
  end if;

  return jsonb_build_object(
    'correct',         v_right,
    'total',           v_total,
    'score',           v_score,
    'passed',          v_pass,
    'pass_mark',       i.pass_mark,
    'attempts_left',   greatest(i.max_attempts - v_used - 1, 0),
    'points',          case when v_entry is not null then i.points else 0 end,
    'already_counted', v_pass and v_entry is null);
end;
$$;

revoke all on function public.submit_learning(uuid, int[]) from public;
grant execute on function public.submit_learning(uuid, int[]) to authenticated;
