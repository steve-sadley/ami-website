-- =============================================================================
-- 0023  A picture that will actually display
--
-- 0022 kept content-media private and gave anon a policy allowing it to read
-- anything under public/. That policy is correct and it does not help, because
-- of how Supabase serves files.
--
-- There are two ways to fetch an object. The /object/public/ address is served
-- straight from the edge with no token, and it works ONLY for a bucket whose
-- `public` flag is true. It does not consult row level security at all. The
-- other ways, /object/authenticated/ and a signed link, do consult it but need
-- a token or a round trip to mint the link.
--
-- So a private bucket with a permissive policy is readable by anon in theory and
-- unreachable by an ordinary <img> tag in practice. The admin showed the saved
-- path, because the upload genuinely succeeded, and then failed to draw the
-- preview. The public site would have done the same thing.
--
-- THE FIX IS TO STOP PRETENDING ONE BUCKET CAN BE BOTH.
--
--   public-media    public flag TRUE.  Pictures meant to be seen by anybody.
--                   Editors write, the world reads, no signing, cacheable for a
--                   year at the edge, which is what a photograph on a home page
--                   should be.
--
--   content-media   stays private, exactly as it is. Guidance documents and
--                   anything members only. Every download is a signed link that
--                   expires, so it cannot circulate after a document is
--                   withdrawn.
--
-- The decision an editor makes is now the bucket they upload to, and the admin
-- says which is which on screen. That is easier to hold in your head than a
-- folder convention, and it cannot be got wrong by mistyping a path.
-- =============================================================================

-- Ten megabytes and images only, enforced by storage rather than by the page. A
-- limit written in JavaScript is a limit somebody can turn off; this one is
-- checked before a single byte is stored.
--
-- The size and type columns exist on Supabase and not on the plain Postgres the
-- tests run against, so the full form is attempted and the bare one is the
-- fallback. The bucket and its public flag are what matter and both are set
-- either way.
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('public-media', 'public-media', true, 10485760,
          array['image/jpeg','image/png','image/webp','image/avif','image/svg+xml'])
  on conflict (id) do update
    set public = true,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;
exception when undefined_column then
  insert into storage.buckets (id, name, public)
  values ('public-media', 'public-media', true)
  on conflict (id) do update set public = true;
end $$;

do $$
begin
  execute $p$
    drop policy if exists pubmedia_insert_editor on storage.objects;
    drop policy if exists pubmedia_update_editor on storage.objects;
    drop policy if exists pubmedia_delete_editor on storage.objects;

    create policy pubmedia_insert_editor on storage.objects
      for insert to authenticated
      with check (bucket_id = 'public-media' and (select app.is_editor()));

    create policy pubmedia_update_editor on storage.objects
      for update to authenticated
      using (bucket_id = 'public-media' and (select app.is_editor()))
      with check (bucket_id = 'public-media' and (select app.is_editor()));

    create policy pubmedia_delete_editor on storage.objects
      for delete to authenticated
      using (bucket_id = 'public-media' and (select app.is_editor()))
  $p$;
exception when insufficient_privilege or undefined_table or undefined_function then
  raise notice 'storage policies skipped: not a Supabase storage schema';
end $$;

-- Reading needs no policy. The bucket's public flag is what serves it, and that
-- is the whole point of putting these files here rather than in content-media.

-- The anon read policy from 0022 is now pointless: nothing anonymous needs to
-- reach content-media any more, and a permission nobody uses is a permission
-- nobody reviews. It goes.
do $$
begin
  execute $p$ drop policy if exists media_select_public on storage.objects $p$;
exception when insufficient_privilege or undefined_table or undefined_function then
  raise notice 'nothing to drop';
end $$;

-- -----------------------------------------------------------------------------
-- Anything already uploaded
-- -----------------------------------------------------------------------------
-- Pictures put into content-media/public/ before this migration are still there
-- and still private, so they will not display. There is no way to move an object
-- between buckets in SQL, and there are few enough of them that re-uploading is
-- quicker than anything clever. This clears the paths that point at files the
-- site cannot fetch, so the site falls back to a stock photograph rather than
-- showing a broken frame, and the admin shows the field as empty, which is the
-- truth.
update public.news_articles       set image_path = null where image_path like 'public/%';
update public.guidance_documents  set image_path = null where image_path like 'public/%';
update public.events              set image_path = null where image_path like 'public/%';
update public.videos              set image_path = null where image_path like 'public/%';

comment on column public.news_articles.image_path is
  'Path inside the public-media bucket, for example 2026/agm-2026-a1b2c3.jpg. '
  'Served from the edge with no signing. Anything private belongs in '
  'content-media instead, where every download is a signed link that expires.';
