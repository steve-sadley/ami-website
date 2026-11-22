-- =============================================================================
-- 0065  A media library for documents, the guidance page, and three new pages
--
-- Steve, 22 November 2026:
--   1. A media library is needed to house documents, images and other files.
--   2. The Guidance section needs a dedicated page to host and manage guidance
--      documents.
--   3. Two more pages: Professional conduct and Committees, moved across from
--      the old site's /membership/professional-conduct/ and
--      /membership/committees/.
--
-- THE LIBRARY HOLDS DOCUMENTS NOW. media_library (0046) was pictures only. A
-- row now has a kind: 'image' as before, in the public-media bucket, or
-- 'document', in the private content-media bucket under documents/. The path
-- rule is stated per kind, so a picture's address can still only ever be a
-- picture's address, which matters because a picture's address goes into a
-- CSS url() on the public site. A document is never a default picture.
--
-- Documents already uploaded for guidance are entered into the library, so it
-- starts complete rather than empty, the same way 0046 started the pictures.
--
-- THE GUIDANCE PAGE READS public_guidance. It carries what a reader needs to
-- choose a document, its type and size included, and never the storage
-- address. Members only documents are LISTED, marked as such, because a
-- member looking for one needs to know it exists; the file itself is only
-- ever handed over by the Worker, after asking can_read_member_documents() as
-- that person.
--
-- WHY THE WORKER SERVES THE FILES. Until now the article page signed a link
-- with the browser's database client, and signing needs a session. A visitor
-- who was not signed in pressed Download and was told it was not available.
-- That is the trap written down after the photograph: anything that works
-- signed in and fails signed out is a signing problem. guidance_file() is
-- the Worker's question, granted to the service role only.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The library takes documents
-- -----------------------------------------------------------------------------
alter table public.media_library add column if not exists kind text not null default 'image';
alter table public.media_library add column if not exists mime_type text;
alter table public.media_library add column if not exists original_name text;

alter table public.media_library drop constraint if exists media_library_path_check;
alter table public.media_library drop constraint if exists media_library_kind_path;
alter table public.media_library add constraint media_library_kind_path check (
  (kind = 'image'
     and path ~ '^(/assets/[a-z0-9-]+\.webp|[a-z0-9][a-z0-9/_-]*\.(webp|jpg))$'
     and path !~ '^documents/')
  or
  (kind = 'document'
     and path ~ '^documents/[a-z0-9][a-z0-9/_-]*\.(pdf|doc|docx|xls|xlsx|ppt|pptx|csv|txt|odt|ods|odp)$'
     and not fallback and not builtin)
);
alter table public.media_library drop constraint if exists media_library_original_name_len;
alter table public.media_library add constraint media_library_original_name_len
  check (original_name is null or length(original_name) <= 200);

comment on column public.media_library.kind is
  'image: a picture in the public-media bucket, chosen for pages, news and the rest. '
  'document: a file in the private content-media bucket under documents/, chosen for '
  'guidance and served by the Worker (0065).';

-- Every document already uploaded for guidance.
insert into public.media_library (path, name, kind, mime_type)
select distinct on (d.storage_path) d.storage_path,
       left(d.title, 120),
       'document',
       case lower(substring(d.storage_path from '\.([a-z0-9]+)$'))
         when 'pdf'  then 'application/pdf'
         when 'docx' then 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
         when 'doc'  then 'application/msword'
         else null end
  from public.guidance_documents d
 where d.storage_path ~ '^documents/[a-z0-9][a-z0-9/_-]*\.(pdf|doc|docx|xls|xlsx|ppt|pptx|csv|txt|odt|ods|odp)$'
   and length(btrim(d.title)) >= 2
 order by d.storage_path, d.created_at
on conflict (path) do nothing;

-- Their sizes, from storage, where storage is there to ask (not on the mirror).
do $$
begin
  update public.media_library m
     set byte_size = (o.metadata ->> 'size')::integer
    from storage.objects o
   where m.kind = 'document' and m.byte_size is null
     and o.bucket_id = 'content-media' and o.name = m.path
     and (o.metadata ->> 'size') ~ '^[0-9]+$';
exception when undefined_table or undefined_column or insufficient_privilege then null;
end $$;

-- Where a file is used now covers guidance documents as well as pictures, so
-- a document behind a published guidance note cannot be deleted from under it.
create or replace function app.media_uses(p_path text)
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(u order by u), '{}') from (
    select 'Page: ' || b.page_key || ', ' || replace(replace(b.block_key, '_photo', ''), '_', ' ')
             || case when b.status = 'draft' then ' (draft)' else '' end as u
      from public.page_blocks b where b.block_key like '%\_photo' and b.body = p_path
    union all select 'Home page headline: ' || h.statement from public.hero_statements h where h.image_path = p_path
    union all select 'News: ' || n.title from public.news_articles n where n.image_path = p_path
    union all select 'Guidance: ' || d.title from public.guidance_documents d where d.image_path = p_path
    union all select 'Guidance document: ' || d.title from public.guidance_documents d where d.storage_path = p_path
    union all select 'Event: ' || e.title from public.events e where e.image_path = p_path
    union all select 'Video: ' || v.title from public.videos v where v.image_path = p_path
    union all select 'Used where an item has no picture' from public.media_library m
               where m.path = p_path and m.fallback and not m.archived
  ) x;
$$;
grant execute on function app.media_uses(text) to authenticated;

-- The library screen. Same staff gate as 0057, new columns at the end.
create or replace view public.admin_media_library
with (security_invoker = true) as
  select q.id, q.path, q.name, q.alt_text, q.width, q.height, q.byte_size, q.builtin,
         q.fallback, q.archived, q.uploaded_by, q.created_at, q.updated_at, q.uses,
         q.kind, q.mime_type, q.original_name
    from (select m.*, app.media_uses(m.path) as uses from public.media_library m) q,
         lateral (select app.is_staff() as staff_gate) g
   where g.staff_gate;
grant select on public.admin_media_library to authenticated;


-- -----------------------------------------------------------------------------
-- 2. The guidance page
-- -----------------------------------------------------------------------------
-- What a visitor sees about each published document. Owner rights, like every
-- public_ view, because a visitor can read no table. No storage address.
create or replace view public.public_guidance as
  select d.slug, d.title, d.category, d.summary, d.image_path,
         public.fallback_picture(d.slug) as fallback_path,
         d.published_at, d.members_only,
         (d.storage_path is not null) as has_document,
         lower(substring(d.storage_path from '\.([a-z0-9]+)$')) as file_type,
         m.byte_size as file_size
    from public.guidance_documents d
    left join public.media_library m on m.path = d.storage_path and m.kind = 'document'
   where d.status = 'published'
     and (d.published_at is null or d.published_at <= now());
grant select on public.public_guidance to anon, authenticated;

-- The Worker's question: the file behind a published guidance document, and
-- whether it needs a member. Service role only; nothing a browser can call.
create or replace function public.guidance_file(p_slug text) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('path', d.storage_path, 'members_only', d.members_only,
                            'title', d.title, 'slug', d.slug)
    from public.guidance_documents d
   where d.slug = p_slug
     and d.status = 'published'
     and (d.published_at is null or d.published_at <= now())
     and d.storage_path ~ '^documents/[a-z0-9][a-z0-9/_-]*\.(pdf|doc|docx|xls|xlsx|ppt|pptx|csv|txt|odt|ods|odp)$';
$$;
revoke all on function public.guidance_file(text) from public;
grant execute on function public.guidance_file(text) to service_role;

-- Asked AS the person, with their own token: a current member, or staff.
create or replace function public.can_read_member_documents() returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.is_staff()
      or exists (select 1 from public.members m where m.id = app.member_id() and m.is_active);
$$;
revoke all on function public.can_read_member_documents() from public;
grant execute on function public.can_read_member_documents() to authenticated;


-- -----------------------------------------------------------------------------
-- 3. The words on the new pages, and the new section on Membership
-- -----------------------------------------------------------------------------
-- Generated by tools/extract-page-copy.py from site 83, the new rows only.
-- on conflict do nothing: a second run never overwrites edited words.
insert into public.page_blocks (page_key, block_key, body, items, status, sort_order)
values
  ('membership', 'standards_eyebrow', 'Standards and governance', null, 'published', 560),
  ('membership', 'standards_heading', 'What members sign up to', null, 'published', 570),
  ('membership', 'standards_cards', null, '[{"icon": "shield", "title": "Professional conduct", "body": "The obligations every member accepts: integrity, competence, fairness and telling the institute when something it needs to know about happens.", "href": "/professional-conduct"}, {"icon": "people", "title": "Committees", "body": "The members who decide applications and grades, and who take members'' technical questions to the source.", "href": "/committees"}]'::jsonb, 'published', 580),
  ('professional-conduct', 'banner_photo', '/assets/photo-team.webp', null, 'published', 1480),
  ('professional-conduct', 'banner_heading', 'Professional conduct', null, 'published', 1490),
  ('professional-conduct', 'banner_lede', 'The standards every AMI member signs up to, and what the institute expects of them in their work.', null, 'published', 1500),
  ('professional-conduct', 'intro_heading', 'Professional conduct of AMI members', null, 'published', 1510),
  ('professional-conduct', 'intro', '<p>The Asbestos Management Institute places a personal obligation on its members to act with integrity, in the public interest and to exercise all reasonable professional skill and care to:</p> <ul> <li>Prevent avoidable risks to health or safety</li> <li>Prevent avoidable adverse impact on the environment</li> <li>Maintain their competence <ul> <li>Undertake only professional tasks for which they are competent</li> <li>Disclose relevant limitations of competence</li> </ul></li> <li>Accept appropriate responsibility for work carried out under their supervision <ul> <li>Treat all persons fairly, without bias, and with respect</li> <li>Encourage others to advance their learning and competence</li> </ul></li> <li>Avoid where possible real or perceived conflict of interest <ul> <li>Advise affected parties when such conflicts arise</li> </ul></li> <li>Observe the proper duties of confidentiality owed to appropriate parties</li> <li>Reject bribery</li> <li>Assess relevant risks and liability, and if appropriate hold professional indemnity insurance</li> <li>Notify the institution if convicted of a criminal offence or upon becoming bankrupt or disqualified as a Company Director</li> <li>Notify the institution of any significant violation of the AMI Code of Conduct by another member</li> </ul>', null, 'published', 1520),
  ('professional-conduct', 'notify_heading', 'Telling AMI', null, 'published', 1530),
  ('professional-conduct', 'notify', null, '[{"text": "A criminal conviction"}, {"text": "Becoming bankrupt"}, {"text": "Disqualification as a company director"}, {"text": "A significant breach of the code by another member"}]'::jsonb, 'published', 1540),
  ('professional-conduct', 'cta_heading', 'Need to raise a concern?', null, 'published', 1550),
  ('professional-conduct', 'cta_body', '<p>If you have a question about the code, or need to tell the institute about something it covers, contact the office in confidence.</p>', null, 'published', 1560),
  ('professional-conduct', 'cta_link', null, '[{"label": "Contact the office", "href": "/contact"}]'::jsonb, 'published', 1570),
  ('committees', 'banner_photo', '/assets/photo-review.webp', null, 'published', 1580),
  ('committees', 'banner_heading', 'Committees', null, 'published', 1590),
  ('committees', 'banner_lede', 'The members who give their time to run the institute''s membership and technical work.', null, 'published', 1600),
  ('committees', 'intro_eyebrow', 'How AMI is run', null, 'published', 1610),
  ('committees', 'intro_heading', 'Sub-committees', null, 'published', 1620),
  ('committees', 'intro_lede', '<p>The Asbestos Management Institute formed a Membership Sub-Committee and a Technical Sub-Committee following initial meetings in September 2022.</p>', null, 'published', 1630),
  ('committees', 'committees', null, '[{"icon": "people", "title": "Membership Sub-Committee", "body": "The final stage of a membership application, including clarifying the appropriate membership grade.", "bullets": ["Christian Jones, Chair", "Robert Burley", "Tony Church", "Luke Gumbley"]}, {"icon": "people", "title": "Technical Sub-Committee", "body": "Reviews questions and issues raised by members and seeks clarity on them from the relevant source.", "bullets": ["Robert Burley, Chair", "Robert Carney", "Tony Church", "Chris Dobson"]}]'::jsonb, 'published', 1640),
  ('committees', 'cta_heading', 'A question for a committee?', null, 'published', 1650),
  ('committees', 'cta_body', '<p>Members can raise a technical question or an issue needing clarification through the office, and it will be passed to the right committee.</p>', null, 'published', 1660),
  ('committees', 'cta_link', null, '[{"label": "Contact the office", "href": "/contact"}]'::jsonb, 'published', 1670),
  ('guidance', 'banner_photo', '/assets/photo-survey.webp', null, 'published', 1680),
  ('guidance', 'banner_heading', 'Guidance documents', null, 'published', 1690),
  ('guidance', 'banner_lede', 'AMI''s own guidance for asbestos professionals and duty holders, to read online or download.', null, 'published', 1700)
on conflict (page_key, block_key) do nothing;

-- The guidance card on Support pointed at the news list filtered to guidance.
-- It now goes to the guidance page. Only that one address, and only where it is
-- still the old one, so a card the office has changed is left alone.
update public.page_blocks
   set items = (select jsonb_agg(case when e ->> 'href' = '/news?kind=guidance'
                                      then jsonb_set(e, '{href}', '"/guidance"') else e end
                                 order by n)
                  from jsonb_array_elements(items) with ordinality as t(e, n))
 where page_key = 'support' and block_key = 'resources'
   and items @> '[{"href": "/news?kind=guidance"}]';
