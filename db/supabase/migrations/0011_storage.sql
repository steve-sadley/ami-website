-- =============================================================================
-- 0011  Storage
--
-- Storage does not live in the public schema, so the "row level security on
-- every table in public" rule does not reach it. storage.objects needs its own
-- policies, and they are written and tested in the same migration as the buckets.
--
-- Four buckets, all private. Files are delivered through short lived signed URLs
-- from a separate origin, so an uploaded file can never execute in the security
-- context of the site.
-- =============================================================================

insert into storage.buckets (id, name, public) values
  ('member-photos',        'member-photos',        false),
  ('application-documents','application-documents',false),
  ('cpd-evidence',         'cpd-evidence',         false),
  ('content-media',        'content-media',        false)
on conflict (id) do nothing;

-- storage.objects belongs to Supabase, not to us. On a hosted project row level
-- security is already enabled on it and authenticated already holds the grants,
-- and the role running this migration does not own the table, so both statements
-- below fail with "must be owner of table objects". They are needed on a plain
-- Postgres, where the tests run, so each is attempted and its failure ignored.
--
-- Creating POLICIES on storage.objects is a different matter and works on both,
-- which is why the rest of this file is not wrapped.
do $$
begin
  execute 'alter table storage.objects enable row level security';
exception when insufficient_privilege or wrong_object_type then
  raise notice 'storage.objects: row level security already managed by the platform';
end $$;

do $$
begin
  execute 'grant select, insert, update, delete on storage.objects to authenticated';
  execute 'grant select on storage.buckets to authenticated';
exception when insufficient_privilege then
  raise notice 'storage grants already managed by the platform';
end $$;

-- The convention every policy below depends on: the FIRST path segment is the
-- owning member's or person's id. So a photograph lives at
--   member-photos/<person_id>/<generated-name>.jpg
-- and a policy can decide on the path alone without joining anything.

-- -----------------------------------------------------------------------------
-- member-photos
-- -----------------------------------------------------------------------------
create policy photos_select_own on storage.objects
  for select to authenticated
  using (bucket_id = 'member-photos'
         and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy photos_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'member-photos'
              and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy photos_update_own on storage.objects
  for update to authenticated
  using (bucket_id = 'member-photos'
         and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy photos_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'member-photos'
         and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy photos_select_staff on storage.objects
  for select to authenticated
  using (bucket_id = 'member-photos' and (select app.is_staff()));

-- The photograph is the one private file that reaches a public surface, because
-- it is drawn onto the wallet pass and onto the verification page where the
-- member has allowed it. It is NEVER linked directly. The Worker reads it with
-- the service role and embeds it, so the photograph travels inside the card
-- rather than becoming a fetchable address.

-- -----------------------------------------------------------------------------
-- application-documents
-- -----------------------------------------------------------------------------
create policy appdocs_select_own on storage.objects
  for select to authenticated
  using (bucket_id = 'application-documents'
         and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy appdocs_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'application-documents'
              and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy appdocs_select_staff on storage.objects
  for select to authenticated
  using (bucket_id = 'application-documents' and (select app.is_staff()));

-- -----------------------------------------------------------------------------
-- cpd-evidence
-- -----------------------------------------------------------------------------
create policy cpdev_select_own on storage.objects
  for select to authenticated
  using (bucket_id = 'cpd-evidence'
         and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy cpdev_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'cpd-evidence'
              and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy cpdev_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'cpd-evidence'
         and (storage.foldername(name))[1] = (select app.person_id())::text);

create policy cpdev_select_staff on storage.objects
  for select to authenticated
  using (bucket_id = 'cpd-evidence' and (select app.is_staff()));

-- -----------------------------------------------------------------------------
-- content-media
-- -----------------------------------------------------------------------------
create policy media_select_signed_in on storage.objects
  for select to authenticated
  using (bucket_id = 'content-media');

create policy media_write_editor on storage.objects
  for insert to authenticated
  with check (bucket_id = 'content-media' and (select app.is_editor()));

create policy media_delete_editor on storage.objects
  for delete to authenticated
  using (bucket_id = 'content-media' and (select app.is_editor()));

-- anon holds nothing on any bucket. Public content images are served through
-- signed URLs generated by a Worker, not by making a bucket public.
