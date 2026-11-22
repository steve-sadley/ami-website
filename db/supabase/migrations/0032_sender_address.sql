-- =============================================================================
-- 0032  A bulletin comes FROM the address it asks you to reply to
--
-- The first real bulletin went out on 15 August and arrived from
-- no-reply@ami.uk.com, carrying bulletin@ami.uk.com on the Reply-To. A reply
-- does reach the right mailbox, so this was not broken. It was contradictory: a
-- member reading "no-reply" and being invited to write back has been told two
-- things, and some clients do not show a Reply-To at all.
--
-- The Worker cannot decide this for itself. claim_email_batch hands it an
-- address, a subject and a body and nothing about what kind of message it is
-- holding, which is right: the Worker's job is to send what it is given. So the
-- decision belongs where the message is written down, and the outbox gains a
-- column for it.
--
-- ONE PLACE DECIDES, and it is a list of template codes rather than a new
-- argument on five call sites. Adding an argument would have meant retyping
-- send_campaign, send_campaign_test and queue_content_digest, each of which is
-- long, none of which is otherwise changing, and every one of which is a chance
-- to move a check by accident. That has happened twice on this project already.
-- =============================================================================

alter table public.email_outbox
  add column if not exists from_email text;

comment on column public.email_outbox.from_email is
  'The address this goes out FROM, where it should not be the default. Null '
  'means the Worker uses its own CONTACT_FROM binding, which is right for a '
  'decision letter: nobody replies to an approval. A bulletin is different and '
  'says so here.';


-- -----------------------------------------------------------------------------
-- Which messages come from the bulletin address
-- -----------------------------------------------------------------------------
-- A separate function rather than a case expression buried in queue_message, so
-- that adding a new kind of mailing is one line in one place and so a test can
-- ask the question directly.
create or replace function app.from_address_for(p_code text) returns text
language sql stable set search_path = ''
as $$
  select case
    when p_code in ('bulletin', 'bulletin_test', 'content_digest')
      then nullif(btrim(app.setting('bulletin_from')), '')
    else null
  end;
$$;

revoke all on function app.from_address_for(text) from public;

comment on function app.from_address_for(text) is
  'Null for anything that is a notice about somebody''s own membership, because '
  'nobody replies to an approval and no-reply is honest there. The bulletin '
  'address for anything sent to a list, because those invite a reply and saying '
  'no-reply while asking for one is telling somebody two things.';


-- -----------------------------------------------------------------------------
-- queue_message, with the sender stamped on the way in
-- -----------------------------------------------------------------------------
-- The same eight arguments as 0029. Deliberately: a ninth with a default would
-- have created an overload rather than replacing this, and 0027 already paid for
-- the lesson that an overload nobody calls is not harmless. It is found by
-- somebody reading the schema, edited in good faith, and has no effect at all.
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

  if exists (select 1 from public.suppression_list where lower(email) = v_to) then
    v_status := 'suppressed';
  end if;

  insert into public.email_outbox
    (template_code, to_email, to_name, subject, html, reply_to,
     person_id, context, status, from_email)
  values
    (p_code, v_to, p_to_name, p_subject, p_html, p_reply_to,
     p_person_id, coalesce(p_context, '{}'::jsonb), v_status,
     app.from_address_for(p_code))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function app.queue_message(text, text, text, text, text, uuid, text, jsonb)
  from public;


-- -----------------------------------------------------------------------------
-- Handing it to the Worker
-- -----------------------------------------------------------------------------
-- DROPPED and recreated rather than replaced. A create or replace cannot change
-- the return type of a function, and this one gains two columns. Dropping loses
-- the grant with it, which 0026 learned the hard way on a view, so the grant is
-- restated immediately below and not left to be noticed later.
--
-- template_code goes across as well as from_email. The Worker does not need it
-- today, because the sender is already decided, but a log line saying "sent" is
-- worth very little and a log line saying "sent cpd_reminder" is worth a great
-- deal at four o'clock on the afternoon somebody rings up.
drop function if exists public.claim_email_batch(int);

create or replace function public.claim_email_batch(p_limit int default 20)
returns table (id uuid, to_email text, to_name text, subject text,
               html text, reply_to text, from_email text, template_code text)
language plpgsql volatile set search_path = ''
as $$
begin
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
       and (o.claimed_at is null or o.claimed_at < now() - interval '5 minutes')
     order by o.queued_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked
  )
  update public.email_outbox o
     set status = 'sending', attempts = o.attempts + 1, claimed_at = now()
    from picked
   where o.id = picked.id
  returning o.id, o.to_email, o.to_name, o.subject, o.html, o.reply_to,
            o.from_email, o.template_code;
end;
$$;

revoke all on function public.claim_email_batch(int) from public;
grant execute on function public.claim_email_batch(int) to service_role;


-- -----------------------------------------------------------------------------
-- Anything already queued
-- -----------------------------------------------------------------------------
-- A bulletin queued before this migration has a null from_email and would go out
-- from no-reply. There are unlikely to be any, and filling them in costs one
-- statement.
update public.email_outbox
   set from_email = app.from_address_for(template_code)
 where from_email is null
   and status in ('queued', 'sending')
   and template_code in ('bulletin', 'bulletin_test', 'content_digest');


-- =============================================================================
-- WHAT THE WORKER DOES WITH IT, so that this file explains the whole change
-- =============================================================================
-- The Worker uses from_email when there is one and falls back to CONTACT_FROM
-- when there is not. It also refuses an address whose domain is not the same as
-- CONTACT_FROM's, and answers with the default instead.
--
-- That guard is not because the database is untrusted. It is because SMTP2GO
-- will only send for a verified domain, so an address on any other domain is a
-- message that fails at the provider with a reason nobody reads, rather than a
-- message that arrives looking slightly wrong. One of those is recoverable by
-- the office and the other is not.
--
-- It also means bulletin_from can be set to something silly in system_settings
-- without anybody being able to make AMI's own domain send for somebody else.
-- =============================================================================
