-- =============================================================================
-- 0038  The CPD scheme for 2027: points from the activity, and reflections
--
-- From the website meeting of 30 October 2026 and the scheme table agreed the
-- same evening (AMI_CPD_Proposal.docx). The new scheme starts on 1 January 2027.
--
-- WHAT CHANGES
--
--   1. An activity type carries its own value. A member no longer types in the
--      points they are claiming: they choose what they did and the database
--      says what it is worth. That is what Reena's CIM portal does, and it is
--      also the end of the one figure on a CPD entry the member chose.
--
--   2. Some activities need a written reflection with a minimum word count, 500
--      for a reflection following a training course. Counted here as well as in
--      the browser, because the browser is the member's.
--
--   3. Some activities cannot be logged by a member at all, because they arrive
--      another way: AMI events and seminars from attendance, ARCA meetings and
--      training from Dynamics, Technical Reviews and ARCA News from questions on
--      the site. Logging one by hand would be a second route to the same points.
--
--   4. Practice of Management is declared once a year.
--
--   5. The fourteen activity types seeded in August are switched off, not
--      deleted, because entries already logged against them on staging point at
--      them. The thirteen in the agreed table replace them.
--
--   6. CPD receipts default ON. Steve, 30 October: "an email sent every time a
--      CPD point is earned". 0029 made the receipt opt in; there are no real
--      members yet, so every existing preference row is switched on as well.
--
-- Every figure here is editable by the office on the CPD activity types screen.
-- Nothing below is a constant somebody has to find in code.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. What an activity type now knows about itself
-- -----------------------------------------------------------------------------
alter table public.cpd_activity_types
  add column if not exists points          numeric(4,1),
  add column if not exists points_min      numeric(4,1),
  add column if not exists points_max      numeric(4,1),
  add column if not exists min_words       integer not null default 0,
  add column if not exists member_can_log  boolean not null default true,
  add column if not exists once_per_year   boolean not null default false,
  add column if not exists needs_evidence  boolean not null default false,
  add column if not exists guidance        text;

comment on column public.cpd_activity_types.points is
  'What one of these is worth. Null when the value is set item by item, as a '
  'Technical Review is: then points_min and points_max bound it.';
comment on column public.cpd_activity_types.min_words is
  'Words a member must write in the reflection before it can be sent. 0 means '
  'no reflection is asked for.';
comment on column public.cpd_activity_types.member_can_log is
  'False for anything that arrives by another route: attendance, Dynamics, or '
  'questions passed on the site. A member cannot log those by hand.';
comment on column public.cpd_activity_types.guidance is
  'One or two sentences shown to the member when they choose this activity.';

-- THE AUGUST TYPES GO OFF BEFORE THE RULE GOES ON. The first version of this
-- file added the constraint first and switched them off later, which failed on
-- staging with "violated by some row": the fourteen were active and valueless at
-- the moment the rule arrived. The mirror passed, because there the starting
-- lists are seeded AFTER the migrations, so the table was empty when the rule
-- arrived. The same shape as the seed that once repaired a migration: the
-- mirror running things in a different order from the real database.
--
-- Anything else switched on with no value, a type the office added, is switched
-- off too and NAMED, rather than left to fail the migration. Its entries are
-- untouched; give it a value on the CPD activity types screen and switch it
-- back on.
do $$
declare v text;
begin
  update public.cpd_activity_types set active = false
   where code in ('course_assessed','course_unassessed','seminar','webinar','reading_technical',
                  'site_learning','assessment_passed','regional_meeting','committee','mentoring',
                  'writing_presenting','reading_general','soft_skills','briefing_delivered');
  select string_agg(code, ', ') into v from public.cpd_activity_types
   where active and points is null and points_min is null;
  if v is not null then
    update public.cpd_activity_types set active = false
     where active and points is null and points_min is null;
    raise notice 'Switched off because they have no value yet: %', v;
  end if;
end $$;

alter table public.cpd_activity_types drop constraint if exists cpd_activity_value;
alter table public.cpd_activity_types add constraint cpd_activity_value check (
  (points is not null and points > 0 and points <= 10)
  or (points is null and points_min is not null and points_max is not null
      and points_min > 0 and points_min <= points_max and points_max <= 10)
  -- the fourteen August types predate values and are switched off below
  or not active
);
alter table public.cpd_activity_types drop constraint if exists cpd_activity_words;
alter table public.cpd_activity_types add constraint cpd_activity_words
  check (min_words between 0 and 5000);

-- -----------------------------------------------------------------------------
-- 2. The reflection
-- -----------------------------------------------------------------------------
alter table public.cpd_entries add column if not exists reflection text;
alter table public.cpd_entries drop constraint if exists cpd_reflection_length;
alter table public.cpd_entries add constraint cpd_reflection_length
  check (reflection is null or length(reflection) <= 40000);

-- Words, counted the way a person would: runs of letters or digits, so a line of
-- dashes or a pasted table of dots is not a hundred words. The browser counts
-- the same way, and the two have to agree or a member is told 500 and refused.
create or replace function app.word_count(t text) returns integer
language sql immutable parallel safe
set search_path = ''
as $$
  select count(*)::int
    from regexp_matches(coalesce(t, ''), '[[:alnum:]]+(''[[:alnum:]]+)*', 'g');
$$;

-- -----------------------------------------------------------------------------
-- 3. The agreed table
-- -----------------------------------------------------------------------------
insert into public.cpd_activity_types
  (code, name, is_core, sort_order, active, points, points_min, points_max,
   min_words, member_can_log, once_per_year, needs_evidence, guidance)
values
  ('ami_committee', 'AMI Council of Management or Technical Committee meeting', true, 10, true,
   1, null, null, 0, false, false, false,
   'Recorded by the office from the meeting register.'),
  ('ami_agm', 'AMI AGM', true, 20, true, 2, null, null, 0, false, false, false,
   'Recorded from the attendance list.'),
  ('ami_seminar', 'AMI Seminar', true, 30, true, 3, null, null, 0, false, false, false,
   'Recorded from Zoom attendance, or earned by watching the recording and passing its questions.'),
  ('technical_review', 'Technical Review', true, 40, true, null, 0.5, 2, 0, false, false, false,
   'Guidance notes, HSE updates and similar on this site. Read it, answer the questions, '
   'and the points arrive. Each review says what it is worth.'),
  ('arca_training', 'ARCA training course', true, 50, true, 1, null, null, 0, false, false, false,
   'Recorded from ARCA''s training records when the course is completed.'),
  ('practice_management', 'Practice of Management, full time', false, 110, true,
   2, null, null, 0, true, true, false,
   'Once a year, for anybody whose full time role is managing asbestos work. The office checks it.'),
  ('regional_meeting_2027', 'ARCA or ACAD regional meeting', false, 120, true,
   1, null, null, 0, true, false, true,
   'ARCA meetings are recorded for you from the attendance list. Log an ACAD meeting here, '
   'with evidence of attendance.'),
  ('arca_agm', 'ARCA AGM', false, 125, true, 1, null, null, 0, false, false, false,
   'Recorded from ARCA''s attendance list.'),
  ('external_training', 'External training course or seminar', false, 130, true,
   1, null, null, 0, true, false, true,
   'A course or seminar run by somebody other than AMI or ARCA. Attach the certificate.'),
  ('qualification', 'Formal asbestos qualification (RSPH, NVQ, BOHS)', false, 140, true,
   2, null, null, 0, true, false, true,
   'Attach the certificate or the awarding body''s confirmation.'),
  ('training_reflection', 'Reflection following a training course', false, 150, true,
   2, null, null, 500, true, false, false,
   'At least 500 words on what you learned on the course and how it changes the way you work.'),
  ('arca_news', 'ARCA News Updates', false, 160, true, 1, null, null, 0, false, false, false,
   'Read an ARCA News update on this site and answer its questions.'),
  ('article', 'Writing an article for publication', false, 170, true,
   2, null, null, 0, true, false, true,
   'Attach the article or a link to where it was published.'),
  ('self_directed', 'Self Directed Learning', false, 180, true, 1, null, null, 0, true, false, false,
   'Anything else of value to your work that is not listed above. Say what it was.')
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- 4. log_cpd, with the value taken from the activity
-- -----------------------------------------------------------------------------
-- DROPPED, not replaced. Changing the parameter list makes a NEW function beside
-- the old one, and an overload nobody calls is how 0027 once hung the email hook
-- on a dead approve_application. The old signature also took p_points, which is
-- exactly the parameter this migration exists to remove.
drop function if exists public.log_cpd(date, uuid, text, numeric, text, integer, text);

create or replace function public.log_cpd(
  p_occurred_on      date,
  p_activity_type_id uuid,
  p_title            text,
  p_provider         text default null,
  p_duration_minutes integer default null,
  p_evidence_ref     text default null,
  p_reflection       text default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_member uuid := app.member_id();
  t        public.cpd_activity_types;
  v_words  integer;
  v_year   integer := extract(year from p_occurred_on)::int;
  v_id     uuid;
begin
  if v_member is null then
    raise exception 'There is no AMI membership for this account.' using errcode = '42501';
  end if;

  select * into t from public.cpd_activity_types
   where id = p_activity_type_id and active;
  if t.id is null then
    raise exception 'That is not an activity type AMI is using.' using errcode = '22023';
  end if;
  if not t.member_can_log then
    raise exception 'That activity is recorded for you automatically, so it cannot be logged by hand.'
      using errcode = '22023';
  end if;
  if t.points is null then
    raise exception 'That activity is valued item by item and cannot be logged by hand.'
      using errcode = '22023';
  end if;

  if p_occurred_on is null or p_occurred_on > current_date then
    raise exception 'A CPD entry cannot be dated in the future.' using errcode = '22023';
  end if;
  if p_occurred_on < current_date - interval '3 years' then
    raise exception 'That date is more than three years ago. Ask the office to record it.'
      using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_title, ''))) < 3 then
    raise exception 'Please say what the activity was.' using errcode = '22023';
  end if;

  v_words := app.word_count(p_reflection);
  if t.min_words > 0 and v_words < t.min_words then
    raise exception 'The reflection needs at least % words. It has %.', t.min_words, v_words
      using errcode = '22023';
  end if;

  if t.once_per_year and exists (
       select 1 from public.cpd_entries e
        where e.member_id = v_member and e.activity_type_id = t.id
          and e.year = v_year and e.status <> 'rejected') then
    raise exception '% can be logged once a year, and % already has one.', t.name, v_year
      using errcode = '22023';
  end if;

  insert into public.cpd_entries
    (member_id, year, occurred_on, activity_type_id, title, provider,
     duration_minutes, points, is_core, how_recorded, status, evidence_ref,
     recorded_by, reflection)
  values
    (v_member, v_year, p_occurred_on, t.id,
     btrim(p_title), nullif(btrim(coalesce(p_provider, '')), ''),
     p_duration_minutes, t.points, t.is_core, 'self_declared', 'pending',
     nullif(btrim(coalesce(p_evidence_ref, '')), ''), app.person_id(),
     nullif(btrim(coalesce(p_reflection, '')), ''))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.log_cpd(date, uuid, text, text, integer, text, text) from public;
grant execute on function public.log_cpd(date, uuid, text, text, integer, text, text)
  to authenticated;

-- -----------------------------------------------------------------------------
-- 5. A member writing round log_cpd
-- -----------------------------------------------------------------------------
-- cpd_insert_own from 0025 lets a member insert a pending row of their own
-- directly. log_cpd is the honest route, but nothing stopped a browser console
-- inserting a row claiming 10 points for an activity worth 1, or a reflection
-- of three words. RLS decides rows, not columns (0028), so a BEFORE trigger
-- holds the value and the rules for any insert that is a member's own.
create or replace function app.cpd_entry_member_rules() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare t public.cpd_activity_types;
begin
  -- Staff, the service role, and automatic awards are not a member logging
  -- their own: they have their own rules and their own functions.
  if app.is_membership_staff() or new.how_recorded <> 'self_declared'
     or new.member_id is distinct from app.member_id() then
    return new;
  end if;

  select * into t from public.cpd_activity_types where id = new.activity_type_id;
  if t.id is null or not t.active or not t.member_can_log or t.points is null then
    raise exception 'That activity cannot be logged by hand.' using errcode = '42501';
  end if;
  -- The value and the category are the activity's, whatever was sent. The
  -- status is NOT touched: a member inserting an accepted row must still be
  -- refused by cpd_insert_own, loudly, rather than quietly turned into pending
  -- and let through. Test 01 asserts that refusal.
  new.points  := t.points;
  new.is_core := t.is_core;
  if t.min_words > 0 and app.word_count(new.reflection) < t.min_words then
    raise exception 'The reflection needs at least % words.', t.min_words using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists cpd_entry_member_rules on public.cpd_entries;
create trigger cpd_entry_member_rules before insert on public.cpd_entries
  for each row execute function app.cpd_entry_member_rules();

-- -----------------------------------------------------------------------------
-- 6. Views carry the reflection and the new columns
-- -----------------------------------------------------------------------------
-- Appended at the END of each select list. A create or replace cannot add a
-- column in the middle, and dropping a view drops its grants.
create or replace view public.my_cpd
with (security_invoker = true) as
select
  e.id, e.year, e.occurred_on, e.title, e.provider, e.points, e.is_core,
  e.how_recorded, e.status, e.evidence_ref, e.duration_minutes, e.recorded_at,
  e.reviewed_at, e.review_note,
  t.name as activity_type,
  t.code as activity_code,
  (select count(*) from public.cpd_evidence v where v.cpd_entry_id = e.id) as evidence_count,
  e.reflection
from public.cpd_entries e
join public.cpd_activity_types t on t.id = e.activity_type_id;

create or replace view public.admin_cpd_queue
with (security_invoker = true) as
  select e.id, e.member_id, e.year, e.occurred_on, e.title, e.provider,
         e.points, e.is_core, e.status, e.evidence_ref, e.recorded_at,
         t.name as activity_type,
         m.membership_number,
         p.given_name, p.family_name,
         e.reflection,
         app.word_count(e.reflection) as reflection_words,
         t.min_words,
         t.needs_evidence,
         (select count(*) from public.cpd_evidence v where v.cpd_entry_id = e.id) as evidence_count
    from public.cpd_entries e
    join public.cpd_activity_types t on t.id = e.activity_type_id
    join public.members m on m.id = e.member_id
    join public.people p on p.id = m.person_id;

grant select on public.my_cpd, public.admin_cpd_queue to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Receipts on by default
-- -----------------------------------------------------------------------------
alter table public.member_preferences alter column cpd_receipts set default true;
update public.member_preferences set cpd_receipts = true where not cpd_receipts;
