-- =============================================================================
-- 0030  Bulletins: one off emails to a segment of the membership
--
-- The third of the three things asked for on 15 August, and the only one with
-- legal weight. A CPD decision is a letter to one person about their own record.
-- A bulletin goes to hundreds of people at once, is close enough to marketing
-- that the rules change, and must carry a working way out.
--
-- Almost none of this is new. 0010 created email_campaigns, email_sends,
-- email_events, suppression_list and consents on 8 August and not one of them
-- has ever been used. 0029 built the queueing, the rendering and the
-- unsubscribe token. This migration is mostly the four rules that make sending
-- safe, and one policy change that had to happen before the table was used for
-- anything real.
--
-- THE FOUR RULES, each of which is here because the obvious version is wrong:
--
--   MATERIALISE ONCE. The recipients are written down when the bulletin is sent
--   and the send refuses to run twice. A double click on a button that emails
--   200 people is not a thing to leave to the browser.
--
--   THE COUNT AND THE SEND COME FROM THE SAME QUERY. app.campaign_recipients is
--   called by the preview, by the count and by the send. Two queries that are
--   meant to agree are two queries that will not, and the day they disagree is
--   the day somebody mails the wrong sixty people.
--
--   NO UNSUBSCRIBE, NO SEND. A bulletin whose body does not contain
--   {{unsubscribe_url}} is refused by the database. Not by the composer, which
--   is a browser, and not by a code review.
--
--   A STAGING SITE MAY NOT MAIL THE MEMBERSHIP. Until system_settings says the
--   environment is live, a send reaches only addresses on a short allow list and
--   says how many it held back. Cheap now, and awkward to retrofit after the
--   first accident.
--
-- WHAT CHANGED THAT WAS NOT ASKED FOR. 0010 gave EDITORS insert and update on
-- email_campaigns, which was harmless while the table was empty and is not
-- harmless now. An editor is a role for news, guidance and page copy and holds
-- no membership privileges at all. Without this change an editor could compose
-- and send a letter to every member on the register, under AMI's name, and
-- nothing about it would look wrong. Campaigns now belong to membership staff,
-- which is the same line 0027 drew on service templates and the same reasoning.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Settings that are facts about the deployment rather than about the schema
-- -----------------------------------------------------------------------------
-- Three of these could have been constants in a function. They are rows because
-- each of them differs between staging and live, and a constant that differs
-- between staging and live is a thing somebody edits in a hurry at cutover and
-- gets wrong.
create table if not exists public.system_settings (
  key        text primary key,
  value      text not null default '',
  note       text,
  updated_at timestamptz not null default now()
);

create trigger system_settings_updated before update on public.system_settings
  for each row execute function app.set_updated_at();

insert into public.system_settings (key, value, note) values
  ('environment', 'staging',
   'staging or live. While it is anything but live, sending a bulletin reaches '
   'only the addresses in bulletin_allow and everybody else is recorded as '
   'withheld. Change it at cutover and not before.'),
  ('site_url', 'https://staging.ami.uk.com',
   'Where the unsubscribe link points. Change it at cutover, or every bulletin '
   'sends members to a site that is about to stop existing.'),
  ('bulletin_from', 'bulletin@ami.uk.com',
   'The Reply-To on a bulletin. It has to be a mailbox somebody reads, which is '
   'why it is not no-reply@. The FROM address is still set by the Worker, '
   'because it has to be a domain SMTP2GO is verified to send for.'),
  ('bulletin_allow', '',
   'Comma separated addresses that may receive a bulletin while the environment '
   'is not live. Put your own in here to test with.')
on conflict (key) do nothing;

alter table public.system_settings enable row level security;
grant select on public.system_settings to authenticated;
grant update on public.system_settings to authenticated;

create policy settings_read_staff on public.system_settings
  for select to authenticated using ((select app.is_staff()));

-- Updating is super users only. The environment flag is the difference between
-- a bulletin reaching four addresses and reaching four hundred.
create policy settings_update_super on public.system_settings
  for update to authenticated
  using ((select app.is_super_user())) with check ((select app.is_super_user()));

comment on table public.system_settings is
  'Facts about this deployment rather than about the schema. Readable by staff, '
  'changed by super users only, because one of these rows decides whether a '
  'bulletin can reach the membership at all.';

create or replace function app.setting(p_key text) returns text
language sql stable security definer set search_path = ''
as $$ select coalesce((select value from public.system_settings where key = p_key), ''); $$;

revoke all on function app.setting(text) from public;


-- -----------------------------------------------------------------------------
-- What a campaign needs beyond what 0010 gave it
-- -----------------------------------------------------------------------------
-- 0010 gave it a name, an audience, a template, a schedule and a sender. It did
-- not give it the thing being sent, because at the time the wording was always
-- going to come from a template. A one off bulletin is not a template: it is
-- written once, sent once and never used again, and putting it in
-- email_templates would fill that table with dead rows and give an editor a
-- route to it.
alter table public.email_campaigns
  add column if not exists subject         text,
  add column if not exists html            text,
  add column if not exists reply_to        text,
  add column if not exists status          text not null default 'draft',
  add column if not exists test_sent_at    timestamptz,
  add column if not exists sent_by         uuid references public.people(id),
  add column if not exists recipient_count integer;

do $$
begin
  alter table public.email_campaigns
    add constraint email_campaigns_status_check
    check (status in ('draft', 'sending', 'sent', 'cancelled'));
exception when duplicate_object then null;
end $$;

comment on column public.email_campaigns.status is
  'draft, sending, sent or cancelled. send_campaign refuses anything that is not '
  'draft, which is what stops the same bulletin going out twice.';
comment on column public.email_campaigns.test_sent_at is
  'When a test copy was last sent. send_campaign refuses to run until this is '
  'set, so nobody can mail the membership something they have not read in an '
  'inbox first.';

alter table public.email_sends
  add column if not exists outbox_id uuid references public.email_outbox(id) on delete set null,
  add column if not exists reason    text;

create index if not exists email_sends_outbox on public.email_sends (outbox_id);

comment on column public.email_sends.status is
  'queued, sent, failed, suppressed or withheld. withheld means the environment '
  'was not live and the address was not on the allow list, which is a thing that '
  'happened rather than a thing that failed.';


-- -----------------------------------------------------------------------------
-- A CAMPAIGN IS NOT CONTENT
-- -----------------------------------------------------------------------------
-- See the head of this file. 0010's policies named app.is_editor(), which was
-- right for a table nothing used and wrong for one that now decides who AMI
-- writes to.
drop policy if exists campaigns_staff  on public.email_campaigns;
drop policy if exists campaigns_write  on public.email_campaigns;
drop policy if exists campaigns_update on public.email_campaigns;

create policy campaigns_read_membership on public.email_campaigns
  for select to authenticated using ((select app.is_membership_staff()));
create policy campaigns_write_membership on public.email_campaigns
  for insert to authenticated with check ((select app.is_membership_staff()));
create policy campaigns_update_membership on public.email_campaigns
  for update to authenticated
  using ((select app.is_membership_staff()) and status = 'draft')
  with check ((select app.is_membership_staff()));

-- A draft can be binned. A sent one cannot, because it is the record of what
-- went to whom, and email_sends hangs off it. 0010 granted DELETE and wrote no
-- policy, which is a locked door with no handle; this is the handle, and it only
-- opens on drafts.
create policy campaigns_delete_draft on public.email_campaigns
  for delete to authenticated
  using ((select app.is_membership_staff()) and status = 'draft' and sent_at is null);

comment on table public.email_campaigns is
  'A one off bulletin: who it goes to, what it says, and whether it has gone. '
  'Membership staff and super users, never editors: an editor is a content role '
  'and a letter to the whole membership is not content.';


-- -----------------------------------------------------------------------------
-- Who is in the segment
-- -----------------------------------------------------------------------------
-- ONE function, called by the count, by the preview and by the send. A count
-- from one query and a send from another is how somebody eventually mails the
-- wrong sixty people, and it is the kind of fault that is invisible until it has
-- already happened.
--
-- The audience is jsonb because the office will want combinations nobody has
-- thought of yet, and because a column per filter means a migration every time.
-- Every key is optional and an absent key means "do not filter on this":
--
--   channel        'newsletter' (default) or 'events'. Which preference gates it.
--   active         'true' (default), 'false', or 'any'
--   grades         ["member","fellow"]         grade CODES, not names
--   cpd            'any' (default), 'met', 'short'
--   employer_ids   ["uuid", ...]
--   joined_after   '2020-01-01'
--   joined_before  '2024-12-31'
--   roles          ["membership","moderator"]  people holding one of these
--   on_register    true or false
--
-- Three conditions are NOT optional and are not exposed as keys, because they
-- are not preferences of whoever is composing: there has to be an address, the
-- address must not be on the suppression list, and the member must not have
-- switched this channel off. Making any of those a checkbox would mean somebody
-- could untick it.
create or replace function app.campaign_recipients(p_audience jsonb)
returns table (
  member_id         uuid,
  person_id         uuid,
  email             text,
  given_name        text,
  family_name       text,
  membership_number text,
  grade             text,
  unsubscribe_token uuid)
language sql stable security definer set search_path = ''
as $$
  with a as (select coalesce(p_audience, '{}'::jsonb) as j)
  select m.id,
         p.id,
         lower(btrim(p.email)),
         p.given_name,
         p.family_name,
         m.membership_number,
         g.name,
         pr.unsubscribe_token
    from public.members m
    join public.people             p  on p.id = m.person_id
    join public.member_preferences pr on pr.member_id = m.id
    join public.membership_grades  g  on g.id = m.grade_id
    left join public.cpd_year_summaries s
      on s.member_id = m.id and s.year = extract(year from current_date)::int
   cross join a
   where coalesce(p.email, '') <> ''
     and not exists (select 1 from public.suppression_list sl
                      where lower(sl.email) = lower(btrim(p.email)))
     and case coalesce(a.j ->> 'channel', 'newsletter')
           when 'events' then pr.email_events
           else               pr.email_newsletter
         end
     and case coalesce(a.j ->> 'active', 'true')
           when 'any'   then true
           when 'false' then not m.is_active
           else              m.is_active
         end
     and (a.j -> 'grades' is null
          or jsonb_array_length(a.j -> 'grades') = 0
          or g.code in (select jsonb_array_elements_text(a.j -> 'grades')))
     and case coalesce(a.j ->> 'cpd', 'any')
           when 'met'   then coalesce(s.requirement_met, false)
           when 'short' then g.requires_cpd and not coalesce(s.requirement_met, false)
           else true
         end
     and (a.j -> 'employer_ids' is null
          or jsonb_array_length(a.j -> 'employer_ids') = 0
          or m.employer_id::text in (select jsonb_array_elements_text(a.j -> 'employer_ids')))
     and (a.j ->> 'joined_after'  is null or m.joined_on >= (a.j ->> 'joined_after')::date)
     and (a.j ->> 'joined_before' is null or m.joined_on <= (a.j ->> 'joined_before')::date)
     and (a.j -> 'roles' is null
          or jsonb_array_length(a.j -> 'roles') = 0
          or exists (select 1 from public.role_grants rg
                      where rg.person_id = p.id
                        and rg.role_code in (select jsonb_array_elements_text(a.j -> 'roles'))))
     and (a.j ->> 'on_register' is null
          or pr.list_on_register = (a.j ->> 'on_register')::boolean);
$$;

revoke all on function app.campaign_recipients(jsonb) from public;

comment on function app.campaign_recipients(jsonb) is
  'The segment, resolved once. The count, the preview and the send all call this '
  'and none of them has a query of its own, because two queries meant to agree '
  'are two queries that eventually will not.';


-- What the office sees before it presses anything. Definer, so it can read the
-- tables the resolver reads, with the staff check inside it rather than relying
-- on the caller's own privileges.
create or replace function public.campaign_recipients_preview(p_campaign_id uuid)
returns table (given_name text, family_name text, email text,
               membership_number text, grade text)
language plpgsql stable security definer set search_path = ''
as $$
declare c public.email_campaigns%rowtype;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may look at a bulletin audience.'
      using errcode = '42501';
  end if;
  select * into c from public.email_campaigns where id = p_campaign_id;
  if not found then raise exception 'No such bulletin.'; end if;

  return query
  select r.given_name, r.family_name, r.email, r.membership_number, r.grade
    from app.campaign_recipients(c.audience) r
   order by r.family_name, r.given_name;
end;
$$;

revoke all on function public.campaign_recipients_preview(uuid) from public;
grant execute on function public.campaign_recipients_preview(uuid) to authenticated, service_role;


create or replace function public.campaign_count(p_campaign_id uuid)
returns integer
language plpgsql stable security definer set search_path = ''
as $$
declare c public.email_campaigns%rowtype; n integer;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may look at a bulletin audience.'
      using errcode = '42501';
  end if;
  select * into c from public.email_campaigns where id = p_campaign_id;
  if not found then raise exception 'No such bulletin.'; end if;
  select count(*) into n from app.campaign_recipients(c.audience);
  return n;
end;
$$;

revoke all on function public.campaign_count(uuid) from public;
grant execute on function public.campaign_count(uuid) to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- Rendering one member's copy
-- -----------------------------------------------------------------------------
-- Kept separate so the test send and the real send cannot drift, and so the
-- unsubscribe URL is built in exactly one place. Everything it substitutes is
-- escaped by app.render_parts on the way in, with no way to opt out.
create or replace function app.campaign_vars(
  p_given text, p_family text, p_number text, p_grade text, p_token uuid)
returns jsonb
language sql stable set search_path = ''
as $$
  select jsonb_build_object(
    'given_name',        coalesce(p_given, ''),
    'family_name',       coalesce(p_family, ''),
    'membership_number', coalesce(p_number, ''),
    'grade',             coalesce(p_grade, ''),
    -- No token means the link lands on the preference page and is told it does
    -- not recognise itself, which is the right answer for a test copy. It must
    -- never carry somebody else's token: a member of staff clicking the
    -- unsubscribe link in a test would otherwise unsubscribe a real member.
    'unsubscribe_url',   app.setting('site_url') || '/preferences'
                         || case when p_token is null then ''
                                 else '?t=' || p_token::text end);
$$;

revoke all on function app.campaign_vars(text, text, text, text, uuid) from public;


-- -----------------------------------------------------------------------------
-- The test copy
-- -----------------------------------------------------------------------------
-- Nothing goes to the membership until one of these has been sent and looked at.
-- It renders with the sender's own details where they have any, so what they
-- read is what a member would read rather than a body full of empty gaps.
create or replace function public.send_campaign_test(p_campaign_id uuid, p_to text)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  c public.email_campaigns%rowtype;
  me record;
  r  record;
  v_id uuid;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may send a bulletin.' using errcode = '42501';
  end if;

  select * into c from public.email_campaigns where id = p_campaign_id;
  if not found then raise exception 'No such bulletin.'; end if;
  if coalesce(btrim(c.subject), '') = '' or coalesce(btrim(c.html), '') = '' then
    raise exception 'A bulletin needs a subject line and a body before it can be sent.';
  end if;
  if coalesce(btrim(p_to), '') = '' then
    raise exception 'Where should the test go?';
  end if;

  select p.given_name, p.family_name, m.membership_number, g.name as grade,
         pr.unsubscribe_token
    into me
    from public.people p
    left join public.members m on m.person_id = p.id
    left join public.membership_grades g on g.id = m.grade_id
    left join public.member_preferences pr on pr.member_id = m.id
   where p.id = app.person_id();

  select * into r from app.render_parts(
    '[TEST] ' || c.subject, c.html,
    app.campaign_vars(coalesce(me.given_name, 'there'), coalesce(me.family_name, ''),
                      coalesce(me.membership_number, 'TEST-0000'),
                      coalesce(me.grade, 'Member'),
                      -- deliberately null: see app.campaign_vars
                      null));

  v_id := app.queue_message('bulletin_test', r.subject, r.html, p_to,
            btrim(coalesce(me.given_name, '') || ' ' || coalesce(me.family_name, '')),
            app.person_id(),
            coalesce(nullif(btrim(coalesce(c.reply_to, '')), ''), app.setting('bulletin_from')),
            jsonb_build_object('campaign_id', c.id, 'kind', 'bulletin_test'));

  update public.email_campaigns set test_sent_at = now() where id = p_campaign_id;
  return v_id;
end;
$$;

revoke all on function public.send_campaign_test(uuid, text) from public;
grant execute on function public.send_campaign_test(uuid, text) to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- Sending it
-- -----------------------------------------------------------------------------
-- Every guard in here is refused loudly rather than worked around, and each one
-- is the answer to a specific way this goes wrong:
--
--   status must be draft          a second press sends nothing
--   subject and body must exist   an empty bulletin is not a bulletin
--   a test must have been sent    nobody mails 200 people something unread
--   the body must carry the       a bulletin with no way out is not lawful, and
--     unsubscribe placeholder       a composer is a browser and cannot be the rule
--   the environment must be live  a staging deploy cannot reach the membership
--
-- The whole thing is one transaction. If it raises half way through, no
-- email_sends rows survive and nothing is queued, so the bulletin is still a
-- draft and can be sent properly rather than half sent with no way to tell which
-- half.
create or replace function public.send_campaign(p_campaign_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  c          public.email_campaigns%rowtype;
  r          record;
  rr         record;
  v_env      text := app.setting('environment');
  v_allow    text[];
  v_queued   integer := 0;
  v_withheld integer := 0;
  v_send     uuid;
  v_outbox   uuid;
  v_reply    text;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may send a bulletin.' using errcode = '42501';
  end if;

  -- FOR UPDATE, so two people pressing Send within the same second serialise
  -- here rather than both reading status = 'draft' and both going ahead.
  select * into c from public.email_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'No such bulletin.'; end if;

  if c.status <> 'draft' or c.sent_at is not null then
    raise exception 'That bulletin is % and has already been sent. Copy it into a new one rather than sending it again.',
      c.status;
  end if;
  if coalesce(btrim(c.subject), '') = '' or coalesce(btrim(c.html), '') = '' then
    raise exception 'A bulletin needs a subject line and a body before it can be sent.';
  end if;
  if c.test_sent_at is null then
    raise exception 'Send yourself a test copy and read it before this goes to the membership.';
  end if;
  if position('{{unsubscribe_url}}' in c.html) = 0 then
    raise exception 'Every bulletin has to carry an unsubscribe link. Put {{unsubscribe_url}} in the body.';
  end if;

  v_allow := coalesce((select array_agg(lower(btrim(x)))
                         from unnest(string_to_array(app.setting('bulletin_allow'), ',')) x
                        where btrim(x) <> ''), '{}'::text[]);
  v_reply := coalesce(nullif(btrim(coalesce(c.reply_to, '')), ''), app.setting('bulletin_from'));

  update public.email_campaigns set status = 'sending' where id = p_campaign_id;

  for r in select * from app.campaign_recipients(c.audience) loop

    -- The staging guard. Recorded as withheld rather than skipped, for the same
    -- reason 0027 marks a suppressed message rather than dropping it: a
    -- recipient who is missing from the record and a recipient who was
    -- deliberately held back look identical afterwards unless one of them says so.
    if v_env <> 'live' and not (r.email = any (v_allow)) then
      insert into public.email_sends (campaign_id, person_id, email, status, reason)
      values (p_campaign_id, r.person_id, r.email, 'withheld',
              'The environment is ' || v_env || ', so only addresses in bulletin_allow are sent to.');
      v_withheld := v_withheld + 1;
      continue;
    end if;

    select * into rr from app.render_parts(c.subject, c.html,
      app.campaign_vars(r.given_name, r.family_name, r.membership_number,
                        r.grade, r.unsubscribe_token));

    insert into public.email_sends (campaign_id, person_id, email, status)
    values (p_campaign_id, r.person_id, r.email, 'queued')
    returning id into v_send;

    v_outbox := app.queue_message('bulletin', rr.subject, rr.html, r.email,
                  btrim(r.given_name || ' ' || r.family_name), r.person_id, v_reply,
                  jsonb_build_object('campaign_id', c.id, 'send_id', v_send,
                                     'kind', 'bulletin'));

    update public.email_sends set outbox_id = v_outbox where id = v_send;
    v_queued := v_queued + 1;
  end loop;

  update public.email_campaigns
     set status          = 'sent',
         sent_at         = now(),
         sent_by         = app.person_id(),
         recipient_count = v_queued
   where id = p_campaign_id;

  return jsonb_build_object('queued', v_queued, 'withheld', v_withheld,
                            'environment', v_env);
end;
$$;

revoke all on function public.send_campaign(uuid) from public;
grant execute on function public.send_campaign(uuid) to authenticated, service_role;

comment on function public.send_campaign(uuid) is
  'Materialises the recipients once and queues one message each. Refuses a '
  'bulletin that is not a draft, has no body, has never been tested, or carries '
  'no unsubscribe link. On a non live environment it reaches only the allow '
  'list and says how many it held back.';


-- -----------------------------------------------------------------------------
-- Keeping email_sends honest
-- -----------------------------------------------------------------------------
-- The drain knows nothing about campaigns and should not have to. It settles the
-- outbox row, and this carries that through to the campaign record, so
-- email_sends is a true account of what happened rather than a list of
-- intentions frozen at the moment of sending.
create or replace function app.sync_campaign_send()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status is distinct from old.status
     and new.status in ('sent', 'failed', 'suppressed')
     and new.context ? 'send_id' then
    update public.email_sends
       set status       = new.status,
           sent_at      = new.sent_at,
           provider_ref = new.provider_ref,
           reason       = new.last_error
     where id = (new.context ->> 'send_id')::uuid;
  end if;
  return new;
end;
$$;

revoke all on function app.sync_campaign_send() from public;

drop trigger if exists email_outbox_sync_send on public.email_outbox;
create trigger email_outbox_sync_send
  after update on public.email_outbox
  for each row execute function app.sync_campaign_send();


-- -----------------------------------------------------------------------------
-- What the office sees
-- -----------------------------------------------------------------------------
create or replace view public.admin_campaigns
with (security_invoker = true) as
select c.id,
       c.name,
       c.subject,
       c.status,
       c.audience,
       c.recipient_count,
       c.test_sent_at,
       c.sent_at,
       p.given_name || ' ' || p.family_name as sent_by,
       c.created_at,
       (select count(*) from public.email_sends s
         where s.campaign_id = c.id and s.status = 'sent')      as delivered,
       (select count(*) from public.email_sends s
         where s.campaign_id = c.id and s.status = 'failed')    as failed,
       (select count(*) from public.email_sends s
         where s.campaign_id = c.id and s.status = 'withheld')  as withheld
  from public.email_campaigns c
  left join public.people p on p.id = c.sent_by
 order by coalesce(c.sent_at, c.created_at) desc;

grant select on public.admin_campaigns to authenticated;


-- -----------------------------------------------------------------------------
-- The two new switches, where a signed in member already looks for them
-- -----------------------------------------------------------------------------
-- 0029 put cpd_reminders and cpd_receipts on member_preferences, and the profile
-- page reads its switches from my_profile rather than from the table. Without
-- this the profile page would show three of the five email switches and the
-- other two would exist only on /preferences, which is precisely the sort of
-- half answer that generates a telephone call.
--
-- create or replace on a view can ADD columns at the end and cannot insert one
-- in the middle, so these two go last and the rest is 0025's body retyped
-- unchanged. Retyped rather than dropped, because dropping a view drops its
-- grants with it and 0026 had to restate them for public_profile after learning
-- that the hard way.
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
    order by w.issued_at desc limit 1) as card_issued_at,
  -- New at the end, and only at the end.
  pr.cpd_reminders,
  pr.cpd_receipts,
  pr.unsubscribe_token
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

-- =============================================================================
-- AT CUTOVER, AND NOT BEFORE
-- =============================================================================
--   update public.system_settings set value = 'live'
--    where key = 'environment';
--   update public.system_settings set value = 'https://ami.uk.com'
--    where key = 'site_url';
--
-- Until the first of those, a bulletin reaches only the addresses listed in
-- bulletin_allow and tells you how many it held back. Until the second, every
-- unsubscribe link in every bulletin points at a site that is about to stop
-- existing.
--
-- And the pg_cron drain job from 0029 needs its URL changed at the same moment,
-- or nothing queued by any of this is ever sent.
-- =============================================================================
