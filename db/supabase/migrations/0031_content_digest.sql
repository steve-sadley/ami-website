-- =============================================================================
-- 0031  The daily digest: telling members what AMI has published
--
-- Asked for on 15 August as "email members every time we publish". It is built
-- as ONE email a day rather than one per item, and that is a change worth
-- defending rather than a liberty taken.
--
-- Four news items published on a Tuesday afternoon is four emails inside an hour
-- to every member on the list. That is the single most reliable way to make
-- somebody switch the newsletter off, and once they have switched it off they
-- have also switched off the one about the thing they did care about. A digest
-- costs the office nothing, reaches the same people with the same information,
-- and on a quiet day sends nothing at all.
--
-- FOUR THINGS THAT MADE THIS MORE THAN A TRIGGER:
--
--   A published article is not the same as a public one. Content can be
--   published with a date in the future, which is how you write something on
--   Saturday and let it out on Monday. So the digest asks what is public NOW,
--   not what was saved, and Monday's readers get Monday's email.
--
--   Editing must not resend. Every item carries notified_at, set when it goes
--   into a digest, so an item is announced once however many times it is
--   afterwards corrected. Same shape as cpd_reminder_log, and for the same
--   reason: the column is the guard, not a clause in the query.
--
--   Two switches, one email. News, guidance and videos answer to
--   email_newsletter and events answer to email_events, because those are the
--   two preferences members were given. Somebody who takes only events gets a
--   digest containing only events, and somebody who takes neither gets nothing.
--
--   The staging guard applies here too. Publishing an article on a staging
--   deployment must not mail the membership, and it would be a poor sort of
--   guard that covered the button somebody presses deliberately and not the job
--   that runs itself at half past six.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- What is_service actually means, said properly
-- -----------------------------------------------------------------------------
-- 0010 defined it as "a letter that cannot be opted out of" and 0027 used it as
-- "a letter only a super user may reword". Those are two different ideas and
-- nothing in the schema has ever enforced the first: whether a member can refuse
-- something is decided by the columns on member_preferences, one switch at a
-- time, and never by this flag.
--
-- The digest forces the question. A member CAN switch it off, so by 0010's
-- reading it is not a service email and an editor could rewrite it. But it goes
-- to the whole membership from AMI's own domain and carries the unsubscribe
-- link, which is exactly the wording an editor should not be able to touch.
--
-- So the flag keeps the meaning 0027 gave it and the comment is corrected rather
-- than the behaviour. Nothing changes in code; a sentence stops being wrong.
comment on column public.email_templates.is_service is
  'AMI''s own operational wording: only a super user may change it. It says '
  'nothing about whether a member can refuse the email, which is decided by the '
  'switches on member_preferences one at a time. 0010 defined this column the '
  'other way round and nothing ever enforced that reading.';


-- -----------------------------------------------------------------------------
-- Announced once
-- -----------------------------------------------------------------------------
alter table public.news_articles      add column if not exists notified_at timestamptz;
alter table public.events             add column if not exists notified_at timestamptz;
alter table public.guidance_documents add column if not exists notified_at timestamptz;
alter table public.videos             add column if not exists notified_at timestamptz;

comment on column public.news_articles.notified_at is
  'When this went into a digest. Set once and never cleared by anything here, so '
  'correcting a typo in a published article does not announce it a second time. '
  'Clear it by hand if you genuinely want an item announced again.';

-- Anything already published when this migration runs is treated as already
-- announced. Without this the first digest would be a list of everything AMI has
-- ever published, which is not the introduction anybody wants.
update public.news_articles      set notified_at = now() where notified_at is null;
update public.events             set notified_at = now() where notified_at is null;
update public.guidance_documents set notified_at = now() where notified_at is null;
update public.videos             set notified_at = now() where notified_at is null;


-- -----------------------------------------------------------------------------
-- Where the pictures live
-- -----------------------------------------------------------------------------
-- The database has never needed to know the storage address before, because
-- every page that shows a picture is a browser that already has it. An email is
-- not, so it goes in settings beside the site address, and for the same reason:
-- it differs between projects and it is a thing somebody would otherwise hard
-- code and forget.
insert into public.system_settings (key, value, note) values
  ('media_url', 'https://ttjvwxxtoidiiejyqmbc.supabase.co/storage/v1/object/public/public-media/',
   'Where a content picture is fetched from in an email. Public bucket, so no '
   'signing is needed and an ordinary image tag works.')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- The wording, with a marker in it
-- -----------------------------------------------------------------------------
-- The items cannot be substituted in as a variable, because app.render_parts
-- escapes every value with no way to opt out and the caller that wants an
-- exception is exactly the caller that should not have one. So the template is
-- SPLIT on a marker and the generated list is put between the halves. The office
-- can reword everything above and below it without ever being able to inject
-- markup into an item.
insert into public.email_templates (code, name, subject, html, is_service) values
(
  'content_digest',
  'What is new at AMI',
  'New from AMI: {{headline}}',
  '<p>Dear {{given_name}},</p>
   <p>This is what AMI has published since the last one of these.</p>
   <!--ITEMS-->
   <p style="margin-top:22px">Everything here is on the website, where the full
      version of each item lives.</p>
   <p style="color:#777;font-size:13px;margin-top:24px">
     You are getting this because you asked AMI to keep you up to date.
     <a href="{{unsubscribe_url}}">Change what AMI sends you</a>.
     Decisions about your own membership will still reach you.</p>',
  true
)
on conflict (code) do nothing;


-- -----------------------------------------------------------------------------
-- One item, as a block of HTML
-- -----------------------------------------------------------------------------
-- Every value escaped on the way in, by hand, because this is the one place in
-- the schema that builds markup rather than substituting into it.
--
-- Tables and inline styles rather than anything modern, because an email is
-- rendered by Outlook as often as not and Outlook uses Word to do it. And the
-- picture is at the top with the words underneath rather than beside them, so
-- the block still reads properly when images are blocked, which they are by
-- default in most clients.
create or replace function app.digest_item_html(
  p_kind    text,
  p_title   text,
  p_meta    text,
  p_summary text,
  p_url     text,
  p_image   text,
  p_locked  boolean default false
) returns text
language sql stable set search_path = ''
as $$
  select
    '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" '
    || 'style="margin:0 0 22px"><tr><td style="padding:0 0 14px;border-bottom:1px solid #e5e5e5">'
    || case when coalesce(p_image, '') = '' then ''
            else '<a href="' || app.html_escape(p_url) || '">'
                 || '<img src="' || app.html_escape(app.setting('media_url') || p_image) || '" '
                 || 'alt="" width="560" style="width:100%;max-width:560px;height:auto;'
                 || 'border-radius:8px;display:block;margin:0 0 12px" /></a>'
       end
    || '<div style="font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:#b3121b;'
    || 'font-weight:700;margin:0 0 4px">' || app.html_escape(p_kind) || '</div>'
    || '<div style="font-size:17px;font-weight:700;margin:0 0 4px">'
    || '<a href="' || app.html_escape(p_url) || '" style="color:#1c1f24;text-decoration:none">'
    || app.html_escape(p_title) || '</a></div>'
    || case when coalesce(p_meta, '') = '' then ''
            else '<div style="font-size:13px;color:#666;margin:0 0 6px">'
                 || app.html_escape(p_meta) || '</div>' end
    || case when coalesce(p_summary, '') = '' then ''
            else '<div style="font-size:14px;line-height:1.55;color:#333">'
                 || app.html_escape(left(p_summary, 400)) || '</div>' end
    || case when p_locked then '<div style="font-size:13px;color:#666;margin-top:6px">'
                              || 'Members only. Sign in to read it.</div>'
            else '' end
    || '</td></tr></table>';
$$;

revoke all on function app.digest_item_html(text, text, text, text, text, text, boolean) from public;


-- -----------------------------------------------------------------------------
-- What has not been announced yet
-- -----------------------------------------------------------------------------
-- PUBLIC NOW rather than saved as published. published_at is allowed to be in
-- the future and that is a feature: it is how the office writes something on
-- Saturday and lets it out on Monday. An item with a future date is simply not
-- yet due and stays in this list until it is.
--
-- An event is dated by starts_at as well, and a published event whose date has
-- already gone is not news. It is excluded rather than announced late, because
-- an email inviting somebody to last Thursday is worse than no email.
create or replace function app.pending_digest_items()
returns table (kind text, sort_at timestamptz, html text, title text,
               table_name text, item_id uuid)
language sql stable security definer set search_path = ''
as $$
  with base as (
    select 'News'  as kind, n.published_at as sort_at, n.title,
           nullif(btrim(coalesce(n.category, '')), '') as meta,
           n.summary, n.image_path, false as locked,
           app.setting('site_url') || '/article?kind=news&slug=' || n.slug as url,
           'news_articles' as table_name, n.id as item_id
      from public.news_articles n
     where n.status = 'published' and n.published_at is not null
       and n.published_at <= now() and n.notified_at is null

    union all
    select 'Event', e.published_at, e.title,
           to_char(e.starts_at, 'FMDD Month YYYY')
             || case when coalesce(btrim(e.location), '') = '' then ''
                     else ', ' || e.location end,
           e.description, null, e.members_only,
           app.setting('site_url') || '/article?kind=event&slug=' || e.slug,
           'events', e.id
      from public.events e
     where e.status = 'published' and e.published_at is not null
       and e.published_at <= now() and e.notified_at is null
       and e.starts_at >= now()

    union all
    select 'Guidance', g.published_at, g.title,
           nullif(btrim(coalesce(g.category, '')), ''),
           g.summary, null, g.members_only,
           app.setting('site_url') || '/article?kind=guidance&slug=' || g.slug,
           'guidance_documents', g.id
      from public.guidance_documents g
     where g.status = 'published' and g.published_at is not null
       and g.published_at <= now() and g.notified_at is null

    union all
    select 'Video', v.published_at, v.title,
           nullif(btrim(coalesce(v.category, '')), ''),
           v.description, v.image_path, v.members_only,
           app.setting('site_url') || '/article?kind=video&slug=' || v.slug,
           'videos', v.id
      from public.videos v
     where v.status = 'published' and v.published_at is not null
       and v.published_at <= now() and v.notified_at is null
  )
  select b.kind, b.sort_at,
         app.digest_item_html(b.kind, b.title, b.meta, b.summary, b.url,
                              b.image_path, b.locked),
         b.title, b.table_name, b.item_id
    from base b
   order by b.sort_at desc;
$$;

revoke all on function app.pending_digest_items() from public;


-- A view so the office can see what the next digest would contain, without
-- running anything and without sending anything.
create or replace view public.admin_digest_pending
with (security_invoker = true) as
select d.kind, d.title, d.sort_at as published_at
  from app.pending_digest_items() d
 where (select app.is_staff());

grant select on public.admin_digest_pending to authenticated;


-- -----------------------------------------------------------------------------
-- Sending it
-- -----------------------------------------------------------------------------
-- Once a day, from a scheduled job, so nobody presses anything and auth.uid() is
-- null. That is what app.queue_system_email exists for and why its grant is the
-- only thing restraining it.
--
-- Returns how many members were written to, so a run that reached nobody is
-- distinguishable from a run that had nothing to say.
create or replace function app.queue_content_digest()
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_items    record;
  v_news     text := '';
  v_events   text := '';
  v_n_count  integer := 0;
  v_e_count  integer := 0;
  v_headline text := '';
  t          public.email_templates%rowtype;
  v_top      text;
  v_bottom   text;
  v_marker   text := '<!--ITEMS-->';
  r          record;
  rr         record;
  v_env      text := app.setting('environment');
  v_allow    text[];
  v_sent     integer := 0;
  v_withheld integer := 0;
  v_body     text;
begin
  -- Two buckets, because the two preferences are separate and a member who takes
  -- only events must not be sent the news to prove a point.
  for v_items in select * from app.pending_digest_items() loop
    if v_items.kind = 'Event' then
      v_events := v_events || v_items.html;
      v_e_count := v_e_count + 1;
    else
      v_news := v_news || v_items.html;
      v_n_count := v_n_count + 1;
    end if;
    if v_headline = '' then v_headline := v_items.title; end if;
  end loop;

  if v_n_count + v_e_count = 0 then
    return jsonb_build_object('items', 0, 'sent', 0, 'withheld', 0);
  end if;

  select * into t from public.email_templates where code = 'content_digest';
  if not found then
    raise exception 'The content_digest template is missing.';
  end if;

  -- Split rather than substitute. app.render_parts escapes every value it puts
  -- into a body, so passing the item list as a variable would deliver it as
  -- visible angle brackets. The halves either side of the marker are the
  -- office's own wording and are trusted; everything between them was escaped
  -- field by field on the way in.
  if position(v_marker in t.html) > 0 then
    v_top    := left(t.html, position(v_marker in t.html) - 1);
    v_bottom := substr(t.html, position(v_marker in t.html) + length(v_marker));
  else
    v_top := t.html;
    v_bottom := '';
  end if;

  v_allow := coalesce((select array_agg(lower(btrim(x)))
                         from unnest(string_to_array(app.setting('bulletin_allow'), ',')) x
                        where btrim(x) <> ''), '{}'::text[]);

  -- Everybody who takes either channel. app.campaign_recipients already refuses
  -- to return somebody with no address, a suppressed address, or the channel
  -- switched off, and none of those is a thing this function should be deciding
  -- for itself a second time.
  for r in
    select * from app.campaign_recipients('{}'::jsonb)
    union
    select * from app.campaign_recipients('{"channel":"events"}'::jsonb)
  loop
    -- Which halves this member has actually asked for.
    declare
      v_takes_news   boolean;
      v_takes_events boolean;
    begin
      select pr.email_newsletter, pr.email_events
        into v_takes_news, v_takes_events
        from public.member_preferences pr where pr.member_id = r.member_id;

      v_body := '';
      if v_takes_news   and v_n_count > 0 then v_body := v_body || v_news;   end if;
      if v_takes_events and v_e_count > 0 then v_body := v_body || v_events; end if;
      if v_body = '' then continue; end if;

      if v_env <> 'live' and not (r.email = any (v_allow)) then
        v_withheld := v_withheld + 1;
        continue;
      end if;

      select * into rr from app.render_parts(
        t.subject,
        v_top || v_body || v_bottom,
        jsonb_build_object(
          'given_name',      r.given_name,
          'family_name',     r.family_name,
          'headline',        v_headline,
          'unsubscribe_url', app.setting('site_url') || '/preferences?t='
                             || r.unsubscribe_token::text));

      perform app.queue_message('content_digest', rr.subject, rr.html, r.email,
        btrim(r.given_name || ' ' || r.family_name), r.person_id,
        app.setting('bulletin_from'),
        jsonb_build_object('kind', 'content_digest', 'items', v_n_count + v_e_count));

      v_sent := v_sent + 1;
    end;
  end loop;

  -- Marked AFTER the queueing and not before. Marked first, a failure half way
  -- through leaves items recorded as announced that nobody was told about, and
  -- nothing anywhere says so. This whole function is one transaction, so a
  -- failure rolls the marking back with the messages.
  --
  -- And marked even when nobody was written to, because the items are still
  -- announced as far as the office is concerned: holding them back would mean a
  -- week of quiet turning into one enormous digest the day somebody subscribes.
  update public.news_articles      set notified_at = now()
   where status = 'published' and published_at is not null
     and published_at <= now() and notified_at is null;
  update public.events             set notified_at = now()
   where status = 'published' and published_at is not null
     and published_at <= now() and notified_at is null and starts_at >= now();
  update public.guidance_documents set notified_at = now()
   where status = 'published' and published_at is not null
     and published_at <= now() and notified_at is null;
  update public.videos             set notified_at = now()
   where status = 'published' and published_at is not null
     and published_at <= now() and notified_at is null;

  return jsonb_build_object('items', v_n_count + v_e_count,
                            'sent', v_sent, 'withheld', v_withheld,
                            'environment', v_env);
end;
$$;

revoke all on function app.queue_content_digest() from public;
revoke all on function app.queue_content_digest() from anon, authenticated;
grant execute on function app.queue_content_digest() to service_role;

comment on function app.queue_content_digest() is
  'One email a day listing what has become public since the last run, to '
  'whichever of the two channels each member takes. Sends nothing on a day with '
  'nothing to say. Safe to run twice: notified_at is what decides.';


-- A wrapper so a super user can send it by hand from the admin app without
-- holding the service role, and can see what happened.
create or replace function public.run_content_digest()
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not app.is_super_user() then
    raise exception 'Only a super user may send the digest by hand.'
      using errcode = '42501';
  end if;
  return app.queue_content_digest();
end;
$$;

revoke all on function public.run_content_digest() from public;
grant execute on function public.run_content_digest() to authenticated, service_role;


-- =============================================================================
-- THE JOB, WHICH IS NOT IN THIS FILE
-- =============================================================================
-- Half past six in the evening, UTC, so it lands after the working day and
-- before anybody goes home to a phone. It sends nothing on a day with nothing to
-- announce, so scheduling it daily costs nothing on a quiet week.
--
--   select cron.schedule('ami-content-digest', '30 18 * * *', $$
--     select app.queue_content_digest();
--   $$);
--
-- To see what the next one would carry, without sending anything:
--
--   select * from public.admin_digest_pending;
-- =============================================================================
