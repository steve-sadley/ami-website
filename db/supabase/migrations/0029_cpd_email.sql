-- =============================================================================
-- 0029  The CPD emails: decisions, receipts and reminders
--
-- 0027 built the outbox and used it for one thing, the two application decision
-- letters. This puts the rest of the CPD scheme's correspondence through the
-- same pipe, and it adds the one piece the outbox has never had: something that
-- queues a message when NOBODY pressed a button.
--
-- Three senders, and they need three different routes into the queue:
--
--   review_cpd            a member of staff decided. app.queue_email already
--                         works, because the caller is membership staff.
--   the logging receipt   a MEMBER inserted a row. queue_email refuses them,
--                         and correctly so.
--   the yearly reminders  NOBODY is signed in. pg_cron is calling, auth.uid()
--                         is null, and queue_email refuses that too.
--
-- So this migration splits 0027's queue_email in two. The part that renders and
-- inserts becomes app.queue_message, with no opinion about who is asking. On top
-- of it sit two callers: app.queue_email, unchanged in signature and behaviour,
-- which asks whether the caller is membership staff, and app.queue_system_email,
-- which does not ask and is therefore granted to nobody a browser can be.
--
-- THAT GRANT IS THE WHOLE LOCK AND IT IS THE MOST DANGEROUS LINE IN THIS FILE.
-- app.queue_system_email will send anything to anybody under AMI's own name and
-- sending domain. It is revoked from public and from authenticated, so a signed
-- in member calling it gets 42501, and the only things that reach it are this
-- schema's own definer functions, which run as the owner and hold it by virtue
-- of ownership. There is a test asserting a member cannot call it. If that test
-- ever goes, the lock has gone with it.
--
-- WHAT A MEMBER MAY REFUSE. 0002 wrote the rule on member_preferences and it
-- decides every switch below: membership notices are not preferences, and
-- switching off the newsletter must never switch off a notice about somebody's
-- own membership. So a decision on a CPD entry is sent whatever the member has
-- chosen, and the reminder and the logging receipt are switchable, because a
-- reminder is a courtesy and a receipt for your own typing is a convenience.
-- Both are still marked is_service, because neither is marketing and neither
-- belongs in a bulletin opt out.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Rendering, pulled apart so two things can use it
-- -----------------------------------------------------------------------------
-- 0027's app.render_email did the substitution and the template lookup in one
-- function. A campaign has no template row, so the substitution has to be usable
-- on a subject and a body held somewhere else. This is 0027's body, lifted out
-- whole and not otherwise touched, and render_email is rewritten to call it.
--
-- Every rule it carries was paid for once already and none of them is optional:
-- the walk is over the PAYLOAD rather than the template, so a template cannot
-- reach for a column nobody offered it; braces are stripped from values, because
-- jsonb_each returns keys in its own order and a note reading
-- "see {{membership_number}}" would otherwise come out carrying a real one;
-- the subject takes the value as typed and the body takes it escaped; and a line
-- break is taken out of the subject, because a subject line goes into a header.
create or replace function app.render_parts(
  p_subject text,
  p_html    text,
  p_vars    jsonb
) returns table (subject text, html text)
language plpgsql stable set search_path = ''
as $$
declare
  k text;
  v text;
  s text := coalesce(p_subject, '');
  h text := coalesce(p_html, '');
begin
  for k, v in select key, value #>> '{}' from jsonb_each(coalesce(p_vars, '{}'::jsonb)) loop
    v := replace(replace(coalesce(v, ''), '{{', ''), '}}', '');
    s := replace(s, '{{' || k || '}}', v);
    h := replace(h, '{{' || k || '}}', app.html_escape(v));
  end loop;

  s := regexp_replace(s, '\{\{[a-z0-9_]+\}\}', '', 'g');
  h := regexp_replace(h, '\{\{[a-z0-9_]+\}\}', '', 'g');
  s := btrim(regexp_replace(s, '[\r\n]+', ' ', 'g'));

  subject := s;
  html := h;
  return next;
end;
$$;

comment on function app.render_parts(text, text, jsonb) is
  '0027''s substitution rules, with the template lookup taken off the front so a '
  'campaign body can use them too. Every value is escaped on its way into the '
  'body and there is no way to opt out, because the one that opts out is the one '
  'that carries somebody else''s markup.';


create or replace function app.render_email(p_code text, p_vars jsonb)
returns table (subject text, html text, is_service boolean)
language plpgsql stable set search_path = ''
as $$
declare
  t public.email_templates%rowtype;
  r record;
begin
  select * into t from public.email_templates where code = p_code;
  if not found then
    raise exception 'There is no email template with the code %.', p_code;
  end if;

  select * into r from app.render_parts(t.subject, t.html, p_vars);

  subject := r.subject;
  html := r.html;
  is_service := t.is_service;
  return next;
end;
$$;


-- -----------------------------------------------------------------------------
-- Queueing, with the question of who is asking taken off it
-- -----------------------------------------------------------------------------
-- This is 0027's queue_email from the render call down, with the staff check
-- removed and nothing else changed. It is SECURITY DEFINER for the same reason
-- 0027's was: the outbox has no insert policy for anybody at all, because no
-- browser may write a message AMI will send under its own name.
--
-- It is granted to NOBODY. Revoking from public removes the default grant every
-- function is created with, and after that the only role that can execute it is
-- the owner, which is what every definer function in this schema runs as. So the
-- three callers below reach it and nothing outside the database does.
create or replace function app.queue_message(
  p_code      text,
  p_subject   text,
  p_html      text,
  p_to_email  text,
  p_to_name   text,
  p_person_id uuid default null,
  p_reply_to  text default null,
  p_context   jsonb default '{}'::jsonb
) returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_status text := 'queued';
  v_to text := lower(btrim(coalesce(p_to_email, '')));
begin
  if v_to = '' then
    raise exception 'An email needs somewhere to go.';
  end if;

  -- Recorded rather than skipped, which is 0027's rule and the reason it is
  -- stated in two places: a message that was never sent because the address
  -- bounces is something the office needs to be able to find. Dropping it
  -- silently leaves a row at 'queued' forever, looking exactly like one about to
  -- go out.
  if exists (select 1 from public.suppression_list where lower(email) = v_to) then
    v_status := 'suppressed';
  end if;

  insert into public.email_outbox
    (template_code, to_email, to_name, subject, html, reply_to,
     person_id, context, status)
  values
    (p_code, v_to, p_to_name, p_subject, p_html, p_reply_to,
     p_person_id, coalesce(p_context, '{}'::jsonb), v_status)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function app.queue_message(text, text, text, text, text, uuid, text, jsonb)
  from public;

comment on function app.queue_message(text, text, text, text, text, uuid, text, jsonb) is
  'Writes a rendered message into the outbox and asks nothing about who wants it '
  'sent. Granted to nobody: the only things that can execute it are this schema''s '
  'own definer functions, which run as the owner. Every caller decides for itself '
  'who is allowed, and the two that a browser can reach both check.';


-- 0027's queue_email, with the same signature, the same grant and the same staff
-- check. Only the last twenty lines moved. Replacing it rather than leaving it
-- alone matters: two functions inserting into the same table drift, and the one
-- that drifts is always the one nobody is looking at.
create or replace function app.queue_email(
  p_code      text,
  p_to_email  text,
  p_to_name   text,
  p_vars      jsonb default '{}'::jsonb,
  p_person_id uuid default null,
  p_reply_to  text default null,
  p_context   jsonb default '{}'::jsonb
) returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare r record;
begin
  -- SECURITY DEFINER changes the executing role. It does not change auth.uid(),
  -- which is read from the request, so this is still asking about the person who
  -- called and not about the owner. That is also why it is is_membership_staff()
  -- and not a test on current_user, which inside a definer function is the owner
  -- and would answer yes to everybody.
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may queue an email from AMI.'
      using errcode = '42501';
  end if;

  select * into r from app.render_email(p_code, p_vars);

  return app.queue_message(p_code, r.subject, r.html, p_to_email, p_to_name,
                           p_person_id, p_reply_to, p_context);
end;
$$;

revoke all on function app.queue_email(text, text, text, jsonb, uuid, text, jsonb) from public;
grant execute on function app.queue_email(text, text, text, jsonb, uuid, text, jsonb)
  to authenticated, service_role;


-- THE DANGEROUS ONE. Read the head of this file before changing the grant.
--
-- No staff check, because there is nobody to check: a trigger fired by a member
-- and a cron job fired by a clock both arrive with an auth.uid() that is either
-- somebody who must not be allowed to send mail or nobody at all.
--
-- What makes it safe is that it is unreachable. authenticated does not hold it,
-- so a signed in member calling it through PostgREST is told permission denied
-- rather than being asked politely not to. anon does not hold it. service_role
-- holds it so that a future Worker route can queue rather than send inline, and
-- the Worker is the one place a secret already lives.
create or replace function app.queue_system_email(
  p_code      text,
  p_to_email  text,
  p_to_name   text,
  p_vars      jsonb default '{}'::jsonb,
  p_person_id uuid default null,
  p_reply_to  text default null,
  p_context   jsonb default '{}'::jsonb
) returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare r record;
begin
  select * into r from app.render_email(p_code, p_vars);
  return app.queue_message(p_code, r.subject, r.html, p_to_email, p_to_name,
                           p_person_id, p_reply_to, p_context);
end;
$$;

revoke all on function app.queue_system_email(text, text, text, jsonb, uuid, text, jsonb)
  from public;
revoke all on function app.queue_system_email(text, text, text, jsonb, uuid, text, jsonb)
  from anon, authenticated;
grant execute on function app.queue_system_email(text, text, text, jsonb, uuid, text, jsonb)
  to service_role;

comment on function app.queue_system_email(text, text, text, jsonb, uuid, text, jsonb) is
  'Queues a message with no check on who asked, for the two cases where nobody '
  'asked: a trigger fired by a member and a scheduled job fired by a clock. The '
  'GRANT is the only thing restraining it. authenticated must never hold it.';


-- -----------------------------------------------------------------------------
-- What a member may switch off
-- -----------------------------------------------------------------------------
-- email_newsletter and email_events have been on this table since 0002 and are
-- reused rather than replaced: the bulletin switch already exists and adding a
-- second one would give the office two answers to the same question.
--
-- unsubscribe_token is what makes the preference page reachable without signing
-- in, which the law requires of a bulletin and which is also simply right: a
-- person who wants less email should not have to remember a password to say so.
-- A uuid default is VOLATILE, so every existing row gets its own value rather
-- than all of them getting one. That is worth stating because it looks wrong.
alter table public.member_preferences
  add column if not exists cpd_reminders     boolean not null default true,
  add column if not exists cpd_receipts      boolean not null default false,
  add column if not exists unsubscribe_token uuid    not null default gen_random_uuid();

create unique index if not exists member_preferences_unsubscribe_token
  on public.member_preferences (unsubscribe_token);

comment on column public.member_preferences.cpd_reminders is
  'Reminders that the year''s CPD is not yet met. A courtesy, so it may be '
  'refused. A DECISION on a CPD entry is not a courtesy and is not covered by '
  'this or by any other switch.';
comment on column public.member_preferences.cpd_receipts is
  'OFF by default. A confirmation that an entry the member typed 10 seconds ago '
  'was received. Some people want it and most do not, and an email nobody asked '
  'for trains them to stop reading the ones that matter.';
comment on column public.member_preferences.unsubscribe_token is
  'The unguessable half of an unsubscribe link. It is per member rather than per '
  'message so the link lands on the preference page and somebody who only wanted '
  'the reminders stopped does not have to leave everything.';


-- -----------------------------------------------------------------------------
-- The templates
-- -----------------------------------------------------------------------------
-- All four are is_service, so 0027's policy puts them out of an editor's reach.
-- A CPD decision is a letter about somebody's own record and an editor is a
-- content role.
--
-- Nothing here is passed as markup. The list of entries arrives as a plain
-- string joined with semicolons rather than as an <ul>, because app.render_parts
-- escapes every value with no way to opt out, and the caller that wants an
-- exception is exactly the caller that should not have one.
insert into public.email_templates (code, name, subject, html, is_service) values
(
  'cpd_accepted',
  'CPD entries accepted',
  'Your CPD entries have been accepted',
  '<p>Dear {{given_name}},</p>
   <p>{{entry_count}} of your CPD entries {{have_or_has}} been accepted:</p>
   <blockquote style="border-left:3px solid #ddd;margin:0;padding-left:16px;color:#555">
     {{titles}}
   </blockquote>
   <p>For {{year}} you are now on <b>{{core_points}} of {{core_required}}</b> core points
      and <b>{{non_core_points}} of {{non_core_required}}</b> non core points.</p>
   <p>{{outstanding}}</p>
   <p>You can see your full record at any time by signing in and going to My CPD.</p>',
  true
),
(
  'cpd_rejected',
  'CPD entries not accepted',
  'Your CPD entries have not been accepted',
  '<p>Dear {{given_name}},</p>
   <p>{{entry_count}} of your CPD entries {{have_or_has}} been looked at and on this
      occasion {{have_or_has}} not been accepted:</p>
   <blockquote style="border-left:3px solid #ddd;margin:0;padding-left:16px;color:#555">
     {{titles}}
   </blockquote>
   <p>The reason is this:</p>
   <blockquote style="border-left:3px solid #ddd;margin:0;padding-left:16px;color:#555">
     {{note}}
   </blockquote>
   <p>The entries stay on your record marked as not accepted, so nothing is lost. If you
      have evidence that would change the position, or if you think this is wrong, reply
      to this message and the office will look again.</p>',
  true
),
(
  'cpd_logged',
  'CPD entry received',
  'AMI has your CPD entry',
  '<p>Dear {{given_name}},</p>
   <p>Your CPD entry <b>{{title}}</b>, worth {{points}} {{core_or_non}} point(s) and dated
      {{occurred_on}}, has been received and is waiting to be reviewed.</p>
   <p>Nothing counts towards your {{year}} total until the office has accepted it. You will
      be told either way.</p>
   <p style="color:#777;font-size:13px">You are getting this because you asked for a receipt
      when you log CPD. You can switch it off on your preferences page.</p>',
  true
),
(
  'cpd_reminder',
  'CPD reminder',
  'Your AMI CPD for {{year}}',
  '<p>Dear {{given_name}},</p>
   <p>A short note on where your CPD stands for {{year}}.</p>
   <p>You have <b>{{core_points}} of the {{core_required}}</b> core points and
      <b>{{non_core_points}} of the {{non_core_required}}</b> non core points.
      {{outstanding}}</p>
   <p>{{months_left}}</p>
   <p>Core means asbestos technical competence and non core means the wider professional
      skills around it. The split matters more than the total: 10 points that are all one
      or all the other does not meet the requirement.</p>
   <p>Sign in and go to My CPD to log what you have done. If you have attended something
      AMI ran, check the record first, because it may already be there.</p>
   <p style="color:#777;font-size:13px">You can switch these reminders off on your
      preferences page. Decisions about your own entries will still reach you.</p>',
  true
)
on conflict (code) do nothing;


-- -----------------------------------------------------------------------------
-- Printing a number a person will read
-- -----------------------------------------------------------------------------
-- CPD points are numeric(4,1), so they are 2 or 2.5 and never 2.375. to_char
-- with 'FM999999.9' looks right and prints "2." for a whole number, complete
-- with the trailing full stop, which reads as a typing mistake in the middle of
-- a sentence. This prints 2 as 2 and 2.5 as 2.5.
create or replace function app.cpd_num(p numeric) returns text
language sql immutable set search_path = ''
as $$
  -- trunc() on a numeric keeps the scale, so trunc(2.0)::text is '2.0' and not
  -- '2'. The cast through bigint is what actually drops it.
  select case when p is null then '0'
              when p = trunc(p) then trunc(p)::bigint::text
              else trim(to_char(p, 'FM999999.9')) end;
$$;


-- -----------------------------------------------------------------------------
-- A sentence about what is left
-- -----------------------------------------------------------------------------
-- Written once and used by both the decision email and the reminder, because two
-- copies of a sentence about the same arithmetic end up disagreeing, and the one
-- that is wrong is the one nobody reads.
create or replace function app.cpd_outstanding_sentence(
  p_core      numeric,
  p_core_req  numeric,
  p_non       numeric,
  p_non_req   numeric
) returns text
language sql immutable set search_path = ''
as $$
  select case
    when greatest(p_core_req - p_core, 0) = 0 and greatest(p_non_req - p_non, 0) = 0
      then 'That meets the requirement for the year. Anything further is welcome and is recorded, but nothing more is needed.'
    when greatest(p_core_req - p_core, 0) = 0
      then 'That leaves ' || app.cpd_num(greatest(p_non_req - p_non, 0))
           || ' non core to find. The core side is met.'
    when greatest(p_non_req - p_non, 0) = 0
      then 'That leaves ' || app.cpd_num(greatest(p_core_req - p_core, 0))
           || ' core to find. The non core side is met.'
    else 'That leaves ' || app.cpd_num(greatest(p_core_req - p_core, 0))
         || ' core and ' || app.cpd_num(greatest(p_non_req - p_non, 0))
         || ' non core to find.'
  end;
$$;


-- -----------------------------------------------------------------------------
-- review_cpd, with the letter on the end of it
-- -----------------------------------------------------------------------------
-- The 0020 body, unchanged, with the queueing added.
--
-- ONE EMAIL PER MEMBER PER PRESS, NOT ONE PER ENTRY. review_cpd takes an ARRAY,
-- because 0020 built it to clear a queue of forty in one transaction, and forty
-- entries can belong to a dozen different people. One message per entry would
-- send somebody eleven emails in a second, which is the fault everybody
-- remembers and nobody forgives.
--
-- So the update returns what it changed, the rows are grouped by member inside
-- the same statement, and one letter goes to each. The count returned is
-- unchanged, because the admin app reads it.
--
-- Note the order. The summary trigger from 0007 fires per row DURING the update
-- statement, so by the time the loop below reads cpd_year_summaries the totals
-- already include this decision. Reading them before the update would have sent
-- everybody yesterday's position, which is the kind of wrong that looks right.
create or replace function public.review_cpd(
  p_ids    uuid[],
  p_status text,
  p_note   text default null
) returns integer
language plpgsql volatile set search_path = ''
as $$
declare
  v_count    integer := 0;
  v_affected jsonb;
  a          jsonb;
  m          record;
  v_year     integer := extract(year from current_date)::int;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may review CPD.' using errcode = '42501';
  end if;
  if p_status not in ('accepted', 'rejected') then
    raise exception 'A review is accepted or rejected, not %.', p_status;
  end if;
  if p_status = 'rejected' and coalesce(btrim(p_note), '') = '' then
    raise exception 'A rejection needs a reason. The member is told what it says.';
  end if;

  with upd as (
    update public.cpd_entries e
       set status = p_status::public.cpd_entry_status,
           review_note = coalesce(p_note, e.review_note)
     where e.id = any (p_ids)
       and e.status = 'pending'
    returning e.member_id, e.year, e.title
  ), agg as (
    -- Grouped by member AND year. A batch that spans two CPD years is rare and
    -- is real, and one letter reporting a position that mixes them would be
    -- wrong in a way nobody could see. Two letters is the honest answer.
    select u.member_id,
           u.year,
           count(*)                                   as n,
           string_agg(u.title, '; ' order by u.title)  as titles
      from upd u
     group by u.member_id, u.year
  )
  select coalesce(sum(agg.n), 0)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'member_id', agg.member_id, 'year', agg.year,
           'n', agg.n, 'titles', agg.titles)), '[]'::jsonb)
    into v_count, v_affected
    from agg;

  if v_count = 0 then
    return 0;
  end if;

  for a in select * from jsonb_array_elements(v_affected) loop
    v_year := (a ->> 'year')::int;

    select p.id            as person_id,
           p.given_name,
           p.family_name,
           lower(btrim(coalesce(p.email, ''))) as email,
           coalesce(s.core_points, 0)          as core_points,
           coalesce(s.non_core_points, 0)      as non_core_points,
           coalesce(q.core_required, 0)        as core_required,
           coalesce(q.non_core_required, 0)    as non_core_required
      into m
      from public.members mm
      join public.people  p on p.id = mm.person_id
      left join public.cpd_year_summaries s
        on s.member_id = mm.id and s.year = v_year
      left join public.cpd_requirements q
        on q.grade_id = mm.grade_id and q.year = v_year
     where mm.id = (a ->> 'member_id')::uuid;

    -- A member with no address on the record is not an error worth taking a
    -- decision down for. The decision is recorded either way and the office can
    -- see the entry was reviewed.
    continue when not found or m.email = '';

    perform app.queue_email(
      case when p_status = 'accepted' then 'cpd_accepted' else 'cpd_rejected' end,
      m.email,
      btrim(m.given_name || ' ' || m.family_name),
      jsonb_build_object(
        'given_name',        m.given_name,
        'family_name',       m.family_name,
        'entry_count',       (a ->> 'n'),
        'have_or_has',       case when (a ->> 'n')::int = 1 then 'has' else 'have' end,
        'titles',            (a ->> 'titles'),
        'note',              coalesce(p_note, ''),
        'year',              v_year::text,
        'core_points',       app.cpd_num(m.core_points),
        'non_core_points',   app.cpd_num(m.non_core_points),
        'core_required',     app.cpd_num(m.core_required),
        'non_core_required', app.cpd_num(m.non_core_required),
        'outstanding',       app.cpd_outstanding_sentence(
                               m.core_points, m.core_required,
                               m.non_core_points, m.non_core_required)),
      m.person_id,
      null,
      jsonb_build_object('member_id', (a ->> 'member_id'), 'kind', 'cpd_review',
                         'entry_count', (a ->> 'n')));
  end loop;

  return v_count;
end;
$$;

revoke all on function public.review_cpd(uuid[], text, text) from public;
grant execute on function public.review_cpd(uuid[], text, text) to authenticated, service_role;

comment on function public.review_cpd(uuid[], text, text) is
  'Accepts or rejects a batch of pending CPD entries in one transaction and '
  'queues ONE letter per member, not one per entry. Entries that are no longer '
  'pending are skipped rather than overwritten, so two people working the queue '
  'at once cannot undo each other.';


-- -----------------------------------------------------------------------------
-- The receipt, off unless asked for
-- -----------------------------------------------------------------------------
-- A trigger and not a line inside log_cpd, because the office can record an
-- entry on a member's behalf and that route does not go through log_cpd. A
-- member should hear about their own record whichever door it came in by.
--
-- Self declared only. An entry AWARDED by AMI or arriving automatically is
-- accepted already and gets the acceptance letter, so a receipt saying it is
-- waiting to be reviewed would be plainly untrue.
create or replace function app.cpd_logged_receipt()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v record;
begin
  if new.how_recorded <> 'self_declared' or new.status <> 'pending' then
    return new;
  end if;

  select p.id as person_id,
         p.given_name,
         p.family_name,
         lower(btrim(coalesce(p.email, ''))) as email,
         pr.cpd_receipts,
         t.name  as activity_type,
         t.is_core
    into v
    from public.members m
    join public.people p on p.id = m.person_id
    join public.member_preferences pr on pr.member_id = m.id
    left join public.cpd_activity_types t on t.id = new.activity_type_id
   where m.id = new.member_id;

  if not found or not v.cpd_receipts or v.email = '' then
    return new;
  end if;

  perform app.queue_system_email(
    'cpd_logged',
    v.email,
    btrim(v.given_name || ' ' || v.family_name),
    jsonb_build_object(
      'given_name',  v.given_name,
      'title',       new.title,
      'points',      app.cpd_num(new.points),
      'core_or_non', case when new.is_core then 'core' else 'non core' end,
      'occurred_on', to_char(new.occurred_on, 'FMDD Month YYYY'),
      'year',        new.year::text),
    v.person_id,
    null,
    jsonb_build_object('cpd_entry_id', new.id, 'kind', 'cpd_logged'));

  return new;
end;
$$;

revoke all on function app.cpd_logged_receipt() from public;

drop trigger if exists cpd_entries_receipt on public.cpd_entries;
create trigger cpd_entries_receipt
  after insert on public.cpd_entries
  for each row execute function app.cpd_logged_receipt();


-- -----------------------------------------------------------------------------
-- The reminders
-- -----------------------------------------------------------------------------
-- Monthly from July, and only to somebody who is actually short. A member who
-- meets the requirement in August hears nothing for the rest of the year without
-- anybody switching anything off.
--
-- THIS TABLE IS THE GUARD, NOT THE QUERY. The obvious way to write this is to
-- ask "has this member already had a reminder this month" in the WHERE clause,
-- and that is wrong: two runs starting a second apart both read false and both
-- send. So the row is inserted FIRST, with the primary key doing the deciding,
-- and the letter is queued only if the insert actually inserted. A job that runs
-- twice by accident sends once.
create table if not exists public.cpd_reminder_log (
  member_id uuid not null references public.members(id) on delete cascade,
  year      integer not null,
  month     integer not null check (month between 1 and 12),
  sent_at   timestamptz not null default now(),
  primary key (member_id, year, month)
);

alter table public.cpd_reminder_log enable row level security;
grant select on public.cpd_reminder_log to authenticated;

create policy cpd_reminder_log_staff on public.cpd_reminder_log
  for select to authenticated
  using (app.is_membership_staff());

comment on table public.cpd_reminder_log is
  'One row per member per month a reminder was queued. The primary key is what '
  'stops a second run of the job sending a second copy, so the insert happens '
  'before the queueing and the queueing depends on it.';


create or replace function app.queue_cpd_reminders(
  p_on         date default current_date,
  p_quiet_days integer default 30
) returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_year  integer := extract(year  from p_on)::int;
  v_month integer := extract(month from p_on)::int;
  v_count integer := 0;
  r record;
begin
  -- Monthly from July. Nothing in the first half of the year, because a reminder
  -- in March is about a target nobody is behind on yet and it teaches people to
  -- ignore the ones in November.
  if v_month < 7 then
    return 0;
  end if;

  for r in
    select m.id                                as member_id,
           p.id                                as person_id,
           p.given_name,
           p.family_name,
           lower(btrim(coalesce(p.email, ''))) as email,
           coalesce(s.core_points, 0)          as core_points,
           coalesce(s.non_core_points, 0)      as non_core_points,
           q.core_required,
           q.non_core_required
      from public.members m
      join public.people             p  on p.id = m.person_id
      join public.member_preferences pr on pr.member_id = m.id
      join public.membership_grades  g  on g.id = m.grade_id
      join public.cpd_requirements   q  on q.grade_id = g.id and q.year = v_year
      left join public.cpd_year_summaries s on s.member_id = m.id and s.year = v_year
     where m.is_active
       and g.requires_cpd
       -- Associate has a row of zeroes rather than no row, which 0007 did on
       -- purpose. So an Associate is excluded by arithmetic here rather than by
       -- a special case naming a grade, and a grade added next year is handled
       -- by whatever its requirement says.
       and (q.core_required > 0 or q.non_core_required > 0)
       and pr.cpd_reminders
       and coalesce(p.email, '') <> ''
       and coalesce(s.requirement_met, false) = false
       -- A bounced address is NOT filtered out here. queue_message marks the row
       -- suppressed and says why, which is 0027's rule and is the more useful
       -- answer: an address that has been dead since June shows up in the office
       -- queue every month with a reason beside it, rather than being invisible.
       --
       -- The softener. Somebody who logged something in the last month is using
       -- the scheme and does not need chasing, and chasing them is how a
       -- reminder becomes junk. Pass 0 to switch it off.
       and not (p_quiet_days > 0 and exists (
                 select 1 from public.cpd_entries e
                  where e.member_id = m.id
                    and e.recorded_at >= (p_on - p_quiet_days)))
  loop
    insert into public.cpd_reminder_log (member_id, year, month)
    values (r.member_id, v_year, v_month)
    on conflict do nothing;

    -- Nothing inserted means somebody or something already sent this month's.
    continue when not found;

    perform app.queue_system_email(
      'cpd_reminder',
      r.email,
      btrim(r.given_name || ' ' || r.family_name),
      jsonb_build_object(
        'given_name',        r.given_name,
        'year',              v_year::text,
        'core_points',       app.cpd_num(r.core_points),
        'non_core_points',   app.cpd_num(r.non_core_points),
        'core_required',     app.cpd_num(r.core_required),
        'non_core_required', app.cpd_num(r.non_core_required),
        'outstanding',       app.cpd_outstanding_sentence(
                               r.core_points, r.core_required,
                               r.non_core_points, r.non_core_required),
        'months_left',       case
                               when v_month = 12
                                 then 'This is the last month of the CPD year.'
                               else 'There ' || case when 12 - v_month = 1 then 'is ' else 'are ' end
                                    || (12 - v_month)::text || ' month'
                                    || case when 12 - v_month = 1 then '' else 's' end
                                    || ' of the CPD year left.'
                             end),
      r.person_id,
      null,
      jsonb_build_object('kind', 'cpd_reminder', 'year', v_year, 'month', v_month));

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function app.queue_cpd_reminders(date, integer) from public;
revoke all on function app.queue_cpd_reminders(date, integer) from anon, authenticated;
grant execute on function app.queue_cpd_reminders(date, integer) to service_role;

comment on function app.queue_cpd_reminders(date, integer) is
  'Queues this month''s CPD reminders. Safe to run as often as you like: '
  'cpd_reminder_log''s primary key decides, not the query. Returns how many were '
  'queued, which is 0 before July and 0 on a day everybody is up to date.';


-- A thin public wrapper so a super user can run it by hand from the admin app
-- when something looks wrong, without holding the service role. PostgREST only
-- exposes the public schema, so without this the only way to run it is the SQL
-- editor.
create or replace function public.run_cpd_reminders(p_on date default current_date)
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not app.is_super_user() then
    raise exception 'Only a super user may run the CPD reminders by hand.'
      using errcode = '42501';
  end if;
  return app.queue_cpd_reminders(p_on);
end;
$$;

revoke all on function public.run_cpd_reminders(date) from public;
grant execute on function public.run_cpd_reminders(date) to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- The preference page, with and without a sign in
-- -----------------------------------------------------------------------------
-- Two ways in. Signed in, a member reads and writes member_preferences directly
-- and prefs_select_own and prefs_update_own decide, which is how the profile
-- page already works. From an unsubscribe link there is no session at all, so
-- these two functions take the token instead.
--
-- The token is a uuid, which is 122 bits of randomness. Enumerating one is not a
-- thing that happens. What these must not do is give away anything beyond what
-- the link holder already has, so the reader returns a first name and five
-- switches and no email address, no membership number and no name that would
-- confirm an identity to somebody who found the link in a forwarded message.
create or replace function public.preferences_by_token(p_token uuid)
returns table (
  given_name          text,
  bulletins           boolean,
  events              boolean,
  cpd_reminders       boolean,
  cpd_receipts        boolean,
  forum_notifications text)
language sql stable security definer set search_path = ''
as $$
  select p.given_name,
         pr.email_newsletter,
         pr.email_events,
         pr.cpd_reminders,
         pr.cpd_receipts,
         pr.forum_notifications
    from public.member_preferences pr
    join public.members m on m.id = pr.member_id
    join public.people  p on p.id = m.person_id
   where pr.unsubscribe_token = p_token;
$$;

revoke all on function public.preferences_by_token(uuid) from public;
grant execute on function public.preferences_by_token(uuid) to anon, authenticated, service_role;


-- Every change writes a consents row, which 0010 built and described as append
-- only in practice: a change of mind is a new row, so what somebody agreed to
-- and when is intact. That record is the answer if anybody ever asks why they
-- were still being emailed, and it is worth more than the switch itself.
create or replace function public.set_preferences_by_token(
  p_token         uuid,
  p_bulletins     boolean default null,
  p_events        boolean default null,
  p_cpd_reminders boolean default null,
  p_cpd_receipts  boolean default null,
  p_forum         text    default null
) returns boolean
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member uuid;
  v_person uuid;
  v_old    public.member_preferences%rowtype;
begin
  -- Two statements rather than one, because plpgsql will not put a record and a
  -- scalar in the same INTO list.
  select pr.* into v_old
    from public.member_preferences pr
   where pr.unsubscribe_token = p_token;

  if not found then
    return false;
  end if;
  v_member := v_old.member_id;

  select m.person_id into v_person
    from public.members m where m.id = v_member;

  if p_forum is not null and p_forum not in ('off', 'immediate', 'daily', 'weekly') then
    raise exception 'That is not a forum notification setting.' using errcode = '22023';
  end if;

  update public.member_preferences pr
     set email_newsletter    = coalesce(p_bulletins,     pr.email_newsletter),
         email_events        = coalesce(p_events,        pr.email_events),
         cpd_reminders       = coalesce(p_cpd_reminders, pr.cpd_reminders),
         cpd_receipts        = coalesce(p_cpd_receipts,  pr.cpd_receipts),
         forum_notifications = coalesce(p_forum,         pr.forum_notifications)
   where pr.member_id = v_member;

  insert into public.consents (person_id, kind, given, source)
  select v_person, k.kind, k.given, 'unsubscribe_link'
    from (values
      ('bulletins',           coalesce(p_bulletins,     v_old.email_newsletter)),
      ('events',              coalesce(p_events,        v_old.email_events)),
      ('cpd_reminders',       coalesce(p_cpd_reminders, v_old.cpd_reminders)),
      ('cpd_receipts',        coalesce(p_cpd_receipts,  v_old.cpd_receipts))
    ) as k(kind, given)
   where k.given is distinct from case k.kind
     when 'bulletins'     then v_old.email_newsletter
     when 'events'        then v_old.email_events
     when 'cpd_reminders' then v_old.cpd_reminders
     when 'cpd_receipts'  then v_old.cpd_receipts
   end;

  return true;
end;
$$;

revoke all on function public.set_preferences_by_token(uuid, boolean, boolean, boolean, boolean, text)
  from public;
grant execute on function public.set_preferences_by_token(uuid, boolean, boolean, boolean, boolean, text)
  to anon, authenticated, service_role;


-- One click, everything a member is allowed to refuse switched off. This is what
-- a List-Unsubscribe header will point at when there is one, and it is the
-- honest reading of somebody clicking "unsubscribe" rather than "preferences".
-- It cannot switch off a decision about their own membership, because nothing
-- can.
create or replace function public.unsubscribe_all_by_token(p_token uuid)
returns boolean
language sql volatile security definer set search_path = ''
as $$
  select public.set_preferences_by_token(p_token, false, false, false, false, 'off');
$$;

revoke all on function public.unsubscribe_all_by_token(uuid) from public;
grant execute on function public.unsubscribe_all_by_token(uuid) to anon, authenticated, service_role;


-- -----------------------------------------------------------------------------
-- What the office sees
-- -----------------------------------------------------------------------------
create or replace view public.admin_cpd_reminders
with (security_invoker = true) as
select l.year,
       l.month,
       count(*)      as members_reminded,
       max(l.sent_at) as last_sent
  from public.cpd_reminder_log l
 group by l.year, l.month
 order by l.year desc, l.month desc;

grant select on public.admin_cpd_reminders to authenticated;


-- =============================================================================
-- THE CLOCK, WHICH IS NOT IN THIS FILE
-- =============================================================================
-- Cloudflare Pages has no scheduled events, so the drain cannot be a cron
-- trigger on the site project and neither can this. The Worker already says so
-- in a comment and already names the answer: pg_cron and pg_net, both of which
-- the Supabase Pro plan has.
--
-- They are not created here because enabling an extension is a project level act
-- rather than a schema change, and because the drain URL is an address rather
-- than a fact about the database. README-0029.md has the four statements. Run
-- them once, in the SQL editor, after this migration.
--
-- The shape is two jobs:
--
--   nightly    select app.queue_cpd_reminders();
--              It decides for itself whether today is a reminder day, so the
--              schedule is dumb and the rule lives in one place.
--
--   every five select net.http_post(url := '<site>/api/mail/drain');
--   minutes    The drain takes no input that decides anything and a second
--              caller during a drain gets an empty batch, so calling it on a
--              timetable is safe and needs no secret.
-- =============================================================================
