-- =============================================================================
-- 0067, public_article gives no storage address.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: public_article has no storage_path column; an open guidance
-- document with a file says has_document true, one without says false, news
-- says false; a visitor can still read it; a members only document is still
-- not in it. Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(6);

insert into public.guidance_documents (slug, title, storage_path, members_only, status, published_at) values
  ('test-67-file',    'TEST guide with a file',    'documents/2026/test-67-file.pdf', false, 'published', now() - interval '1 day'),
  ('test-67-nofile',  'TEST guide with no file',   null,                              false, 'published', now() - interval '1 day'),
  ('test-67-members', 'TEST members guide',        'documents/2026/test-67-m.pdf',    true,  'published', now() - interval '1 day');

select ok(not exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = 'public_article' and column_name = 'storage_path'),
          'public_article has no storage_path column');
set local role anon;
select is((select has_document from public.public_article where slug = 'test-67-file'), true,
          'a visitor is told an open guide has a document');
select is((select has_document from public.public_article where slug = 'test-67-nofile'), false,
          'and that one without a file has none');
select is((select count(*)::int from public.public_article where slug = 'test-67-members'), 0,
          'a members only guide is still not in it');
select ok(not exists (select 1 from public.public_article where kind <> 'guidance' and has_document),
          'nothing but guidance claims a document');
select ok((select count(*) from public.public_article) >= 2, 'a visitor can still read the view');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 6. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 6 TESTS PASSED' as result;

rollback;
