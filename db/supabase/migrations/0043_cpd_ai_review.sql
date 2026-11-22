-- =============================================================================
-- 0043  CPD reflections reviewed with AI help
--
-- The plan agreed on 30 October 2026 (claude/ami-cpd-automation-plan.md), item 4
-- in the order of work:
--
--   Each reflection is marked against a short guide by Claude, which recommends
--   accept or query with a reason. A person decides; the office can accept a
--   batch of recommended entries at once. The record notes that AI assisted.
--   AI does not accept on its own at launch.
--
-- HOW IT FITS TOGETHER, the same shape as Zoom (0042)
--
--   The office presses Ask Claude on CPD to review. The admin app asks the
--   site's Worker, carrying the staff member's own sign in. The Worker asks the
--   database for a few entries waiting for a recommendation (ai_review_begin,
--   AS THEM), sends each reflection to Claude with the guide, and hands each
--   answer back (ai_review_record, AS THE SERVICE ROLE). The admin app then
--   shows the recommendation on the card, and a person presses Accept or
--   Reject exactly as before.
--
-- FOUR THINGS THAT MUST HOLD, and test 28 holds them:
--
--   AI NEVER DECIDES. ai_review_record writes a recommendation into a table of
--   its own and touches nothing on cpd_entries. The only way an entry is
--   accepted is review_cpd, called by a person, and the trigger from 0020
--   stamps that person as the reviewer.
--
--   THE RECORD SAYS AI ASSISTED. When a person decides an entry that carries a
--   recommendation, the entry is marked ai_assisted and points at the
--   recommendation, guide version and model included. My CPD shows it.
--
--   CLAUDE SEES THE REFLECTION AND NOTHING ABOUT THE PERSON. No name, no
--   membership number, no email, no employer. The activity, the title, the
--   provider, the date and the words. The member's record never leaves.
--
--   A RECOMMENDATION COMES FROM CLAUDE AND NOWHERE ELSE. Recording one is
--   granted to the service role only and accepted only for an entry a member of
--   staff asked about in the last ten minutes, so a browser cannot write
--   "Claude recommends accept" on an entry it would like accepted.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The settings
-- -----------------------------------------------------------------------------
insert into public.system_settings (key, value, note) values
  ('ai_review_model', 'claude-sonnet-5-5',
   'The Claude model that reads reflections. Changing it changes only future '
   'recommendations; every recommendation records the model that made it.')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- 2. The guide
-- -----------------------------------------------------------------------------
-- Versioned rather than edited in place, so every recommendation can say which
-- wording it was marked against. Saving a new version is a new row; the
-- newest active row is the guide.
create table if not exists public.cpd_review_guides (
  id          uuid primary key default gen_random_uuid(),
  version     integer generated always as identity,
  body        text not null check (length(btrim(body)) between 200 and 8000),
  active      boolean not null default true,
  created_by  uuid references public.people(id),
  created_at  timestamptz not null default now()
);
create unique index if not exists cpd_review_guides_version on public.cpd_review_guides (version);

comment on table public.cpd_review_guides is
  'What Claude marks a reflection against. Add a new version rather than '
  'editing an old one: each recommendation records the version it used.';

create or replace function app.cpd_review_guide_stamp() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.created_by := app.person_id();
  return new;
end;
$$;
drop trigger if exists cpd_review_guides_stamp on public.cpd_review_guides;
create trigger cpd_review_guides_stamp before insert on public.cpd_review_guides
  for each row execute function app.cpd_review_guide_stamp();

-- A guide that has marked something is evidence and is not rewritten. Switch it
-- off and add a new one.
create or replace function app.cpd_review_guide_frozen() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.body is distinct from old.body then
    raise exception 'A guide is not rewritten once saved. Add a new version instead, so earlier recommendations still say what they were marked against.'
      using errcode = '22023';
  end if;
  return new;
end;
$$;
drop trigger if exists cpd_review_guides_frozen on public.cpd_review_guides;
create trigger cpd_review_guides_frozen before update on public.cpd_review_guides
  for each row execute function app.cpd_review_guide_frozen();

alter table public.cpd_review_guides enable row level security;
revoke all on public.cpd_review_guides from anon, authenticated;
grant select, insert, update on public.cpd_review_guides to authenticated;
drop policy if exists review_guides_staff on public.cpd_review_guides;
create policy review_guides_staff on public.cpd_review_guides
  for all to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

-- The first version. A draft for the office to change, written for the one
-- activity that needs a reflection today: a reflection following a training
-- course, 500 words.
insert into public.cpd_review_guides (body)
select $guide$Recommend ACCEPT when the reflection does all four of these:

1. It is about a real piece of training. It names the course, or describes it clearly enough that a reader knows what it was.
2. It says what the member learned. Something specific: a method, a regulation, a piece of guidance, a mistake they will now avoid. Not only that the course was "useful" or "informative".
3. It says how it changes the way they work, or will. A real example from their own work is the strongest evidence of this.
4. It is the member's own thinking about their own practice, rather than a summary of the course content alone.

Recommend QUERY when any of those is missing, when most of it restates the course syllabus with little of the member's own view, when it is about something other than a training course, or when it repeats itself to reach the word count.

Do not judge spelling, grammar, style or how well written it is. Do not guess whether anybody else, or a computer, wrote it. Do not query because you disagree with a technical point; if a technical statement looks wrong for the UK asbestos sector (CAR 2012, L143, HSG248, HSG264 and similar), say so in the reason for the office, and still judge the four points above.

The reason is for AMI's office: one or two plain sentences saying which points are met or missing. When you recommend QUERY, also write a short, polite note to the member saying what to add. Address them as "you". Do not use their name.$guide$
where not exists (select 1 from public.cpd_review_guides);


-- -----------------------------------------------------------------------------
-- 3. The recommendations
-- -----------------------------------------------------------------------------
create table if not exists public.cpd_ai_reviews (
  id              uuid primary key default gen_random_uuid(),
  entry_id        uuid not null references public.cpd_entries(id) on delete cascade,
  recommendation  text not null check (recommendation in ('accept', 'query')),
  reason          text not null check (length(btrim(reason)) between 3 and 2000),
  member_note     text check (member_note is null or length(member_note) <= 2000),
  guide_id        uuid not null references public.cpd_review_guides(id),
  model           text not null,
  asked_by        uuid references public.people(id),
  created_at      timestamptz not null default now()
);
create index if not exists cpd_ai_reviews_entry on public.cpd_ai_reviews (entry_id, created_at desc);

comment on table public.cpd_ai_reviews is
  'Claude''s recommendation on a reflection. A recommendation only: nothing '
  'here changes an entry. Written only by ai_review_record, as the site.';

alter table public.cpd_ai_reviews enable row level security;
revoke all on public.cpd_ai_reviews from anon, authenticated;
grant select on public.cpd_ai_reviews to authenticated;
drop policy if exists ai_reviews_staff on public.cpd_ai_reviews;
create policy ai_reviews_staff on public.cpd_ai_reviews
  for select to authenticated using ((select app.is_membership_staff()));

drop trigger if exists cpd_ai_reviews_audit on public.cpd_ai_reviews;
create trigger cpd_ai_reviews_audit after insert or update or delete on public.cpd_ai_reviews
  for each row execute function app.audit_row();

-- Who asked, and when, so the Worker can record only what it was asked for.
alter table public.cpd_entries add column if not exists ai_requested_by uuid references public.people(id);
alter table public.cpd_entries add column if not exists ai_requested_at timestamptz;
alter table public.cpd_entries add column if not exists ai_review_id uuid references public.cpd_ai_reviews(id);
alter table public.cpd_entries add column if not exists ai_assisted boolean not null default false;
-- A member may edit their own pending entry (cpd_update_own_pending, 0007). A
-- recommendation on words that have since changed is a recommendation on
-- something else, so it stops counting the moment they change.
alter table public.cpd_entries add column if not exists reflection_changed_at timestamptz;

comment on column public.cpd_entries.ai_assisted is
  'True when a person decided this entry with a recommendation from Claude in '
  'front of them. ai_review_id says which, and so which guide and model.';

-- The latest recommendation on an entry that was made on its CURRENT words.
create or replace function app.cpd_latest_ai_review(p_entry uuid) returns public.cpd_ai_reviews
language sql stable security definer set search_path = ''
as $$
  select r.* from public.cpd_ai_reviews r join public.cpd_entries e on e.id = r.entry_id
   where r.entry_id = p_entry
     and r.created_at > coalesce(e.reflection_changed_at, '-infinity'::timestamptz)
   order by r.created_at desc, r.id limit 1;
$$;
revoke all on function app.cpd_latest_ai_review(uuid) from public;

create or replace function app.cpd_reflection_changed() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.reflection is distinct from old.reflection then
    new.reflection_changed_at := now();
  end if;
  return new;
end;
$$;
drop trigger if exists cpd_entries_reflection_changed on public.cpd_entries;
create trigger cpd_entries_reflection_changed before update of reflection on public.cpd_entries
  for each row execute function app.cpd_reflection_changed();


-- -----------------------------------------------------------------------------
-- 4. When a person decides, the record says AI assisted
-- -----------------------------------------------------------------------------
-- Runs alongside 0020's stamp, on the same change. Named to run after it.
create or replace function app.cpd_mark_ai_assisted() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r public.cpd_ai_reviews;
begin
  if new.status is distinct from old.status and new.status in ('accepted', 'rejected')
     and new.how_recorded <> 'automatic' then
    r := app.cpd_latest_ai_review(new.id);
    if r.id is not null then
      new.ai_assisted  := true;
      new.ai_review_id := r.id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists cpd_entries_zz_ai_assisted on public.cpd_entries;
create trigger cpd_entries_zz_ai_assisted
  before update of status on public.cpd_entries
  for each row execute function app.cpd_mark_ai_assisted();

-- RLS decides rows, not columns. Members may insert their own entries and
-- staff may update entries, and none of these four columns is anybody's to
-- set by hand. INVOKER, deliberately: inside a definer function current_user
-- is the owner, and the question here is who is really asking. The functions
-- above run as the owner and pass; a browser runs as authenticated and does not.
create or replace function app.cpd_ai_columns_guard() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    -- Silently cleared rather than refused: a member's form never sends them,
    -- so anything here came from a console, and the entry itself is still fine.
    new.ai_assisted := false;
    new.ai_review_id := null;
    new.ai_requested_by := null;
    new.ai_requested_at := null;
    new.reflection_changed_at := null;
    return new;
  end if;
  if new.reflection is not distinct from old.reflection
     and new.reflection_changed_at is distinct from old.reflection_changed_at then
    raise exception 'Whether AI assisted is recorded by the database, not set by hand.'
      using errcode = '42501';
  end if;
  if (new.ai_requested_by, new.ai_requested_at) is distinct from (old.ai_requested_by, old.ai_requested_at)
     or ((new.ai_assisted, new.ai_review_id) is distinct from (old.ai_assisted, old.ai_review_id)
         and not (new.status is distinct from old.status)) then
    raise exception 'Whether AI assisted is recorded by the database, not set by hand.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists cpd_entries_ai_guard on public.cpd_entries;
create trigger cpd_entries_ai_guard before insert or update on public.cpd_entries
  for each row execute function app.cpd_ai_columns_guard();


-- -----------------------------------------------------------------------------
-- 5. Asking: a member of staff, as themselves
-- -----------------------------------------------------------------------------
-- Returns up to p_limit pending entries that have a reflection and no
-- recommendation against the current guide, with ONLY what Claude needs. The
-- Worker never sees who wrote them.
create or replace function public.ai_review_begin(p_limit integer default 3) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_by    uuid := app.person_id();
  g       public.cpd_review_guides;
  v_items jsonb;
begin
  if not app.is_membership_staff() or v_by is null then
    raise exception 'Asking Claude about CPD is for membership staff.' using errcode = '42501';
  end if;
  select * into g from public.cpd_review_guides where active order by version desc limit 1;
  if g.id is null then
    raise exception 'There is no active review guide. Add one under CPD review guide.' using errcode = '22023';
  end if;

  with picked as (
    select e.id
      from public.cpd_entries e
      join public.cpd_activity_types t on t.id = e.activity_type_id
     where e.status = 'pending'
       and t.min_words > 0
       and length(btrim(coalesce(e.reflection, ''))) > 0
       and not exists (select 1 from public.cpd_ai_reviews r
                        where r.entry_id = e.id and r.guide_id = g.id
                          and r.created_at > coalesce(e.reflection_changed_at, '-infinity'::timestamptz))
       -- Not one somebody else asked about a minute ago and is still waiting on.
       and (e.ai_requested_at is null or e.ai_requested_at < now() - interval '10 minutes')
     order by e.recorded_at
     limit greatest(1, least(coalesce(p_limit, 3), 5))
     for update of e skip locked
  ), stamped as (
    update public.cpd_entries e
       set ai_requested_by = v_by, ai_requested_at = now()
      from picked where e.id = picked.id
    returning e.id, e.title, e.provider, e.occurred_on, e.reflection, e.activity_type_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'activity', t.name, 'title', s.title, 'provider', s.provider,
           'occurred_on', s.occurred_on, 'min_words', t.min_words,
           'words', app.word_count(s.reflection), 'reflection', s.reflection)), '[]'::jsonb)
    into v_items
    from stamped s join public.cpd_activity_types t on t.id = s.activity_type_id;

  return jsonb_build_object(
    'by', v_by, 'guide_id', g.id, 'guide_version', g.version, 'guide', g.body,
    'model', coalesce(nullif(app.setting('ai_review_model'), ''), 'claude-sonnet-5-5'),
    'items', v_items,
    'remaining', (select count(*) from public.cpd_entries e
                    join public.cpd_activity_types t on t.id = e.activity_type_id
                   where e.status = 'pending' and t.min_words > 0
                     and length(btrim(coalesce(e.reflection, ''))) > 0
                     and not exists (select 1 from public.cpd_ai_reviews r
                                      where r.entry_id = e.id and r.guide_id = g.id
                                        and r.created_at > coalesce(e.reflection_changed_at, '-infinity'::timestamptz))
                     and e.ai_requested_at is null));
end;
$$;
revoke all on function public.ai_review_begin(integer) from public;
grant execute on function public.ai_review_begin(integer) to authenticated;


-- -----------------------------------------------------------------------------
-- 6. Recording: the Worker, as the service role
-- -----------------------------------------------------------------------------
create or replace function public.ai_review_record(
  p_entry          uuid,
  p_by             uuid,
  p_guide          uuid,
  p_model          text,
  p_recommendation text,
  p_reason         text,
  p_member_note    text default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  e    public.cpd_entries;
  v_id uuid;
begin
  select * into e from public.cpd_entries where id = p_entry for update;
  if e.id is null then
    raise exception 'There is no such entry.' using errcode = '22023';
  end if;
  if p_by is null or e.ai_requested_by is distinct from p_by
     or e.ai_requested_at < now() - interval '10 minutes' then
    raise exception 'Nobody on the staff asked about this entry just now.' using errcode = '42501';
  end if;
  if e.status <> 'pending' then
    -- Decided while Claude was reading it. Nothing to recommend any more, and
    -- not an error: say so and record nothing.
    update public.cpd_entries set ai_requested_by = null, ai_requested_at = null where id = e.id;
    return null;
  end if;
  if e.reflection_changed_at >= e.ai_requested_at then
    -- The member changed the words while Claude was reading the old ones.
    update public.cpd_entries set ai_requested_by = null, ai_requested_at = null where id = e.id;
    return null;
  end if;
  if p_recommendation not in ('accept', 'query') then
    raise exception 'A recommendation is accept or query.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.cpd_review_guides where id = p_guide) then
    raise exception 'No such guide.' using errcode = '22023';
  end if;

  insert into public.cpd_ai_reviews
    (entry_id, recommendation, reason, member_note, guide_id, model, asked_by)
  values
    (e.id, p_recommendation, left(btrim(p_reason), 2000),
     case when p_recommendation = 'query' then nullif(left(btrim(coalesce(p_member_note, '')), 2000), '') end,
     p_guide, left(coalesce(p_model, ''), 100), p_by)
  returning id into v_id;

  update public.cpd_entries set ai_requested_by = null, ai_requested_at = null where id = e.id;
  return v_id;
end;
$$;
revoke all on function public.ai_review_record(uuid, uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.ai_review_record(uuid, uuid, uuid, text, text, text, text) to service_role;

-- Something went wrong at Claude's end: let the entry be asked about again at
-- once rather than in ten minutes.
create or replace function public.ai_review_release(p_entry uuid, p_by uuid) returns void
language sql volatile security definer set search_path = ''
as $$
  update public.cpd_entries set ai_requested_by = null, ai_requested_at = null
   where id = p_entry and ai_requested_by = p_by;
$$;
revoke all on function public.ai_review_release(uuid, uuid) from public, anon, authenticated;
grant execute on function public.ai_review_release(uuid, uuid) to service_role;


-- -----------------------------------------------------------------------------
-- 7. What the screens read
-- -----------------------------------------------------------------------------
-- Appended at the END of each select list: a create or replace cannot add a
-- column in the middle.
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
         (select count(*) from public.cpd_evidence v where v.cpd_entry_id = e.id) as evidence_count,
         r.recommendation as ai_recommendation,
         r.reason         as ai_reason,
         r.member_note    as ai_member_note,
         r.created_at     as ai_reviewed_at,
         r.model          as ai_model,
         g.version        as ai_guide_version,
         e.ai_assisted
    from public.cpd_entries e
    join public.cpd_activity_types t on t.id = e.activity_type_id
    join public.members m on m.id = e.member_id
    join public.people p on p.id = m.person_id
    left join lateral (select * from public.cpd_ai_reviews x where x.entry_id = e.id
                          and x.created_at > coalesce(e.reflection_changed_at, '-infinity'::timestamptz)
                        order by x.created_at desc, x.id limit 1) r on true
    left join public.cpd_review_guides g on g.id = r.guide_id;

create or replace view public.my_cpd
with (security_invoker = true) as
select
  e.id, e.year, e.occurred_on, e.title, e.provider, e.points, e.is_core,
  e.how_recorded, e.status, e.evidence_ref, e.duration_minutes, e.recorded_at,
  e.reviewed_at, e.review_note,
  t.name as activity_type,
  t.code as activity_code,
  (select count(*) from public.cpd_evidence v where v.cpd_entry_id = e.id) as evidence_count,
  e.reflection,
  e.ai_assisted
from public.cpd_entries e
join public.cpd_activity_types t on t.id = e.activity_type_id;

grant select on public.my_cpd, public.admin_cpd_queue to authenticated;
