-- =============================================================================
-- 0066: the private content-media bucket is read by office staff only
--
-- Found while extending the security check for 0064 and 0065, 22 November 2026.
--
-- 0011 let ANY signed in account read everything in content-media. That was
-- harmless while the bucket held only pictures the office was preparing. Since
-- 0065 it also holds the guidance documents, members only ones included, under
-- documents/. A lapsed member can still sign in, so a lapsed member could have
-- fetched a members only document straight from storage, going round the
-- Worker's check (can_read_member_documents) entirely.
--
-- Nothing on the public site or the members area reads this bucket. The admin
-- app reads it as a member of staff (the media library's previews and upload
-- check), and the Worker reads it with the service key, which needs no policy.
-- So reading becomes staff only: app.is_staff() is super user, administrator,
-- editor, membership and moderator. Writing and deleting stay editors only, as
-- they were.
-- =============================================================================

drop policy if exists media_select_signed_in on storage.objects;
drop policy if exists media_select_staff on storage.objects;

create policy media_select_staff on storage.objects
  for select to authenticated
  using (bucket_id = 'content-media' and (select app.is_staff()));
