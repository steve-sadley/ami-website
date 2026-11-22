-- =============================================================================
-- 0027  The email outbox, and the two decision emails
--
-- The application acknowledgement and the office notification are sent by the
-- Worker at the moment the form is submitted, because the Worker is where the
-- submission already is and the applicant is sitting there waiting for an answer.
-- A decision is not like that. Approving or refusing an application happens in
-- the admin app, hours or weeks later, and the admin app is a browser. A browser
-- must never hold the SMTP2GO key, so the browser cannot send the email.
--
-- So the decision does what the rest of this schema does with anything that
-- matters: it writes it down. approve_application and refuse_application queue a
-- message in the same transaction that records the decision, which means the
-- email cannot be lost by a network failure, cannot be sent twice by a double
-- click, and cannot be sent at all for a decision that was rolled back. The
-- Worker then drains the queue with the key it already holds.
--
-- Three consequences worth stating, because each one is the reason a simpler
-- design was rejected:
--
--   A message that fails is still there. It carries the reason and the number of
--   attempts, so a refusal that never reached the applicant is a row somebody
--   can find, rather than a thing nobody knows did not happen.
--
--   The wording lives in email_templates, which 0010 built and nothing has used
--   until now. The office can change what an approval says without a deployment
--   and without me.
--
--   The suppression list is honoured here, at the moment of queueing, and again
--   when the batch is claimed. 0010 says it is honoured on every send without
--   exception including service emails, and an address that bounces does not
--   stop bouncing because the message was important.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Escaping, in the database
-- -----------------------------------------------------------------------------
-- A template is HTML and the values substituted into it are not. An applicant's
-- own name goes into an approval email, and a decision note written by a member
-- of staff goes into a refusal, and neither has been through anything that would
-- make it safe to drop into markup. The Worker escapes everything it renders
-- itself; this is the same rule applied at the other place rendering happens.
create or replace function app.html_escape(t text)
returns text language sql immutable set search_path = ''
as $$
  select replace(replace(replace(replace(replace(
    coalesce(t, ''),
    '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

comment on function app.html_escape(text) is
  'Escapes a value on its way into an email body. Every substitution in '
  'app.render_email goes through this, with no way to opt out, because the one '
  'that opts out is the one that carries somebody else''s markup.';


-- -----------------------------------------------------------------------------
-- Rendering
-- -----------------------------------------------------------------------------
-- Placeholders are {{name}}. Anything the template asks for and the payload does
-- not carry becomes an empty string rather than the literal {{name}}, because a
-- member reading "Dear {{given_name}}" is worse than a member reading "Dear".
--
-- The substitution walks the PAYLOAD rather than scanning the template, so the
-- only things that can ever be substituted are values the calling function chose
-- to pass. A template cannot reach for a column nobody offered it.
create or replace function app.render_email(p_code text, p_vars jsonb)
returns table (subject text, html text, is_service boolean)
language plpgsql stable set search_path = ''
as $$
declare
  t public.email_templates%rowtype;
  k text;
  v text;
  s text;
  h text;
begin
  select * into t from public.email_templates where code = p_code;
  if not found then
    raise exception 'There is no email template with the code %.', p_code;
  end if;

  s := t.subject;
  h := t.html;

  for k, v in select key, value #>> '{}' from jsonb_each(coalesce(p_vars, '{}'::jsonb)) loop
    -- A value cannot itself contain a placeholder. jsonb_each returns keys in
    -- its own order rather than the order they were written, so a short key is
    -- substituted before a long one, and a decision note reading
    -- "see {{membership_number}}" would otherwise come out of the letter with a
    -- real membership number in it. Escaping does not help: the braces are not
    -- markup. So they are taken out of the value.
    v := replace(replace(coalesce(v, ''), '{{', ''), '}}', '');

    -- A subject line is not HTML, so it takes the value as typed. The body is,
    -- so it takes it escaped. Getting these the same way round is the whole
    -- point of doing it here rather than in four call sites.
    s := replace(s, '{{' || k || '}}', v);
    h := replace(h, '{{' || k || '}}', app.html_escape(v));
  end loop;

  -- Anything the template asked for that nobody supplied.
  s := regexp_replace(s, '\{\{[a-z0-9_]+\}\}', '', 'g');
  h := regexp_replace(h, '\{\{[a-z0-9_]+\}\}', '', 'g');

  -- A subject line goes into a header. A line break in one is how somebody adds
  -- headers of their own choosing, and a template is editable in the admin app.
  s := btrim(regexp_replace(s, '[\r\n]+', ' ', 'g'));

  subject := s;
  html := h;
  is_service := t.is_service;
  return next;
end;
$$;


-- -----------------------------------------------------------------------------
-- The outbox
-- -----------------------------------------------------------------------------
-- The rendered message rather than a reference to the template. A refusal sent
-- in March said what it said, and an office that rewrites the template in June
-- has not changed the letter somebody received. This is a record of what was
-- sent, so it holds what was sent.
create table public.email_outbox (
  id            uuid primary key default gen_random_uuid(),
  template_code text not null,
  to_email      text not null,
  to_name       text,
  subject       text not null,
  html          text not null,
  reply_to      text,
  person_id     uuid references public.people(id) on delete set null,
  context       jsonb not null default '{}'::jsonb,
  status        text not null default 'queued'
                check (status in ('queued', 'sending', 'sent', 'failed', 'suppressed')),
  attempts      int  not null default 0,
  last_error    text,
  provider_ref  text,
  queued_at     timestamptz not null default now(),
  claimed_at    timestamptz,
  sent_at       timestamptz
);

-- The drain asks for queued rows oldest first. Everything else is a person
-- looking at what went wrong.
create index email_outbox_pending on public.email_outbox (queued_at)
  where status in ('queued', 'sending');
create index email_outbox_person on public.email_outbox (person_id);

comment on table public.email_outbox is
  'Transactional email waiting to be sent, written in the same transaction as '
  'the thing it is about. A decision that was rolled back queues nothing; a '
  'decision that was committed queues exactly one message, however many times '
  'the button was pressed.';

comment on column public.email_outbox.attempts is
  'Incremented when a batch is claimed, not when a send succeeds, so a message '
  'that kills the sender cannot be retried forever. claim_email_batch will not '
  'return a row that has been tried three times.';


-- -----------------------------------------------------------------------------
-- Queueing
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER, and this one is the exception that proves the rule the rest
-- of the schema follows. Everything else here runs as the caller so the caller's
-- policies still apply. This runs as the owner because the outbox has no insert
-- policy for anybody at all: no browser may write a message that AMI will send
-- under its own name and its own sending domain.
--
-- Which makes the grant the thing to get right, and the first attempt got it
-- wrong. Revoking execute from everybody looks safe and is not: the decision
-- functions are SECURITY INVOKER, so they run as the member of staff who called
-- them, so the member of staff is the one who needs the privilege, and refusing
-- an application died with "permission denied for function queue_email". The
-- tests caught it, which is the argument for having them.
--
-- So the grant is wide and the RULE IS IN THE FUNCTION, which is what the rest
-- of this schema does everywhere else. is_membership_staff() is checked here as
-- well as in the two decision functions, because a redundant check is what makes
-- a wide grant safe, and without it any signed in member could send mail from
-- AMI's own domain to any address they liked.
--
-- SECURITY DEFINER changes the executing role. It does not change auth.uid(),
-- which is read from the request, so the check below is still asking about the
-- person who called and not about the owner. That is also why the check is
-- is_membership_staff() and not anything to do with current_user: inside a
-- security definer function current_user is the OWNER, so a role test there
-- would be asking the wrong question and would answer yes to everybody.
--
-- There is deliberately no service role branch. Nothing the Worker does queues a
-- message: the two application emails are sent inline at submission, because the
-- applicant is waiting for an answer and the Worker is already holding the
-- submission.
--
-- If that ever changes, note that the service role holds SELECT and UPDATE on
-- the outbox and nothing else. Bypassing row level security is not the same
-- thing as holding a privilege, and those two are easy to conflate: an INSERT
-- from the Worker today answers 42501 permission denied. Grant it deliberately
-- at that point rather than assuming it is already there.
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
declare
  r record;
  v_id uuid;
  v_status text := 'queued';
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may queue an email from AMI.'
      using errcode = '42501';
  end if;

  if coalesce(btrim(p_to_email), '') = '' then
    raise exception 'An email needs somewhere to go.';
  end if;

  select * into r from app.render_email(p_code, p_vars);

  -- Recorded rather than skipped. A refusal that was never sent because the
  -- address bounces is something the office needs to know about, and a row
  -- marked suppressed says so. Dropping it silently says nothing.
  if exists (select 1 from public.suppression_list
              where lower(email) = lower(btrim(p_to_email))) then
    v_status := 'suppressed';
  end if;

  insert into public.email_outbox
    (template_code, to_email, to_name, subject, html, reply_to,
     person_id, context, status)
  values
    (p_code, lower(btrim(p_to_email)), p_to_name, r.subject, r.html, p_reply_to,
     p_person_id, coalesce(p_context, '{}'::jsonb), v_status)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function app.queue_email(text, text, text, jsonb, uuid, text, jsonb) from public;
grant execute on function app.queue_email(text, text, text, jsonb, uuid, text, jsonb)
  to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- Draining, for the Worker
-- -----------------------------------------------------------------------------
-- FOR UPDATE SKIP LOCKED, and the status moved to 'sending' before the rows are
-- handed out, so two drains running at once cannot both pick up the same message
-- and send it twice. An applicant receiving two refusals is worse than one
-- receiving none late.
--
-- These three are SECURITY INVOKER and the GRANT is the whole lock. That is the
-- opposite of queue_email above and it is right for the opposite reason: the
-- service role already bypasses row level security, so it needs no help from a
-- definer, and running as the caller means a browser calling this gets
-- "permission denied for function", which is the true answer. Writing a role
-- check inside a definer function would have been asking current_user, and
-- inside a definer function current_user is the owner.
create or replace function public.claim_email_batch(p_limit int default 20)
returns table (id uuid, to_email text, to_name text, subject text,
               html text, reply_to text)
language plpgsql volatile set search_path = ''
as $$
begin
  -- An address can be suppressed AFTER a message was queued for it. Marking the
  -- row rather than merely skipping it: skipping leaves a letter sitting at
  -- 'queued' with no error, forever, looking to the office exactly like one that
  -- is about to go out. The first version of this did that, and it contradicted
  -- the thing queue_email gets right two hundred lines up.
  update public.email_outbox o
     set status = 'suppressed',
         last_error = 'That address was added to the suppression list after this '
                   || 'message was queued, so it was never sent.'
   where o.status in ('queued', 'sending')
     and exists (select 1 from public.suppression_list s
                  where lower(s.email) = o.to_email);

  return query
  with picked as (
    select o.id from public.email_outbox o
     where o.status in ('queued', 'sending')
       and o.attempts < 3
       -- A message being retried waits five minutes, so a provider having a bad
       -- minute is not hammered and a stuck 'sending' row is picked up again.
       and (o.claimed_at is null or o.claimed_at < now() - interval '5 minutes')
     order by o.queued_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked
  )
  update public.email_outbox o
     set status = 'sending', attempts = o.attempts + 1, claimed_at = now()
    from picked
   where o.id = picked.id
  returning o.id, o.to_email, o.to_name, o.subject, o.html, o.reply_to;
end;
$$;

revoke all on function public.claim_email_batch(int) from public;
grant execute on function public.claim_email_batch(int) to service_role;

create or replace function public.mark_email_sent(p_id uuid, p_ref text default null)
returns void language plpgsql volatile set search_path = ''
as $$
begin
  -- Only a row that was actually handed out. Without this a Worker bug can mark
  -- a message sent that was never claimed, or re-settle one that already went,
  -- and either way the queue stops being a record of what happened.
  update public.email_outbox
     set status = 'sent', sent_at = now(), provider_ref = p_ref, last_error = null
   where id = p_id and status = 'sending';
end;
$$;

revoke all on function public.mark_email_sent(uuid, text) from public;
grant execute on function public.mark_email_sent(uuid, text) to service_role;

-- A message goes back to 'queued' until it has been tried three times, and only
-- then to 'failed'. The count is what decides, not the caller, so a sender with
-- a bug cannot mark something failed on the first attempt and cannot retry it
-- forever either.
create or replace function public.mark_email_failed(p_id uuid, p_error text)
returns void language plpgsql volatile set search_path = ''
as $$
begin
  update public.email_outbox
     set status = case when attempts >= 3 then 'failed' else 'queued' end,
         last_error = left(coalesce(p_error, 'no reason given'), 500)
   where id = p_id and status = 'sending';
end;
$$;

revoke all on function public.mark_email_failed(uuid, text) from public;
grant execute on function public.mark_email_failed(uuid, text) to service_role;


-- -----------------------------------------------------------------------------
-- Who may look
-- -----------------------------------------------------------------------------
-- Enabled and not forced, like the other eight in 0018. The functions above are
-- security definer and run as the owner, and forcing would bind the owner and
-- stop every one of them working with no error anywhere.
alter table public.email_outbox enable row level security;

grant select on public.email_outbox to authenticated;

-- The three drain functions run as the caller, so the caller needs the table
-- privilege as well as the function. Only the service role holds it, and only
-- the Worker holds the service role.
--
-- The service role bypasses row level security. It does not bypass a GRANT, and
-- those are two different things that are easy to conflate. claim_email_batch
-- re-checks the suppression list as it hands rows out, so it needs to be able to
-- read it: an address can be suppressed AFTER a message was queued for it, which
-- is exactly the case the check exists for.
grant select, update on public.email_outbox to service_role;
grant select on public.suppression_list to service_role;

-- Membership staff may read the queue, because chasing a refusal that did not
-- arrive is their job. Nobody may insert, update or delete from a browser at
-- all: there is no policy for those and no grant either, which is two locks
-- rather than one.
create policy outbox_staff_read on public.email_outbox
  for select to authenticated
  using (app.is_membership_staff());

comment on policy outbox_staff_read on public.email_outbox is
  'A queued message can carry an applicant''s name, their address and the reason '
  'their application was refused, so it is membership staff and nobody else. A '
  'member cannot read their own, because there is nothing in it they were not '
  'already sent.';


-- -----------------------------------------------------------------------------
-- A service template is not content
-- -----------------------------------------------------------------------------
-- 0010 gave editors write access to every email template, which was harmless
-- while nothing used the table. This migration makes it the source of letters
-- AMI sends from its own domain about somebody's membership, and that changes
-- what the grant means.
--
-- An editor is a role for news, guidance and page copy. It carries no membership
-- privileges at all. Without this, an editor could rewrite application_refused
-- to add a link of their choosing and the next refusal a membership officer
-- issued would carry it, under AMI's name, to somebody who has every reason to
-- trust it. Nothing about the decision would look wrong.
--
-- So a template marked is_service belongs to super users. Marketing templates
-- stay with editors, which is what 0010 meant by the distinction and what the
-- comment on that column already says: the distinction has to hold in the data
-- rather than only in the sending code.
drop policy if exists templates_write  on public.email_templates;
drop policy if exists templates_update on public.email_templates;

create policy templates_write on public.email_templates
  for insert to authenticated
  with check ((select app.is_editor()) and (is_service is not true or (select app.is_super_user())));

create policy templates_update on public.email_templates
  for update to authenticated
  using ((select app.is_editor()) and (is_service is not true or (select app.is_super_user())))
  with check ((select app.is_editor()) and (is_service is not true or (select app.is_super_user())));

comment on table public.email_templates is
  'The wording of what AMI sends. A template marked is_service is a letter about '
  'somebody''s own membership and only a super user may change one, because an '
  'editor is a content role and a refusal letter is not content.';


-- -----------------------------------------------------------------------------
-- The two templates
-- -----------------------------------------------------------------------------
-- is_service is true on both. A decision on somebody's own application is not
-- marketing and cannot be opted out of, which 0010 says has to hold in the data
-- rather than only in the sending code.
--
-- The wording is deliberately plain and promises nothing that is not true. The
-- approval does not say welcome to the register, because a new member is created
-- inactive and is switched on by hand once the fee is paid. Saying otherwise
-- would have somebody looking for themselves on a register they are not on yet.
insert into public.email_templates (code, name, subject, html, is_service) values
(
  'application_approved',
  'Application approved',
  'Your AMI membership application has been approved, {{reference}}',
  '<p>Dear {{given_name}},</p>
   <p>Your application for membership of the Asbestos Management Institute, reference
      <b>{{reference}}</b>, has been approved.</p>
   <p>Your membership number is <b>{{membership_number}}</b>. Please quote it in anything
      you send the office.</p>
   <p>An invoice for the first year''s subscription is on its way to the invoicing address
      you gave. Your membership becomes active, and your record appears on the public
      register, once that has been settled. You will be sent your sign in details at the
      same time.</p>
   <p>{{note}}</p>
   <p>If anything here looks wrong, reply to this message and the office will put it right.</p>',
  true
),
(
  'application_refused',
  'Application refused',
  'Your AMI membership application, {{reference}}',
  '<p>Dear {{given_name}},</p>
   <p>Thank you for applying for membership of the Asbestos Management Institute. Your
      application, reference <b>{{reference}}</b>, has been considered and on this occasion
      it has not been successful.</p>
   <p>The reason is this:</p>
   <blockquote style="border-left:3px solid #ddd;margin:0;padding-left:16px;color:#555">
     {{note}}
   </blockquote>
   <p>This is not a permanent bar. You are welcome to apply again once the position has
      changed, and the office is happy to talk through what would be needed.</p>
   <p>Reply to this message if you would like to discuss it.</p>',
  true
)
on conflict (code) do nothing;


-- -----------------------------------------------------------------------------
-- Hooking the decisions up
-- -----------------------------------------------------------------------------
-- Both functions are replaced rather than triggered, and that is on purpose. A
-- trigger on membership_applications would fire for every route into the table,
-- including a correction made by hand in the SQL editor, and emailing somebody a
-- refusal because a typo was fixed is exactly the kind of thing a trigger does
-- and nobody expects. The email belongs to the decision, so it is written where
-- the decision is written.

-- THE OVERLOAD THAT NEARLY SWALLOWED THIS WHOLE FEATURE
--
-- app.approve_application exists twice. 0006 wrote a five argument version that
-- took an auth user id, and 0017 wrote a four argument version that does not,
-- because 0017 is where a person stopped being a login. 0017 did not drop the
-- old one, and nothing calls it: public.approve_application passes four.
--
-- The email hook went onto the five argument version first. Every one of the
-- thirty admin tests still passed, the migration applied cleanly, and no
-- approval would ever have sent an email, because the function it was attached
-- to is dead code. It surfaced only because a new test called the wrapper and
-- the argument count did not match.
--
-- So the dead one goes. An overload nobody calls is not harmless: it is a
-- function that will be found by somebody reading the schema, edited in good
-- faith, and have no effect at all.
drop function if exists app.approve_application(uuid, uuid, text, date, text);

-- This is the 0017 body, unchanged, with the queue at the end of it.
create or replace function app.approve_application(
  p_application_id    uuid,
  p_membership_number text,
  p_joined_on         date default current_date,
  p_note              text default null
) returns uuid
language plpgsql
-- SECURITY INVOKER on purpose: it runs as the member of staff who called it, so
-- every row it writes is written under their own policies and appears in the
-- audit log under their name.
set search_path = ''
as $$
declare
  a public.membership_applications%rowtype;
  v_person_id uuid;
  v_member_id uuid;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may approve an application.' using errcode = '42501';
  end if;

  select * into a from public.membership_applications where id = p_application_id;
  if not found then
    raise exception 'Application % not found.', p_application_id;
  end if;
  if a.status not in ('submitted', 'under_review') then
    raise exception 'Application % is %, so it cannot be approved.', a.reference, a.status;
  end if;

  -- reuse a person record if this address is already known, otherwise create one.
  -- No account is created and none is needed.
  select id into v_person_id from public.people where lower(email) = lower(a.email) limit 1;
  if v_person_id is null then
    insert into public.people (given_name, family_name, email, mobile)
    values (a.given_name, a.family_name, a.email, a.telephone)
    returning id into v_person_id;
  end if;

  insert into public.members
    (person_id, membership_number, grade_id, employer_id, current_job_title,
     joined_on, is_active, status)
  values
    (v_person_id, p_membership_number, a.grade_id, a.employer_id, a.job_title,
     p_joined_on, false, 'applicant')
  returning id into v_member_id;

  insert into public.member_preferences (member_id) values (v_member_id);

  update public.membership_applications
     set status = 'approved', decided_at = now(), decided_by = app.person_id(),
         decision_note = p_note, member_id = v_member_id, person_id = v_person_id
   where id = p_application_id;

  insert into public.application_events (application_id, from_status, to_status, actor_id, note)
  values (p_application_id, a.status, 'approved', app.person_id(), p_note);

  -- New in 0027. Inside the transaction, so an approval that fails after this
  -- point sends nothing, and an approval that succeeds sends exactly one however
  -- many times the button was pressed.
  perform app.queue_email(
    'application_approved',
    a.email,
    btrim(a.given_name || ' ' || a.family_name),
    jsonb_build_object(
      'given_name',        a.given_name,
      'family_name',       a.family_name,
      'reference',         a.reference,
      'membership_number', p_membership_number,
      'note',              coalesce(p_note, '')),
    v_person_id,
    null,
    jsonb_build_object('application_id', p_application_id, 'member_id', v_member_id));

  return v_member_id;
end;
$$;

revoke all on function app.approve_application(uuid, text, date, text) from public;
grant execute on function app.approve_application(uuid, text, date, text)
  to authenticated, service_role;


create or replace function public.refuse_application(
  p_application_id uuid,
  p_note           text
) returns void
language plpgsql volatile set search_path = ''
as $$
declare a public.membership_applications%rowtype;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may refuse an application.' using errcode = '42501';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'A refusal needs a reason. It goes to the applicant and it is the record.';
  end if;

  select * into a from public.membership_applications where id = p_application_id;
  if not found then
    raise exception 'Application % not found.', p_application_id;
  end if;
  if a.status not in ('submitted', 'under_review') then
    raise exception 'Application % is %, so it cannot be refused.', a.reference, a.status;
  end if;

  update public.membership_applications
     set status = 'refused', decided_at = now(), decided_by = app.person_id(),
         decision_note = p_note
   where id = p_application_id;

  -- app.person_id() and NOT auth.uid(). Since 0017 a person is not a login and
  -- the two are different values, and actor_id is a foreign key to people(id),
  -- so auth.uid() here raises 23503 and takes the whole refusal down with it.
  -- 0025 fixed exactly this in the audit trigger. It went back in here while
  -- this function was being retyped, and the fixtures hid it because they give a
  -- person the same id for both. Test 05 now gives them different ones.
  insert into public.application_events (application_id, from_status, to_status, actor_id, note)
  values (p_application_id, a.status, 'refused', app.person_id(), p_note);

  -- The reason is not optional above, and this is why. It is the record, and it
  -- is also the letter: the note the member of staff typed is the note the
  -- applicant reads, escaped on its way into the body.
  perform app.queue_email(
    'application_refused',
    a.email,
    btrim(a.given_name || ' ' || a.family_name),
    jsonb_build_object(
      'given_name',  a.given_name,
      'family_name', a.family_name,
      'reference',   a.reference,
      'note',        p_note),
    a.person_id,
    null,
    jsonb_build_object('application_id', p_application_id));
end;
$$;

revoke all on function public.refuse_application(uuid, text) from public;
grant execute on function public.refuse_application(uuid, text) to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- What the office sees
-- -----------------------------------------------------------------------------
-- Security invoker, so the policy above is what restricts it and the view cannot
-- become a way round it. The body is not in here: it is long, it is HTML, and
-- what somebody chasing a message needs is who, what, when and why not.
create or replace view public.admin_email_queue
with (security_invoker = true) as
select o.id,
       o.template_code,
       o.to_email,
       o.to_name,
       o.subject,
       o.status,
       o.attempts,
       o.last_error,
       o.queued_at,
       o.sent_at,
       o.context
  from public.email_outbox o
 order by o.queued_at desc;

grant select on public.admin_email_queue to authenticated;
