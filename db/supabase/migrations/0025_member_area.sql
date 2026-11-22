-- =============================================================================
-- 0025  The members area
--
-- Almost nothing here is a new rule. 0007 and 0008 already let a member read
-- their own CPD, insert a pending self declared entry, start a thread and reply
-- to one, and 0009 already lets them issue their own card while the membership
-- is active. What was missing was the surface: a member can read their own
-- people row and nobody else's, so a forum thread showing who wrote each post
-- had nothing to read, and a profile page had to make six round trips to build
-- one screen.
--
-- So this migration adds views that gather what is already permitted, plus the
-- four things that genuinely did not exist: somewhere to keep the card strip, a
-- way to save a photograph that also records the consent, a way to log a CPD
-- entry without being trusted to say whether it is core, and slugs for threads.
--
-- It also fixes one bug, described in full below.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- The bug: two policies, two different ideas of whose folder it is
-- -----------------------------------------------------------------------------
-- 0011 states the convention plainly, and applies it to all four buckets: the
-- first path segment is the owning PERSON's id. Every policy in that file keys
-- on app.person_id(), and application-documents and cpd-evidence follow it.
--
-- 0021 then added member_photo_public, the one narrow hole that lets an anonymous
-- visitor see a photograph on a public verification page. It keys the first path
-- segment on the MEMBER id instead.
--
-- The two cannot both be satisfied by one path. A photograph stored under the
-- person id is invisible to the public policy, so the verification page silently
-- shows no picture. A photograph stored under the member id cannot be written or
-- read by the member at all, so uploading appears to fail for no reason. Which
-- failure you get depends on which convention the uploader happened to follow,
-- and neither one raises an error anywhere.
--
-- Nothing has been uploaded yet, so there is nothing to move. The convention that
-- wins is 0011's, because it is written down, it is what the other two buckets
-- do, and person is the right owner: a photograph belongs to a human being rather
-- than to a membership that may lapse and be reissued.
--
-- The public policy is rewritten to reach the membership through people, which is
-- one join and keeps all three conditions being re-checked on every request.
do $$
begin
  execute $p$
    drop policy if exists member_photo_public on storage.objects;
    create policy member_photo_public on storage.objects
      for select to anon
      using (
        bucket_id = 'member-photos'
        and exists (
          select 1
            from public.people pe
            join public.members m             on m.person_id = pe.id
            join public.member_preferences pr on pr.member_id = m.id
           where pe.id::text = (storage.foldername(storage.objects.name))[1]
             and m.is_active
             and pr.public_profile
             and pr.photo_on_public_page
        ))
  $p$;
exception when insufficient_privilege or undefined_table or undefined_function then
  raise notice 'storage policy skipped: not a Supabase storage schema';
end $$;


-- -----------------------------------------------------------------------------
-- Somewhere to keep the card strip
-- -----------------------------------------------------------------------------
-- The member cuts one square and one three to one strip from the same picture,
-- because a square crop of a face put into a strip is a crop through the nose.
-- Two files, so two columns. The consent covers both: it is consent to hold a
-- photograph of the person, not consent to a particular file.
alter table public.people
  add column if not exists photo_strip_path text;

comment on column public.people.photo_strip_path is
  'The 1125 by 369 strip drawn across the top of the membership card. Cut from '
  'the same picture as photo_path, in the browser, so the original never leaves '
  'the member''s device and the location written into a phone photograph never '
  'reaches AMI.';


-- -----------------------------------------------------------------------------
-- photo_upload_target
-- -----------------------------------------------------------------------------
-- Called by the Worker AS THE MEMBER before it uploads anything. It answers two
-- questions: which folder is yours, and what is there now.
--
-- It returns the folder rather than letting the Worker work it out, so no member
-- identifier is ever carried in a request the Worker can be talked into changing.
-- The folder is decided here, from auth.uid(), and there is nothing to tamper
-- with.
create or replace function public.photo_upload_target()
returns table (folder text, previous_square text, previous_strip text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id::text, p.photo_path, p.photo_strip_path
    from public.people p
   where p.auth_user_id = auth.uid();
$$;

revoke all on function public.photo_upload_target() from public;
grant execute on function public.photo_upload_target() to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- set_my_photo
-- -----------------------------------------------------------------------------
-- Records the two paths and the consent in one statement, because a photograph
-- held without a dated consent breaks the check constraint on people and, more
-- to the point, breaks the promise the upload page makes.
--
-- Deliberately NOT security definer. A member updating their own people row is
-- exactly what people_update_own already allows, so this runs as the caller and
-- the existing policy is what decides. A definer function here would be a second
-- rule to keep in step with the first.
create or replace function public.set_my_photo(p_square text, p_strip text)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_person uuid := app.person_id();
begin
  if v_person is null then
    raise exception 'There is no AMI record for this account.' using errcode = '42501';
  end if;

  -- Both paths must be inside this person's own folder. The policies already say
  -- so for the storage object; this says so for the row that points at it, so a
  -- record can never be made to point at somebody else's file.
  if p_square is null or p_strip is null
     or split_part(p_square, '/', 1) <> v_person::text
     or split_part(p_strip,  '/', 1) <> v_person::text then
    raise exception 'A photograph must be stored in your own folder.' using errcode = '42501';
  end if;

  update public.people
     set photo_path       = p_square,
         photo_strip_path = p_strip,
         photo_consent    = true,
         photo_consent_at = coalesce(photo_consent_at, now())
   where id = v_person;
end;
$$;

revoke all on function public.set_my_photo(text, text) from public;
grant execute on function public.set_my_photo(text, text) to authenticated, service_role;

-- Removing the photograph withdraws the consent with it. Keeping a dated consent
-- for a picture that no longer exists is keeping a record of nothing.
create or replace function public.clear_my_photo()
returns void
language sql
volatile
set search_path = ''
as $$
  update public.people
     set photo_path = null, photo_strip_path = null,
         photo_consent = false, photo_consent_at = null
   where id = app.person_id();
$$;

revoke all on function public.clear_my_photo() from public;
grant execute on function public.clear_my_photo() to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- my_profile
-- -----------------------------------------------------------------------------
-- One row, everything a members page needs about the person looking at it.
--
-- security_invoker = true, which is the opposite of the public_* views in 0012.
-- Those run as the owner because anon has no policies to run under. This runs as
-- the caller, so members_select_own and people_select_own are what restrict it,
-- and the view cannot become a way around them. A second member's row is not
-- filtered out by this definition; it is unreachable underneath it.
create or replace view public.my_profile
with (security_invoker = true) as
select
  m.id                        as member_id,
  p.id                        as person_id,
  m.membership_number,
  p.given_name,
  p.family_name,
  p.post_nominals,
  p.email,
  p.mobile,
  p.home_address,
  p.business_address,
  p.photo_path,
  p.photo_strip_path,
  p.photo_consent,
  g.name                      as grade,
  g.post_nominals             as grade_post_nominals,
  g.is_assessed,
  g.requires_cpd,
  o.name                      as employer,
  m.current_job_title,
  m.joined_on,
  m.is_active,
  m.status,
  pr.list_on_register,
  pr.public_profile,
  pr.photo_on_public_page,
  pr.forum_notifications,
  pr.email_newsletter,
  pr.email_events,
  s.slug,
  coalesce(r.core_required, 5)     as cpd_required_core,
  coalesce(r.non_core_required, 5) as cpd_required_non_core,
  (select max(y.year) from public.membership_years y where y.member_id = m.id) as last_year_recorded,
  (select w.issued_at from public.wallet_passes w
    where w.member_id = m.id and w.revoked_at is null
    order by w.issued_at desc limit 1) as card_issued_at
from public.members m
join public.people p              on p.id = m.person_id
join public.membership_grades g   on g.id = m.grade_id
join public.member_preferences pr on pr.member_id = m.id
left join public.organisations o   on o.id = m.employer_id
left join public.register_slugs s  on s.member_id = m.id and s.retired_at is null
left join public.cpd_requirements r
       on r.grade_id = m.grade_id
      and r.year = extract(year from current_date)::int;

grant select on public.my_profile to authenticated;

comment on view public.my_profile is
  'The signed in member''s own record, gathered. Restricted by the policies on '
  'the tables underneath rather than by anything written here, which is why it '
  'is security_invoker and the public_* views are not.';


-- -----------------------------------------------------------------------------
-- update_my_profile
-- -----------------------------------------------------------------------------
-- The short list of things a member may change about themselves. Their name,
-- their grade, their employer and their membership number are not on it: those
-- are the AMI record, and a member editing their own grade is the end of the
-- scheme.
--
-- The email address is not here either. It is the address they sign in with, so
-- it changes through Supabase Auth with a confirmation to both addresses, and the
-- people row follows once that has happened.
create or replace function public.update_my_profile(
  p_mobile           text default null,
  p_home_address     jsonb default null,
  p_business_address jsonb default null)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_person uuid := app.person_id();
begin
  if v_person is null then
    raise exception 'There is no AMI record for this account.' using errcode = '42501';
  end if;
  update public.people
     set mobile           = coalesce(nullif(btrim(p_mobile), ''), mobile),
         home_address     = coalesce(p_home_address, home_address),
         business_address = coalesce(p_business_address, business_address)
   where id = v_person;
end;
$$;

revoke all on function public.update_my_profile(text, jsonb, jsonb) from public;
grant execute on function public.update_my_profile(text, jsonb, jsonb) to authenticated;


-- =============================================================================
-- CPD
-- =============================================================================

-- -----------------------------------------------------------------------------
-- my_cpd
-- -----------------------------------------------------------------------------
-- The member's own log, with the activity type spelled out and the evidence
-- counted. cpd_select_own is what restricts it.
--
-- how_recorded is carried through rather than reduced to a status, because the
-- whole argument for publishing a CPD figure is being able to say where each
-- line came from.
create or replace view public.my_cpd
with (security_invoker = true) as
select
  e.id,
  e.year,
  e.occurred_on,
  e.title,
  e.provider,
  e.points,
  e.is_core,
  e.how_recorded,
  e.status,
  e.evidence_ref,
  e.duration_minutes,
  e.recorded_at,
  e.reviewed_at,
  e.review_note,
  t.name as activity_type,
  t.code as activity_code,
  (select count(*) from public.cpd_evidence v where v.cpd_entry_id = e.id) as evidence_count
from public.cpd_entries e
join public.cpd_activity_types t on t.id = e.activity_type_id;

grant select on public.my_cpd to authenticated;

-- -----------------------------------------------------------------------------
-- my_cpd_summary
-- -----------------------------------------------------------------------------
-- The two numbers the rings draw, the requirement they are measured against, and
-- how the accepted points arrived. Left joined from the summary table so a member
-- with nothing logged gets a row of zeroes rather than no row, because a page
-- that has to handle "no answer" as well as "zero" handles it wrongly once.
create or replace view public.my_cpd_summary
with (security_invoker = true) as
select
  m.id as member_id,
  y.yr as year,
  coalesce(s.core_points, 0)      as core_points,
  coalesce(s.non_core_points, 0)  as non_core_points,
  coalesce(s.entry_count, 0)      as entry_count,
  coalesce(s.requirement_met, false) as requirement_met,
  coalesce(r.core_required, 5)     as core_required,
  coalesce(r.non_core_required, 5) as non_core_required,
  g.requires_cpd,
  (select count(*) from public.cpd_entries e
    where e.member_id = m.id and e.year = y.yr and e.status = 'pending')  as pending_count,
  (select count(*) from public.cpd_entries e
    where e.member_id = m.id and e.year = y.yr and e.status = 'rejected') as rejected_count,
  (select coalesce(sum(e.points), 0) from public.cpd_entries e
    where e.member_id = m.id and e.year = y.yr and e.status = 'accepted'
      and e.how_recorded = 'automatic')       as points_automatic,
  (select coalesce(sum(e.points), 0) from public.cpd_entries e
    where e.member_id = m.id and e.year = y.yr and e.status = 'accepted'
      and e.how_recorded = 'awarded_by_ami')  as points_awarded,
  (select coalesce(sum(e.points), 0) from public.cpd_entries e
    where e.member_id = m.id and e.year = y.yr and e.status = 'accepted'
      and e.how_recorded = 'self_declared')   as points_self
from public.members m
join public.membership_grades g on g.id = m.grade_id
cross join lateral (
  select generate_series(extract(year from m.joined_on)::int,
                         extract(year from current_date)::int) as yr) y
left join public.cpd_year_summaries s on s.member_id = m.id and s.year = y.yr
left join public.cpd_requirements r   on r.grade_id = m.grade_id and r.year = y.yr;

grant select on public.my_cpd_summary to authenticated;

-- -----------------------------------------------------------------------------
-- log_cpd
-- -----------------------------------------------------------------------------
-- A member may already insert a pending entry directly, and cpd_insert_own is
-- what makes that safe. One thing it cannot check is whether the entry is
-- honestly core: is_core is a column on the row, so a member could log a non
-- core activity and tick core. The office reviews every entry and would catch
-- it, but a rule that depends on somebody noticing is not a rule.
--
-- So is_core is taken from the activity type and the year from the date, and
-- neither is a parameter. The insert still runs as the member, under the same
-- policy, so this narrows what can be said without widening who may say it.
create or replace function public.log_cpd(
  p_occurred_on      date,
  p_activity_type_id uuid,
  p_title            text,
  p_points           numeric default 1,
  p_provider         text default null,
  p_duration_minutes integer default null,
  p_evidence_ref     text default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_member uuid := app.member_id();
  v_core   boolean;
  v_active boolean;
  v_id     uuid;
begin
  if v_member is null then
    raise exception 'There is no AMI membership for this account.' using errcode = '42501';
  end if;

  select t.is_core into v_core
    from public.cpd_activity_types t
   where t.id = p_activity_type_id and t.active;
  if v_core is null then
    raise exception 'That is not an activity type AMI is using.' using errcode = '22023';
  end if;

  if p_occurred_on > current_date then
    raise exception 'A CPD entry cannot be dated in the future.' using errcode = '22023';
  end if;
  if p_occurred_on < current_date - interval '3 years' then
    raise exception 'That date is more than three years ago. Ask the office to record it.'
      using errcode = '22023';
  end if;
  if coalesce(p_points, 0) <= 0 or p_points > 10 then
    raise exception 'Points must be between 0.5 and 10.' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_title, ''))) < 3 then
    raise exception 'Please say what the activity was.' using errcode = '22023';
  end if;

  insert into public.cpd_entries
    (member_id, year, occurred_on, activity_type_id, title, provider,
     duration_minutes, points, is_core, how_recorded, status, evidence_ref, recorded_by)
  values
    (v_member, extract(year from p_occurred_on)::int, p_occurred_on, p_activity_type_id,
     btrim(p_title), nullif(btrim(coalesce(p_provider, '')), ''),
     p_duration_minutes, p_points, v_core, 'self_declared', 'pending',
     nullif(btrim(coalesce(p_evidence_ref, '')), ''), app.person_id())
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.log_cpd(date, uuid, text, numeric, text, integer, text) from public;
grant execute on function public.log_cpd(date, uuid, text, numeric, text, integer, text)
  to authenticated;


-- =============================================================================
-- The forum
-- =============================================================================

-- A thread needs a slug and a slug must be unique, so it is generated here rather
-- than chosen by the caller. A reference or a slug chosen by the caller can be
-- chosen twice, which is the same reasoning that put reference generation inside
-- submit_application in 0021.
create or replace function app.thread_slug(p_title text) returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_base text;
  v_try  text;
  n      integer := 0;
begin
  v_base := regexp_replace(
              regexp_replace(lower(app.normalise_for_matching(p_title)), '[^a-z0-9]+', '-', 'g'),
              '(^-+|-+$)', '', 'g');
  v_base := nullif(left(v_base, 60), '');
  if v_base is null then v_base := 'discussion'; end if;
  v_try := v_base;
  while exists (select 1 from public.forum_threads t where t.slug = v_try) loop
    n := n + 1;
    v_try := v_base || '-' || n::text;
    if n > 500 then
      v_try := v_base || '-' || replace(gen_random_uuid()::text, '-', '');
      exit;
    end if;
  end loop;
  return v_try;
end;
$$;

grant execute on function app.thread_slug(text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- start_thread
-- -----------------------------------------------------------------------------
-- The thread and its first post in one transaction, because a thread with no
-- post is a row nobody can see and nobody can delete.
--
-- Runs as the member, so forum_thread_insert and forum_post_insert decide, which
-- means an inactive member cannot start one and the banned word trigger still
-- screens the body. If the first post is held, the thread is held with it: a
-- thread whose only post is invisible must not appear in the list showing zero
-- replies.
create or replace function public.start_thread(
  p_category_id uuid, p_title text, p_body text)
returns table (thread_id uuid, slug text, held boolean)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_member uuid := app.member_id();
  v_slug   text;
  v_thread uuid;
  v_status public.forum_post_status;
begin
  if v_member is null then
    raise exception 'There is no AMI membership for this account.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_title, ''))) < 3 then
    raise exception 'Please give the discussion a title.' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_body, ''))) < 1 then
    raise exception 'Please write something in the first post.' using errcode = '22023';
  end if;

  v_slug := app.thread_slug(p_title);

  insert into public.forum_threads (category_id, author_id, title, slug)
  values (p_category_id, v_member, btrim(p_title), v_slug)
  returning id into v_thread;

  insert into public.forum_posts (thread_id, author_id, body)
  values (v_thread, v_member, btrim(p_body))
  returning status into v_status;

  if v_status = 'held' then
    update public.forum_threads set status = 'held' where id = v_thread;
  end if;

  return query select v_thread, v_slug, (v_status = 'held');
end;
$$;

revoke all on function public.start_thread(uuid, text, text) from public;
grant execute on function public.start_thread(uuid, text, text) to authenticated;

-- A reply, returning whether it was held, so the page can say so plainly instead
-- of the member wondering why their post is not there.
create or replace function public.reply_to_thread(p_thread_id uuid, p_body text)
returns table (post_id uuid, held boolean)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_member uuid := app.member_id();
  v_id     uuid;
  v_status public.forum_post_status;
begin
  if v_member is null then
    raise exception 'There is no AMI membership for this account.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_body, ''))) < 1 then
    raise exception 'Please write something.' using errcode = '22023';
  end if;
  if exists (select 1 from public.forum_threads t
              where t.id = p_thread_id and t.locked) then
    raise exception 'That discussion is closed to new replies.' using errcode = '42501';
  end if;

  insert into public.forum_posts (thread_id, author_id, body)
  values (p_thread_id, v_member, btrim(p_body))
  returning id, status into v_id, v_status;

  return query select v_id, (v_status = 'held');
end;
$$;

revoke all on function public.reply_to_thread(uuid, text) from public;
grant execute on function public.reply_to_thread(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- The forum views
-- -----------------------------------------------------------------------------
-- These are the reason this migration exists. A member can read forum_posts, and
-- cannot read the people row of the member who wrote one, so until now a thread
-- could be displayed with no idea who said any of it.
--
-- security_invoker = false, so they run as the owner and the policies underneath
-- do not apply. That makes the definition the only control, exactly as it does
-- for the public_* views in 0012, so each one carries its own filter and is worth
-- reading as carefully as a policy:
--
--   * only active members may read them at all
--   * only published posts, EXCEPT the reader's own, so a member sees their own
--     held post and nobody else's
--   * the four columns named below and nothing else. No email address, no
--     telephone number, no membership status beyond the grade.
--   * photo_path appears only where the member has switched their photograph on
--     publicly, because a picture visible to a whole membership is a public
--     picture whatever the page is called
create or replace view public.forum_category_list
with (security_invoker = false) as
select
  c.id, c.slug, c.name, c.description, c.sort_order, c.locked,
  (select count(*) from public.forum_threads t
    where t.category_id = c.id and t.status = 'published') as thread_count,
  (select max(t.last_post_at) from public.forum_threads t
    where t.category_id = c.id and t.status = 'published') as last_post_at
from public.forum_categories c
where c.active
  and app.is_active_member();

create or replace view public.forum_thread_list
with (security_invoker = false) as
select
  t.id, t.slug, t.title, t.category_id, c.slug as category_slug, c.name as category,
  t.pinned, t.locked, t.post_count, t.last_post_at, t.created_at,
  p.given_name, p.family_name, p.post_nominals,
  g.name as grade,
  case when pr.photo_on_public_page then p.photo_path end as photo_path,
  (t.author_id = app.member_id()) as mine
from public.forum_threads t
join public.forum_categories c    on c.id = t.category_id
join public.members m             on m.id = t.author_id
join public.people p              on p.id = m.person_id
join public.membership_grades g   on g.id = m.grade_id
join public.member_preferences pr on pr.member_id = m.id
where app.is_active_member()
  and (t.status = 'published' or t.author_id = app.member_id());

create or replace view public.forum_post_list
with (security_invoker = false) as
select
  fp.id, fp.thread_id, fp.seq, fp.body, fp.status, fp.held_reason,
  fp.created_at, fp.edited_at,
  p.given_name, p.family_name, p.post_nominals,
  g.name as grade,
  o.name as employer,
  case when pr.photo_on_public_page then p.photo_path end as photo_path,
  s.slug as author_slug,
  (fp.author_id = app.member_id()) as mine,
  -- What decides whether the edit and delete links are shown. The policies in
  -- 0008 are what actually enforce it; this is so the page does not offer a
  -- member something the database is about to refuse.
  (fp.author_id = app.member_id() and not app.post_has_reply(fp.id)) as can_edit,
  exists (select 1 from public.forum_endorsements e where e.post_id = fp.id) as endorsed
from public.forum_posts fp
join public.members m             on m.id = fp.author_id
join public.people p              on p.id = m.person_id
join public.membership_grades g   on g.id = m.grade_id
join public.member_preferences pr on pr.member_id = m.id
left join public.organisations o   on o.id = m.employer_id
left join public.register_slugs s  on s.member_id = m.id and s.retired_at is null
where app.is_active_member()
  and (fp.status = 'published' or fp.author_id = app.member_id());

grant select on public.forum_category_list to authenticated;
grant select on public.forum_thread_list   to authenticated;
grant select on public.forum_post_list     to authenticated;

comment on view public.forum_post_list is
  'Posts with their author. Runs as the owner because a member cannot read '
  'another member''s people row, so the filter in this definition is the whole '
  'control: active members only, published posts plus the reader''s own, four '
  'columns about the author and a photograph only where it is already public.';


-- -----------------------------------------------------------------------------
-- my_posts
-- -----------------------------------------------------------------------------
-- Everything this member has written, for the download my data button on the
-- profile page and for the "your discussions" list. Invoker, because
-- forum_post_select already limits it to their own plus published.
create or replace view public.my_posts
with (security_invoker = true) as
select fp.id, fp.thread_id, t.title as thread, t.slug as thread_slug,
       c.name as category, fp.body, fp.status, fp.created_at, fp.edited_at
from public.forum_posts fp
join public.forum_threads t     on t.id = fp.thread_id
join public.forum_categories c  on c.id = t.category_id
where fp.author_id = (select app.member_id());

grant select on public.my_posts to authenticated;


-- =============================================================================
-- my_recent
-- =============================================================================
-- What the dashboard shows under "what has happened on your record". Three
-- different things in one shape, because the question a member is asking is one
-- question.
--
-- Nothing negative appears here, and that is not an oversight. A rejected CPD
-- entry shows to the member with the reason, because it is their own record and
-- they are owed the explanation. It appears nowhere else at all.
--
-- security_invoker = false, and for one reason: the second branch names the
-- member who replied, and a member cannot read another member's people row. As
-- an invoker view every reply would silently vanish and the page would look
-- quiet rather than broken, which is the failure this codebase keeps finding.
-- Both branches therefore carry their own app.member_id() filter, and those two
-- filters are the whole control.
create or replace view public.my_recent
with (security_invoker = false) as
select * from (
  select
    case e.how_recorded
      when 'automatic'      then 'auto'
      when 'awarded_by_ami' then 'ami'
      else case when e.status = 'pending' then 'wait' else 'auto' end
    end::text as kind,
    case
      when e.status = 'pending'  then 'Waiting to be reviewed'
      when e.status = 'rejected' then 'An entry was not accepted'
      when e.how_recorded = 'automatic' then
        e.points::text || ' point' || case when e.points = 1 then '' else 's' end
        || ' awarded automatically'
      when e.how_recorded = 'awarded_by_ami' then
        e.points::text || ' point' || case when e.points = 1 then '' else 's' end
        || ' awarded by AMI'
      else e.points::text || ' point' || case when e.points = 1 then '' else 's' end
        || ' accepted'
    end::text as title,
    (e.title || coalesce('. ' || e.review_note, '') || '.')::text as detail,
    coalesce(e.reviewed_at, e.recorded_at) as happened_at,
    '/cpd'::text as href
  from public.cpd_entries e
  where e.member_id = (select app.member_id())

  union all

  select 'post'::text,
         ('A reply to ' || t.title)::text,
         (p.given_name || ' ' || p.family_name)::text,
         fp.created_at,
         ('/thread?t=' || t.slug)::text
  from public.forum_posts fp
  join public.forum_threads t on t.id = fp.thread_id
  join public.members m       on m.id = fp.author_id
  join public.people p        on p.id = m.person_id
  where t.author_id = (select app.member_id())
    and fp.author_id <> (select app.member_id())
    and fp.status = 'published'
) x
order by happened_at desc;

grant select on public.my_recent to authenticated;


-- =============================================================================
-- The second bug: the audit trigger writes the wrong id
-- =============================================================================
-- app.audit_row() in 0005 records the actor as auth.uid(), and audit_log.actor_id
-- is a foreign key to public.people(id). That was correct when it was written:
-- 0002 made people.id BE the Supabase auth user id, so the two were the same
-- value.
--
-- 0017 separated them, so that the office could hold a person before that person
-- has an account. A person now has an id of its own and an auth_user_id beside
-- it, and 0017 backfilled the existing rows with auth_user_id = id, which is why
-- nothing broke at the time and why every test still passes.
--
-- Every person created SINCE then has an id from gen_random_uuid() and an
-- auth_user_id that is a different value. For those people, and that is every
-- member the office has approved since 0017, auth.uid() is not a people id, the
-- foreign key is violated, and the audited write fails outright:
--
--     insert or update on table "audit_log" violates foreign key constraint
--     "audit_log_actor_id_fkey"
--
-- The tables carrying an audit trigger include members, membership_years,
-- cpd_entries and wallet_passes. So a member logging a CPD entry fails, the
-- office approving an application fails, and issuing a card fails. Nothing
-- degrades quietly; the whole statement is refused.
--
-- The existing tests do not catch it because their fixtures give each person the
-- same id for both columns, which is exactly the thing 0017 stopped being true.
-- 04_member_area_supabase.sql deliberately uses different values for the two, and
-- that is what surfaced this.
--
-- The fix is to record the PERSON, which is what the column has always meant.
-- Written as a fallback rather than a replacement, so a row written by the
-- service role or by a job with no session still audits with a null actor rather
-- than failing: an audit trail that refuses the write it is auditing is worse
-- than one that records "we do not know who".
create or replace function app.audit_row() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after  jsonb;
  v_row_id text;
  v_actor  uuid;
begin
  if tg_op = 'DELETE' then
    v_before := to_jsonb(old);
    v_row_id := (to_jsonb(old) ->> 'id');
  elsif tg_op = 'INSERT' then
    v_after  := to_jsonb(new);
    v_row_id := (to_jsonb(new) ->> 'id');
  else
    v_before := to_jsonb(old);
    v_after  := to_jsonb(new);
    v_row_id := (to_jsonb(new) ->> 'id');
    -- an update that changed nothing is noise, not history
    if v_before = v_after then
      return new;
    end if;
  end if;

  -- The person, not the account. If the account is not linked to a person yet,
  -- or there is no session at all, the actor is unknown and says so.
  v_actor := app.person_id();

  insert into public.audit_log (actor_id, actor_role, action, table_name, row_id, before, after)
  values (v_actor, current_user, tg_op, tg_table_name, v_row_id, v_before, v_after);

  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

comment on function app.audit_row() is
  'Attach to any table whose changes must be answerable later. Records the '
  'PERSON who made the change, not the account: 0017 separated the two and this '
  'function was still writing auth.uid() into a column that references people.';
