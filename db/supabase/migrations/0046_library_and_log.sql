-- =============================================================================
-- 0046  The image library, every page photograph editable, and a log of every
--       email the system sends
--
-- Steve, 31 October 2026: "we need an image library rather than putting all
-- photos on the page editor; all photos on the pages need to be able to be
-- edited; and a communication log that records every email sent from the
-- system."
--
-- 1. THE LIBRARY. One place for pictures. Uploaded once, converted once (the
--    admin app's converter: turned upright, scaled, re-encoded, location and
--    camera details stripped), named, given alternative text, and then chosen
--    from anywhere a picture goes: page photographs, the home page headline,
--    news, guidance, events and video. The five photographs the site carries
--    are in it from the start, marked built in. The library says where each
--    picture is used, and refuses to delete one that is.
--
-- 2. THE PHOTOGRAPHS THAT COULD NOT BE CHANGED. Thirteen were made editable at
--    0037. Two sets were left: the four that rotate with the home page
--    headline, and the four used for an article, event or video with no
--    picture of its own. The first become a picture and a label on each
--    headline, so a headline and its photograph can no longer drift apart (the
--    old rule was to keep two counts equal by hand). The second become a
--    choice in the library: any picture marked "use where an item has none".
--
-- 3. THE COMMUNICATION LOG. email_outbox already holds every letter the
--    database queues: decisions, receipts, reminders, bulletins, digests. Four
--    emails never went near it, because the Worker sends them as it handles a
--    form: the applicant's acknowledgement, the office's notice of an
--    application, and the two from the contact form. The Worker now records
--    each of those after sending, as a row already sent (or failed), so the
--    log is the outbox and the outbox is complete.
--
--    THIS CHANGES AN EARLIER DECISION. The contact form wrote nothing to the
--    database on purpose ("an enquiry is a message and the office already has
--    somewhere it keeps messages"). Logging every email means the enquiry and
--    its acknowledgement are now kept. The privacy notice needs a line saying
--    so, and how long they are kept.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The library
-- -----------------------------------------------------------------------------
-- The headline's picture columns first: the library's "where is it used"
-- reads them, so they have to exist before it is written. Section 2a fills them.
alter table public.hero_statements add column if not exists image_path text;
alter table public.hero_statements add column if not exists badge text;

create table if not exists public.media_library (
  id            uuid primary key default gen_random_uuid(),
  path          text not null unique
                check (path ~ '^(/assets/[a-z0-9-]+\.webp|[a-z0-9][a-z0-9/_-]*\.(webp|jpg))$'),
  name          text not null check (length(btrim(name)) between 2 and 120),
  alt_text      text check (alt_text is null or length(alt_text) <= 300),
  width         integer,
  height        integer,
  byte_size     integer,
  builtin       boolean not null default false,
  fallback      boolean not null default false,
  archived      boolean not null default false,
  uploaded_by   uuid references public.people(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.media_library is
  'Every picture the site can show, uploaded once and chosen from anywhere. '
  'The path is the same address a page photograph block holds. builtin rows are '
  'the photographs in the site bundle. fallback marks the pictures used, in '
  'turn, for an item with no picture of its own.';

drop trigger if exists media_library_updated on public.media_library;
create trigger media_library_updated before update on public.media_library
  for each row execute function app.set_updated_at();
drop trigger if exists media_library_audit on public.media_library;
create trigger media_library_audit after insert or update or delete on public.media_library
  for each row execute function app.audit_row();

-- INVOKER on purpose: inside a definer function current_user is the owner,
-- and the question here is who is really asking. Test 34 found it.
create or replace function app.media_library_stamp() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.uploaded_by := app.person_id();
    -- Built in means "in the bundle". Only a migration says that.
    if current_user in ('authenticated', 'anon') then new.builtin := false; end if;
  else
    if new.path is distinct from old.path then
      raise exception 'A picture''s address does not change. Upload a new one instead.' using errcode = '22023';
    end if;
    if new.builtin is distinct from old.builtin and current_user in ('authenticated', 'anon') then
      raise exception 'Whether a picture is built in is not changed here.' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists media_library_stamp on public.media_library;
create trigger media_library_stamp before insert or update on public.media_library
  for each row execute function app.media_library_stamp();

-- Where a picture is used, every place a picture can go.
create or replace function app.media_uses(p_path text) returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(u order by u), '{}') from (
    select 'Page: ' || b.page_key || ', ' || replace(replace(b.block_key, '_photo', ''), '_', ' ')
             || case when b.status = 'draft' then ' (draft)' else '' end as u
      from public.page_blocks b where b.block_key like '%\_photo' and b.body = p_path
    union all select 'Home page headline: ' || h.statement from public.hero_statements h where h.image_path = p_path
    union all select 'News: ' || n.title from public.news_articles n where n.image_path = p_path
    union all select 'Guidance: ' || d.title from public.guidance_documents d where d.image_path = p_path
    union all select 'Event: ' || e.title from public.events e where e.image_path = p_path
    union all select 'Video: ' || v.title from public.videos v where v.image_path = p_path
    union all select 'Used where an item has no picture' from public.media_library m
               where m.path = p_path and m.fallback and not m.archived
  ) x;
$$;
revoke all on function app.media_uses(text) from public;
-- The library view is security invoker, so the staff member reading it calls
-- this. app is not exposed to browsers, and what it returns is titles of
-- published or draft content, which staff can read anyway.
grant execute on function app.media_uses(text) to authenticated;

create or replace function app.media_library_guard_delete() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_uses text[];
begin
  if old.builtin then
    raise exception 'A photograph from the site''s own bundle cannot be deleted. Archive it instead.'
      using errcode = '22023';
  end if;
  v_uses := app.media_uses(old.path);
  if array_length(v_uses, 1) > 0 then
    raise exception 'This picture is in use (%), so it cannot be deleted. Change those first, or archive it.',
      array_to_string(v_uses, '; ') using errcode = '22023';
  end if;
  return old;
end;
$$;
drop trigger if exists media_library_guard_delete on public.media_library;
create trigger media_library_guard_delete before delete on public.media_library
  for each row execute function app.media_library_guard_delete();

alter table public.media_library enable row level security;
revoke all on public.media_library from anon, authenticated;
grant select, insert, update, delete on public.media_library to authenticated;
drop policy if exists media_library_read on public.media_library;
create policy media_library_read on public.media_library
  for select to authenticated using ((select app.is_staff()));
drop policy if exists media_library_write on public.media_library;
create policy media_library_write on public.media_library
  for insert to authenticated with check ((select app.is_editor()));
drop policy if exists media_library_update on public.media_library;
create policy media_library_update on public.media_library
  for update to authenticated using ((select app.is_editor())) with check ((select app.is_editor()));
drop policy if exists media_library_delete on public.media_library;
create policy media_library_delete on public.media_library
  for delete to authenticated using ((select app.is_editor()));

-- The library screen, with where each picture is used.
create or replace view public.admin_media_library
with (security_invoker = true) as
  select m.*, app.media_uses(m.path) as uses
    from public.media_library m;
grant select on public.admin_media_library to authenticated;

-- The bundle's five, and every picture already chosen somewhere, so the
-- library starts complete rather than empty.
insert into public.media_library (path, name, alt_text, builtin, fallback) values
  ('/assets/hero.webp',         'Asbestos removal site, enclosure',  'Asbestos removal work in progress', true, false),
  ('/assets/photo-review.webp', 'Reviewing documents',               'Professionals reviewing documents', true, true),
  ('/assets/photo-site.webp',   'On site',                           'Work on a site',                    true, true),
  ('/assets/photo-survey.webp', 'Survey',                            'A surveyor at work',                true, true),
  ('/assets/photo-team.webp',   'The team',                          'A team of professionals',           true, true)
on conflict (path) do nothing;

insert into public.media_library (path, name)
select distinct p, 'Uploaded ' || to_char(now(), 'DD Mon YYYY') || ': ' || regexp_replace(p, '^.*/', '')
  from (
    select b.body as p from public.page_blocks b where b.block_key like '%\_photo' and b.body not like '/assets/%'
    union select image_path from public.news_articles where image_path is not null
    union select image_path from public.guidance_documents where image_path is not null
    union select image_path from public.events where image_path is not null
    union select image_path from public.videos where image_path is not null
  ) x
 where p ~ '^[a-z0-9][a-z0-9/_-]*\.(webp|jpg)$'
on conflict (path) do nothing;


-- -----------------------------------------------------------------------------
-- 2a. The home page headline carries its own photograph
-- -----------------------------------------------------------------------------
alter table public.hero_statements drop constraint if exists hero_image_address;
alter table public.hero_statements add constraint hero_image_address check (
  image_path is null or image_path ~ '^(/assets/[a-z0-9-]+\.webp|[a-z0-9][a-z0-9/_-]*\.(webp|jpg))$');
alter table public.hero_statements drop constraint if exists hero_badge_length;
alter table public.hero_statements add constraint hero_badge_length check (badge is null or length(badge) <= 60);

comment on column public.hero_statements.image_path is
  'The photograph shown with this headline. Each headline carries its own, so '
  'the two always turn together.';
comment on column public.hero_statements.badge is
  'The short label on the photograph, such as "Assessed on evidence".';

-- What each headline showed until now, in the same order, so nothing changes
-- on the page until somebody chooses otherwise.
with ranked as (
  select id, row_number() over (order by sort_order, id) as n
    from public.hero_statements where image_path is null
)
update public.hero_statements h
   set image_path = (array['/assets/hero.webp', '/assets/photo-review.webp',
                           '/assets/photo-team.webp', '/assets/photo-site.webp'])[((r.n - 1) % 4) + 1],
       badge = coalesce(h.badge, (array['Recognised best practice', 'Assessed on evidence',
                           'A community of professionals', 'Competence, kept current'])[((r.n - 1) % 4) + 1])
  from ranked r where r.id = h.id;

-- A headline added later, by the office or by a starting list loaded after
-- this migration, gets a photograph and label by its position too, so no
-- headline ever turns without a picture. The office changes it from there.
create or replace function app.hero_default_picture() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  n integer;
begin
  if new.image_path is null or new.badge is null then
    select count(*) into n from public.hero_statements;
    new.image_path := coalesce(new.image_path, (array['/assets/hero.webp', '/assets/photo-review.webp',
                        '/assets/photo-team.webp', '/assets/photo-site.webp'])[(n % 4) + 1]);
    new.badge := coalesce(new.badge, (array['Recognised best practice', 'Assessed on evidence',
                        'A community of professionals', 'Competence, kept current'])[(n % 4) + 1]);
  end if;
  return new;
end;
$$;
drop trigger if exists hero_default_picture on public.hero_statements;
create trigger hero_default_picture before insert on public.hero_statements
  for each row execute function app.hero_default_picture();

create or replace view public.public_hero as
  select h.statement, h.sort_order, h.image_path, h.badge
    from public.hero_statements h
   where h.active
   order by h.sort_order;
grant select on public.public_hero to anon, authenticated;


-- -----------------------------------------------------------------------------
-- 2b. The picture for an item with none of its own
-- -----------------------------------------------------------------------------
-- The same item always gets the same picture, chosen by a hash of its slug from
-- the pictures marked fallback. Null when none is marked: the site then uses
-- its own four, as before.
create or replace function public.fallback_picture(p_key text) returns text
language sql stable security definer set search_path = ''
as $$
  with f as (select path, row_number() over (order by created_at, id) - 1 as n,
                    count(*) over () as c
               from public.media_library where fallback and not archived)
  select path from f where n = abs(hashtext(coalesce(p_key, ''))) % c limit 1;
$$;
revoke all on function public.fallback_picture(text) from public;
grant execute on function public.fallback_picture(text) to anon, authenticated;

-- Appended at the end of each view: a create or replace cannot add a column in
-- the middle.
create or replace view public.public_content as
  select 'news'::text as kind, n.slug, n.title, n.summary, n.published_at, n.category,
         n.image_path, null::timestamptz as starts_at, null::text as location,
         public.fallback_picture(n.slug) as fallback_path
    from public.news_articles n
   where n.status = 'published' and n.published_at <= now()
  union all
  select 'event', e.slug, e.title, e.description, e.published_at, e.kind,
         e.image_path, e.starts_at, e.location, public.fallback_picture(e.slug)
    from public.events e
   where e.status = 'published' and not e.members_only
  union all
  select 'guidance', d.slug, d.title, d.summary, d.published_at, d.category,
         d.image_path, null, null, public.fallback_picture(d.slug)
    from public.guidance_documents d
   where d.status = 'published' and not d.members_only
  union all
  select 'video', v.slug, v.title, v.description, v.published_at, v.category,
         v.image_path, null, null, public.fallback_picture(v.slug)
    from public.videos v
   where v.status = 'published' and not v.members_only;

create or replace view public.public_article as
  select 'news'::text as kind, n.slug, n.title, n.category, n.summary, n.body,
         n.image_path, n.published_at, null::text as storage_path,
         null::text as vimeo_id, null::timestamptz as starts_at,
         null::timestamptz as ends_at, null::text as location,
         public.fallback_picture(n.slug) as fallback_path
    from public.news_articles n
   where n.status = 'published' and n.published_at <= now()
  union all
  select 'guidance', d.slug, d.title, d.category, d.summary, null,
         d.image_path, d.published_at, d.storage_path, null, null, null, null,
         public.fallback_picture(d.slug)
    from public.guidance_documents d
   where d.status = 'published' and not d.members_only
  union all
  select 'video', v.slug, v.title, v.category, v.description, null,
         v.image_path, v.published_at, null, v.vimeo_id, null, null, null,
         public.fallback_picture(v.slug)
    from public.videos v
   where v.status = 'published' and not v.members_only
  union all
  select 'event', e.slug, e.title, e.kind, e.description, null,
         e.image_path, e.published_at, null, null, e.starts_at, e.ends_at, e.location,
         public.fallback_picture(e.slug)
    from public.events e
   where e.status = 'published' and not e.members_only;

grant select on public.public_content, public.public_article to anon, authenticated;


-- The daily digest (0031) built every picture address from the media bucket.
-- A news item can now carry one of the site's own photographs, /assets/...,
-- which lives on the site, not in the bucket. Restated whole, one line changed.
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
                 || '<img src="' || app.html_escape(case when p_image like '/assets/%'
                                                    then rtrim(app.setting('site_url'), '/') || p_image
                                                    else app.setting('media_url') || p_image end) || '" '
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


-- -----------------------------------------------------------------------------
-- 3. The communication log
-- -----------------------------------------------------------------------------
-- An email the Worker sent itself, recorded after the fact. The service role
-- only: a browser must not be able to write "we told them" into the log.
create or replace function public.log_direct_email(
  p_kind text, p_to_email text, p_to_name text, p_subject text, p_html text,
  p_reply_to text, p_ok boolean, p_error text default null, p_context jsonb default '{}'::jsonb)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_id     uuid;
  v_person uuid;
begin
  if p_kind not in ('application_received', 'application_office', 'contact_office', 'contact_ack') then
    raise exception 'Not an email the site sends directly.' using errcode = '22023';
  end if;
  select id into v_person from public.people where lower(btrim(email)) = lower(btrim(p_to_email)) limit 1;
  insert into public.email_outbox
    (template_code, to_email, to_name, subject, html, reply_to, person_id, context,
     status, attempts, last_error, queued_at, sent_at)
  values
    ('direct:' || p_kind, lower(btrim(p_to_email)), nullif(btrim(coalesce(p_to_name, '')), ''),
     left(coalesce(p_subject, ''), 300), coalesce(p_html, ''), p_reply_to, v_person,
     coalesce(p_context, '{}'::jsonb) || jsonb_build_object('direct', true),
     case when p_ok then 'sent' else 'failed' end, 1,
     case when p_ok then null else left(coalesce(p_error, 'not sent'), 500) end,
     now(), case when p_ok then now() end)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.log_direct_email(text, text, text, text, text, text, boolean, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.log_direct_email(text, text, text, text, text, text, boolean, text, jsonb)
  to service_role;

-- What the log screen lists. The body is left out of the list and fetched when
-- somebody opens one: a year of bulletins is a lot of HTML to load to search.
create or replace view public.admin_communication_log
with (security_invoker = true) as
  select o.id, o.template_code,
         case when o.template_code like 'direct:%' then 'Sent by the site as a form was handled'
              when o.context ? 'campaign_id' then 'Bulletin'
              else 'Queued by the database' end as route,
         o.to_email, o.to_name, o.subject, o.status, o.attempts, o.last_error,
         o.queued_at, o.sent_at, coalesce(o.sent_at, o.queued_at) as at,
         o.person_id, p.given_name, p.family_name, m.membership_number
    from public.email_outbox o
    left join public.people p on p.id = o.person_id
    left join public.members m on m.person_id = o.person_id;
grant select on public.admin_communication_log to authenticated;
