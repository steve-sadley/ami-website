-- =============================================================================
-- 0066, the private content-media bucket is read by office staff only.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: a current member, a lapsed member and an account with no
-- role see nothing in content-media, documents or otherwise; an editor and a
-- membership officer see both; nobody signed out sees anything; and the old
-- everybody policy is gone. Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(9);

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- How many of the two test objects the signed in person can see.
-- A role with no grant on storage at all (anon on the mirror) is refused rather
-- than shown nothing; both mean it sees nothing, so a refusal counts as 0.
create or replace function seen() returns int language plpgsql as $$
declare n int;
begin
  select count(*)::int into n from storage.objects
   where bucket_id = 'content-media' and name like 'zz-test-66/%';
  return n;
exception when insufficient_privilege then
  return 0;
end $$;
grant execute on function seen() to authenticated, anon;

-- Person ids and login ids differ on purpose: a person is not a login.
insert into auth.users (id, email) values
  ('66660000-0000-0000-0000-000000000001', 'cm.editor@test.invalid'),
  ('66660000-0000-0000-0000-000000000002', 'cm.member@test.invalid'),
  ('66660000-0000-0000-0000-000000000003', 'cm.lapsed@test.invalid'),
  ('66660000-0000-0000-0000-000000000004', 'cm.office@test.invalid'),
  ('66660000-0000-0000-0000-000000000005', 'cm.nobody@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('66661111-0000-0000-0000-000000000001', '66660000-0000-0000-0000-000000000001', 'Eda', 'Editor', 'cm.editor@test.invalid'),
  ('66661111-0000-0000-0000-000000000002', '66660000-0000-0000-0000-000000000002', 'Mo', 'Member', 'cm.member@test.invalid'),
  ('66661111-0000-0000-0000-000000000003', '66660000-0000-0000-0000-000000000003', 'Lee', 'Lapsed', 'cm.lapsed@test.invalid'),
  ('66661111-0000-0000-0000-000000000004', '66660000-0000-0000-0000-000000000004', 'Olu', 'Office', 'cm.office@test.invalid'),
  ('66661111-0000-0000-0000-000000000005', '66660000-0000-0000-0000-000000000005', 'Nia', 'Nobody', 'cm.nobody@test.invalid');
insert into public.role_grants (person_id, role_code) values
  ('66661111-0000-0000-0000-000000000001', 'editor'),
  ('66661111-0000-0000-0000-000000000004', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select ('66662222-0000-0000-0000-00000000000' || n)::uuid, ('66661111-0000-0000-0000-00000000000' || n)::uuid,
       'TEST-CM-' || n, g.id, date '2020-01-01', n = 2, (case when n = 2 then 'current' else 'lapsed' end)::public.member_status
  from (values (2), (3)) v(n), (select id from public.membership_grades where code = 'member') g;

insert into storage.objects (bucket_id, name) values
  ('content-media', 'zz-test-66/documents/members-guide.pdf'),
  ('content-media', 'zz-test-66/library/picture.webp');

-- 1. the policies themselves
select ok(not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                       and policyname = 'media_select_signed_in'),
          'the old policy letting every signed in account read content-media is gone');
select ok(exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                   and policyname = 'media_select_staff' and qual ilike '%is_staff%'),
          'content-media is read through a staff only policy');

-- 2. who sees what
select sign_in_as('66660000-0000-0000-0000-000000000002');
select is(seen(), 0, 'a current member sees nothing in content-media');
reset role;
select sign_in_as('66660000-0000-0000-0000-000000000003');
select is(seen(), 0, 'a lapsed member sees nothing in content-media, so cannot go round the Worker');
reset role;
select sign_in_as('66660000-0000-0000-0000-000000000005');
select is(seen(), 0, 'an account with no role and no membership sees nothing');
reset role;
select sign_in_as('66660000-0000-0000-0000-000000000001');
select is(seen(), 2, 'an editor sees the documents and the pictures');
reset role;
select sign_in_as('66660000-0000-0000-0000-000000000004');
select is(seen(), 2, 'a membership officer sees them too (the media library previews)');
reset role;
set local role anon;
select is(seen(), 0, 'nobody signed out sees anything');
reset role;

-- 3. writing is unchanged: editors only
select ok(exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                   and policyname = 'media_write_editor' and with_check ilike '%is_editor%'),
          'uploading to content-media is still editors only');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 9. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 9 TESTS PASSED' as result;

rollback;
