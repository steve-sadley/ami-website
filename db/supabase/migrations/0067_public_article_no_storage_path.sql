-- =============================================================================
-- 0067: public_article no longer gives out a document's storage address
--
-- Found by security check 9, 22 November 2026. public_article carried
-- storage_path, the guidance document's address in the private content-media
-- bucket, readable by anybody. The bucket is private and the documents shown
-- here are open ones, so nothing could be fetched with it, but where a file
-- lives is the Worker's business, never a visitor's (public_guidance already
-- keeps it back). The article page only used it to decide whether to offer
-- Download, and the download itself goes through /api/guidance/<slug>.
--
-- So storage_path becomes has_document, true or false. Renaming a column in
-- the middle of a view needs a drop and a fresh create, and a drop takes the
-- grants with it, so they are given back below. Nothing else depends on this
-- view.
-- =============================================================================

drop view if exists public.public_article;

create view public.public_article as
  select 'news'::text as kind, n.slug, n.title, n.category, n.summary, n.body,
         n.image_path, n.published_at, false as has_document,
         null::text as vimeo_id, null::timestamptz as starts_at,
         null::timestamptz as ends_at, null::text as location,
         public.fallback_picture(n.slug) as fallback_path
    from public.news_articles n
   where n.status = 'published' and n.published_at <= now()
  union all
  select 'guidance', d.slug, d.title, d.category, d.summary, null,
         d.image_path, d.published_at, (d.storage_path is not null), null, null, null, null,
         public.fallback_picture(d.slug)
    from public.guidance_documents d
   where d.status = 'published' and not d.members_only
  union all
  select 'video', v.slug, v.title, v.category, v.description, null,
         v.image_path, v.published_at, false, v.vimeo_id, null, null, null,
         public.fallback_picture(v.slug)
    from public.videos v
   where v.status = 'published' and not v.members_only
  union all
  select 'event', e.slug, e.title, e.kind, e.description, null,
         e.image_path, e.published_at, false, null, e.starts_at, e.ends_at, e.location,
         public.fallback_picture(e.slug)
    from public.events e
   where e.status = 'published' and not e.members_only;

grant select on public.public_article to anon, authenticated;
