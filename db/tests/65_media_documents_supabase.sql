-- =============================================================================
-- 0065, documents in the media library, the guidance page and the new pages.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: a document's address can only be a document's and a
-- picture's only a picture's; a document is never a default picture; the
-- guidance already uploaded is in the library; a document in use cannot be
-- deleted; public_guidance shows published documents, members only ones
-- included but marked, never a draft, never a future one, and never a storage
-- address; guidance_file is the Worker's alone; can_read_member_documents says
-- yes to a current member and to staff, no to a lapsed member; the new pages'
-- words are readable by a visitor; and the Support card points at /guidance.
-- Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(30);

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function state_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
grant execute on function state_of(text) to authenticated, anon, service_role;

-- Person ids and login ids differ on purpose: a person is not a login.
insert into auth.users (id, email) values
  ('65650000-0000-0000-0000-000000000001', 'md.editor@test.invalid'),
  ('65650000-0000-0000-0000-000000000002', 'md.member@test.invalid'),
  ('65650000-0000-0000-0000-000000000003', 'md.lapsed@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('65651111-0000-0000-0000-000000000001', '65650000-0000-0000-0000-000000000001', 'Eda', 'Editor', 'md.editor@test.invalid'),
  ('65651111-0000-0000-0000-000000000002', '65650000-0000-0000-0000-000000000002', 'Mo', 'Member', 'md.member@test.invalid'),
  ('65651111-0000-0000-0000-000000000003', '65650000-0000-0000-0000-000000000003', 'Lee', 'Lapsed', 'md.lapsed@test.invalid');
insert into public.role_grants (person_id, role_code) values
  ('65651111-0000-0000-0000-000000000001', 'editor');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select ('65652222-0000-0000-0000-00000000000' || n)::uuid, ('65651111-0000-0000-0000-00000000000' || n)::uuid,
       'TEST-MD-' || n, g.id, date '2020-01-01', n = 2, (case when n = 2 then 'current' else 'lapsed' end)::public.member_status
  from (values (2), (3)) v(n), (select id from public.membership_grades where code = 'member') g;

insert into public.guidance_documents (slug, title, storage_path, members_only, status, published_at) values
  ('test-md-open',    'TEST open guide',    'documents/2026/test-md-open.pdf',    false, 'published', now() - interval '1 day'),
  ('test-md-members', 'TEST members guide', 'documents/2026/test-md-members.docx', true, 'published', now() - interval '1 day'),
  ('test-md-draft',   'TEST draft guide',   'documents/2026/test-md-draft.pdf',   false, 'draft', null),
  ('test-md-future',  'TEST future guide',  'documents/2026/test-md-future.pdf',  false, 'published', now() + interval '3 days');

-- 1. the library's address rules
select is(state_of($$insert into public.media_library (path, name, kind) values ('documents/2026/test-a.pdf', 'TEST pdf', 'document')$$),
          'ok', 'a PDF goes into the library as a document');
select is(state_of($$insert into public.media_library (path, name, kind) values ('documents/2026/test-b.xlsx', 'TEST sheet', 'document')$$),
          'ok', 'so does a spreadsheet');
select is(state_of($$insert into public.media_library (path, name, kind) values ('documents/2026/test-c.html', 'TEST page', 'document')$$),
          '23514', 'a web page is not a document the library will hold');
select is(state_of($$insert into public.media_library (path, name, kind) values ('documents/2026/test-d.exe', 'TEST program', 'document')$$),
          '23514', 'nor is a program');
select is(state_of($$insert into public.media_library (path, name, kind) values ('library/2026/test-e.webp', 'TEST pic', 'document')$$),
          '23514', 'a picture''s address cannot be filed as a document');
select is(state_of($$insert into public.media_library (path, name, kind) values ('documents/2026/test-f.webp', 'TEST pic', 'image')$$),
          '23514', 'and a picture cannot be put among the documents');
select is(state_of($$insert into public.media_library (path, name, kind, fallback) values ('documents/2026/test-g.pdf', 'TEST pdf', 'document', true)$$),
          '23514', 'a document can never be a default picture');
select is(state_of($$insert into public.media_library (path, name) values ('library/2026/test-h.webp', 'TEST pic')$$),
          'ok', 'a picture with no kind given is a picture, as before 0065');

-- 2. the backfill and the uses (the fixtures above came after the migration,
--    so the backfill is checked against what it would find now)
insert into public.media_library (path, name, kind)
select d.storage_path, d.title, 'document' from public.guidance_documents d
 where d.slug like 'test-md-%' on conflict (path) do nothing;
select ok(not exists (select 1 from public.guidance_documents d
                       where d.storage_path is not null and d.storage_path like 'documents/%'
                         and not exists (select 1 from public.media_library m where m.path = d.storage_path and m.kind = 'document')),
          'every guidance document''s file is in the library as a document');
select ok('Guidance document: TEST open guide' = any (app.media_uses('documents/2026/test-md-open.pdf')),
          'the library says which guidance a document is behind');
select is(state_of($$delete from public.media_library where path = 'documents/2026/test-md-open.pdf'$$),
          '22023', 'so a document in use cannot be deleted from under it');

-- 3. the office's view
select sign_in_as('65650000-0000-0000-0000-000000000001');
select is((select kind from public.admin_media_library where path = 'documents/2026/test-a.pdf'),
          'document', 'staff see the kind on the library screen');
reset role;
select sign_in_as('65650000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.admin_media_library), 0, 'a member sees nothing in the library');
reset role;

-- 4. the guidance page
set local role anon;
select ok(exists (select 1 from public.public_guidance where slug = 'test-md-open' and has_document and file_type = 'pdf'),
          'a visitor sees an open document, with its type');
select ok(exists (select 1 from public.public_guidance where slug = 'test-md-members' and members_only and file_type = 'docx'),
          'and a members only one, marked as such');
select ok(not exists (select 1 from public.public_guidance where slug = 'test-md-draft'), 'but not a draft');
select ok(not exists (select 1 from public.public_guidance where slug = 'test-md-future'), 'nor one dated forward');
reset role;
select is((select count(*)::int from information_schema.columns
            where table_schema = 'public' and table_name = 'public_guidance' and column_name like '%path%' and column_name <> 'image_path' and column_name <> 'fallback_path'),
          0, 'the guidance view carries no storage address');

-- 5. the Worker's question
set local role anon;
select is(state_of($$select public.guidance_file('test-md-open')$$), '42501', 'a visitor cannot ask for a file''s address');
reset role;
select sign_in_as('65650000-0000-0000-0000-000000000002');
select is(state_of($$select public.guidance_file('test-md-open')$$), '42501', 'nor can a member');
reset role;
set local role service_role;
select is(public.guidance_file('test-md-open') ->> 'path', 'documents/2026/test-md-open.pdf', 'the Worker gets the file of a published document');
select is((public.guidance_file('test-md-members') ->> 'members_only')::boolean, true, 'and is told when it needs a member');
select ok(public.guidance_file('test-md-draft') is null and public.guidance_file('test-md-future') is null,
          'and gets nothing for a draft or one dated forward');
reset role;

-- 6. who may have a members only document
select sign_in_as('65650000-0000-0000-0000-000000000002');
select is(public.can_read_member_documents(), true, 'a current member may');
reset role;
select sign_in_as('65650000-0000-0000-0000-000000000003');
select is(public.can_read_member_documents(), false, 'a lapsed member may not');
reset role;
select sign_in_as('65650000-0000-0000-0000-000000000001');
select is(public.can_read_member_documents(), true, 'staff may');
reset role;
set local role anon;
select is(state_of($$select public.can_read_member_documents()$$), '42501', 'a visitor cannot even ask');
reset role;

-- 7. the new pages
set local role anon;
select is((select count(distinct page_key)::int from public.public_page
            where page_key in ('professional-conduct', 'committees', 'guidance')), 3,
          'a visitor can read the words of all three new pages');
select ok(exists (select 1 from public.public_page where page_key = 'committees' and block_key = 'committees'
                   and jsonb_array_length(items) >= 1),
          'the committees are a list the office can add to');
reset role;
select ok(not exists (select 1 from public.page_blocks where page_key = 'support' and block_key = 'resources'
                       and items @> '[{"href": "/news?kind=guidance"}]'),
          'the Support guidance card no longer points at the news list');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 30. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 30 TESTS PASSED' as result;

rollback;
