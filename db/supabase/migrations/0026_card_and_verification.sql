-- =============================================================================
-- 0026  The membership card, and a verification page that can say no
--
-- Two things, and they belong together because the second is what the first
-- points at. A card carries a code, the code leads to a page, and until now that
-- page could only say yes.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- The verification page can now say no
-- -----------------------------------------------------------------------------
-- 0012 recorded this decision and the consequence beside it, and the consequence
-- has arrived: the card is about to be real. Steve confirmed the change on
-- 9 August 2026.
--
-- Before: an inactive membership was filtered out of public_profile, so a request
-- for its slug returned nothing and the page said "this membership cannot be
-- confirmed", which is the same answer a mistyped address gets. A duty holder
-- scanning a card could not tell a lapsed member from a forged one, and a
-- perfectly genuine card that somebody had simply not renewed read as a broken
-- link.
--
-- After: the row is still returned and it carries is_active, so the page can say
-- plainly that this person is not a current member.
--
-- What an inactive row does NOT carry is as considered as what it does. The
-- photograph, the employer and the CPD position all go. Somebody who has left has
-- not agreed to AMI publishing their face and their employer indefinitely, and
-- their CPD position is nobody's business once there is no membership to
-- evidence. The name, the membership number and the grade stay, because those
-- three are what let a duty holder match a card in their hand to a record and get
-- an honest answer about it.
--
-- public_profile, the member's own switch, is still respected. A member who has
-- said do not look me up is not looked up whether they are active or not.
-- Dropped rather than replaced: CREATE OR REPLACE cannot add a column in the
-- middle of a view, and is_active belongs beside the grade rather than tacked on
-- the end where a reader would miss it. Nothing depends on this view except the
-- page that reads it.
drop view if exists public.public_profile;

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
  m.is_active,
  case when m.is_active then o.name end as employer,
  case when m.is_active then m.joined_on end as joined_on,
  -- the photograph appears only where the member is current AND has switched it
  -- on, which is two conditions and both are re-checked here and again in the
  -- storage policy on every request
  case when m.is_active and pr.photo_on_public_page then p.photo_path end as photo_path,
  case
    when not m.is_active     then null
    when not g.requires_cpd  then 'Not required at this grade'
    when cs.requirement_met  then 'Meeting the requirement'
    else 'In progress'
  end as cpd_status,
  case when m.is_active then extract(year from current_date)::int end as cpd_period,
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
  and pr.public_profile;

-- Dropping a view drops its grants with it. anon reads this one and nothing else
-- on the way to a verification page, so forgetting this line would take the card
-- down for everybody who is not signed in, which is everybody scanning one.
grant select on public.public_profile to anon, authenticated;

comment on view public.public_profile is
  'The page a card leads to. It answers for a membership that has been switched '
  'off as well as for one that is current, because a code already printed on a '
  'card outlives the membership behind it, and a duty holder needs to be able to '
  'tell a lapsed member from a forged card. An inactive row carries the name, the '
  'number and the grade, and nothing else.';


-- -----------------------------------------------------------------------------
-- my_card
-- -----------------------------------------------------------------------------
-- Everything the card page draws, in one row. Invoker, so members_select_own and
-- people_select_own decide what it can reach.
--
-- The scopes column is what fills the strip where a member has no photograph.
-- Verified scope of practice is deferred out of phase 1, so it is null for
-- everybody today and the card falls back to the AMI mark. It is here rather than
-- added later because the card's three states are designed around it and a card
-- that gains a state after members have installed it is a card that changes shape
-- on their phone.
create or replace view public.my_card
with (security_invoker = true) as
select
  m.id                as member_id,
  m.membership_number,
  p.given_name,
  p.family_name,
  p.post_nominals,
  g.name              as grade,
  g.post_nominals     as grade_post_nominals,
  g.is_assessed,
  g.requires_cpd,
  m.joined_on,
  m.is_active,
  m.status,
  p.photo_strip_path,
  p.photo_path,
  s.slug,
  null::text[]        as scopes,
  coalesce(cs.core_points, 0)     as cpd_core,
  coalesce(cs.non_core_points, 0) as cpd_non_core,
  coalesce(r.core_required, 5) + coalesce(r.non_core_required, 5) as cpd_required_total,
  w.id                as pass_id,
  w.platform          as pass_platform,
  w.serial_number,
  w.issued_at         as pass_issued_at,
  (select count(*) from public.card_issues ci where ci.member_id = m.id) as times_issued
from public.members m
join public.people p             on p.id = m.person_id
join public.membership_grades g  on g.id = m.grade_id
left join public.register_slugs s on s.member_id = m.id and s.retired_at is null
left join public.cpd_year_summaries cs
       on cs.member_id = m.id and cs.year = extract(year from current_date)::int
left join public.cpd_requirements r
       on r.grade_id = m.grade_id and r.year = extract(year from current_date)::int
left join public.wallet_passes w
       on w.member_id = m.id and w.revoked_at is null;

grant select on public.my_card to authenticated;


-- -----------------------------------------------------------------------------
-- issue_my_card
-- -----------------------------------------------------------------------------
-- Self service, and only while the membership is active, which is what
-- passes_insert_own in 0009 already says. This adds the two things a policy
-- cannot do: generate the serial and the token, and record the issue.
--
-- The serial is generated HERE and not by the caller, for the same reason an
-- application reference is: a value chosen by the caller can be chosen twice, and
-- a duplicate serial on a wallet pass means two members' cards collide on Apple's
-- side.
--
-- The token is returned ONCE, in this call, and never again. Only its hash is
-- stored, exactly as a password would be. A member who loses it reissues, which
-- is the same button they would press anyway.
--
-- Issuing revokes the previous pass for that platform, by the trigger in 0009. A
-- lost phone therefore stops verifying the moment a new card is issued, which is
-- the whole argument for a digital card over a printed one.
create or replace function public.issue_my_card(p_platform text default 'apple')
returns table (serial_number text, auth_token text, issued_at timestamptz)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_member   uuid := app.member_id();
  v_platform public.wallet_platform;
  v_serial   text;
  v_token    text;
  v_issued   timestamptz;
begin
  if v_member is null then
    raise exception 'There is no AMI membership for this account.' using errcode = '42501';
  end if;

  begin
    v_platform := p_platform::public.wallet_platform;
  exception when invalid_text_representation then
    raise exception 'That is not a wallet AMI issues for.' using errcode = '22023';
  end;

  -- A membership that has been switched off cannot mint a card saying it is
  -- valid. The policy says the same thing; this says it with a message a person
  -- can read instead of an empty result.
  if not app.is_active_member() then
    raise exception 'A card can only be issued while the membership is active.'
      using errcode = '42501';
  end if;

  v_serial := 'AMI-' || upper(encode(extensions.gen_random_bytes(8), 'hex'));
  v_token  := encode(extensions.gen_random_bytes(24), 'hex');

  insert into public.wallet_passes
    (member_id, platform, serial_number, auth_token_hash, issued_at, last_updated_at)
  values
    (v_member, v_platform, v_serial,
     encode(extensions.digest(v_token, 'sha256'), 'hex'), now(), now())
  returning wallet_passes.issued_at into v_issued;

  insert into public.card_issues (member_id, platform, reason, issued_by)
  values (v_member, v_platform,
          case when exists (select 1 from public.card_issues ci
                             where ci.member_id = v_member)
               then 'replacement'::public.card_issue_reason
               else 'first_issue'::public.card_issue_reason end,
          app.person_id());

  return query select v_serial, v_token, v_issued;
end;
$$;

revoke all on function public.issue_my_card(text) from public;
grant execute on function public.issue_my_card(text) to authenticated;
