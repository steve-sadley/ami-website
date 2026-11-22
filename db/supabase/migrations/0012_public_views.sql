-- =============================================================================
-- 0012  What the public can reach
--
-- anon holds no privileges on any base table. It holds select on three views and
-- nothing else.
--
-- These views are owned by a privileged role with security_invoker LEFT OFF, so
-- they run with the owner's rights and the underlying policies do not apply.
-- That is deliberate, and it means the view definition is the ONLY control. Each
-- one therefore carries its own filter and is reviewed as carefully as a policy.
-- Supabase's linter flags this pattern; it is intended, documented here, and
-- covered by tests.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public_register
-- -----------------------------------------------------------------------------
-- Active members who have opted in. is_active is the switch a member of staff
-- presses, and nothing else decides who appears here.
create view public.public_register
with (security_invoker = false) as
select
  m.membership_number,
  p.given_name,
  p.family_name,
  p.post_nominals,
  g.name        as grade,
  g.is_assessed,
  o.name        as employer,
  extract(year from m.joined_on)::int as joined_year,
  s.slug
from public.members m
join public.people p             on p.id = m.person_id
join public.membership_grades g  on g.id = m.grade_id
join public.member_preferences pr on pr.member_id = m.id
left join public.organisations o  on o.id = m.employer_id
left join public.register_slugs s on s.member_id = m.id and s.retired_at is null
where m.is_active
  and g.appears_on_register
  and pr.list_on_register;

comment on view public.public_register is
  'The searchable register. Active, opted in, and on a grade that appears. '
  'An inactive membership disappears from here the moment the switch is thrown.';

-- -----------------------------------------------------------------------------
-- public_profile
-- -----------------------------------------------------------------------------
-- The page a card QR code leads to.
--
-- DECISION OF 8 AUGUST 2026, and the consequence recorded beside it: an inactive
-- member is removed from here as well as from the register, so a request for
-- their slug returns nothing.
--
-- The consequence is that a card QR already in circulation then leads to a page
-- that does not exist, which reads as a broken link rather than as an answer,
-- and it does not let a duty holder tell a lapsed member from a forged card. The
-- alternative, a page that stays and says plainly that the person is not a
-- current member, is one line in this view: drop "and m.is_active" from the
-- where clause and expose m.is_active as a column. Worth revisiting once the
-- card is in real use.
create view public.public_profile
with (security_invoker = false) as
select
  s.slug,
  m.membership_number,
  p.given_name,
  p.family_name,
  p.post_nominals,
  g.name        as grade,
  g.is_assessed,
  g.requires_cpd,
  o.name        as employer,
  m.joined_on,
  -- the photograph appears ONLY where the member has switched it on, which is a
  -- separate choice from consenting to it on the card
  case when pr.photo_on_public_page then p.photo_path end as photo_path,
  -- CPD as a status against the requirement with the period stated, never a bare
  -- score, because four points in March is not a shortfall. A grade that does
  -- not require CPD says so rather than showing a gap.
  case
    when not g.requires_cpd then 'Not required at this grade'
    when cs.requirement_met  then 'Meeting the requirement'
    else 'In progress'
  end as cpd_status,
  extract(year from current_date)::int as cpd_period,
  now() as verified_at
from public.register_slugs s
join public.members m            on m.id = s.member_id
join public.people p             on p.id = m.person_id
join public.membership_grades g  on g.id = m.grade_id
join public.member_preferences pr on pr.member_id = m.id
left join public.organisations o  on o.id = m.employer_id
left join public.cpd_year_summaries cs
       on cs.member_id = m.id and cs.year = extract(year from current_date)::int
where s.retired_at is null
  and pr.public_profile
  and m.is_active;

-- -----------------------------------------------------------------------------
-- public_content
-- -----------------------------------------------------------------------------
create view public.public_content
with (security_invoker = false) as
select 'news'::text as kind, n.slug, n.title, n.summary, n.published_at,
       n.category, null::timestamptz as starts_at, null::text as location
  from public.news_articles n
 where n.status = 'published' and n.published_at <= now()
union all
select 'event', e.slug, e.title, e.description, e.published_at,
       e.kind, e.starts_at, e.location
  from public.events e
 where e.status = 'published' and not e.members_only
union all
select 'guidance', d.slug, d.title, d.summary, d.published_at,
       d.category, null, null
  from public.guidance_documents d
 where d.status = 'published' and not d.members_only
union all
select 'video', v.slug, v.title, v.description, v.published_at,
       v.category, null, null
  from public.videos v
 where v.status = 'published' and not v.members_only;

-- -----------------------------------------------------------------------------
-- The only grants anon ever receives
-- -----------------------------------------------------------------------------
grant usage on schema public to anon;
grant select on public.public_register to anon, authenticated;
grant select on public.public_profile  to anon, authenticated;
grant select on public.public_content  to anon, authenticated;

-- Everything else the public touches, meaning the contact form, the application
-- form and event booking, goes through a Worker with Turnstile in front of it
-- and writes nothing directly.
