# 0066: content-media is read by office staff only

Database 54. Site 85 and admin 48 are unchanged. Security check 9.

Found on 22 November 2026 while extending the security check for 0064 and
0065. 0011 let any signed in account read everything in the private
content-media bucket. Since 0065 that bucket holds the guidance documents,
members only ones included, so a lapsed member who can still sign in could
have fetched one straight from storage, going round the Worker's check that
the membership is current.

Nothing on the site reads the bucket. The admin app reads it as staff (media
library previews) and the Worker reads it with the service key. So reading is
now `app.is_staff()`: super user, administrator, editor, membership and
moderator. Uploading and deleting stay editors only.

## Done on staging, 22 November

Run by Claude through the Supabase connection, with Steve's standing
agreement. Test 66's nine checks were run on staging in a transaction that
rolled back (pgTAP is not installed there, so as plain SQL): all nine right.
Nothing was left behind. On the mirror, 1,029 tests pass, in migration order
and in staging order; test 66 fails four checks when the old policy is put
back.

## The way back

```sql
drop policy if exists media_select_staff on storage.objects;
create policy media_select_signed_in on storage.objects
  for select to authenticated using (bucket_id = 'content-media');
```

Do not use it unless the media library previews stop working for staff, and
then only until the cause is found.
