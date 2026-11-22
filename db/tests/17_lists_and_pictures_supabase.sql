-- =============================================================================
-- 0036, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- Two backstops. page_blocks.items must be a list of objects, because the site
-- draws a list item by reading fields off an object and silently draws the
-- markup instead when it cannot. And the public-media bucket takes WebP and
-- JPEG only, two megabytes at most, because admin 17 converts every picture to
-- one of those and anything else went round the converter.
--
-- The bucket checks only mean something on Supabase. The mirror's storage
-- tables have no size or type columns, so there the two checks say so and pass,
-- and the count stays the same in both places.
--
-- Every fixture value is prefixed.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(14);

-- -----------------------------------------------------------------------------
-- The shape of a list
-- -----------------------------------------------------------------------------
select ok(exists(select 1 from pg_constraint
                  where conname = 'page_blocks_items_shape'
                    and conrelid = 'public.page_blocks'::regclass),
          'page_blocks has the items shape check');

select lives_ok($$
  insert into public.page_blocks (page_key, block_key, items, status)
  values ('zz-test-page', 'cards', '[{"title":"One"},{"title":"Two"}]'::jsonb, 'draft')
$$, 'a list of objects is accepted');

select throws_ok($$
  insert into public.page_blocks (page_key, block_key, items, status)
  values ('zz-test-page', 'obj', '{"title":"One"}'::jsonb, 'draft')
$$, '23514', null, 'a single object where a list belongs is refused');

select throws_ok($$
  insert into public.page_blocks (page_key, block_key, items, status)
  values ('zz-test-page', 'str', '[{"title":"One"},"two"]'::jsonb, 'draft')
$$, '23514', null, 'a list with a string in it is refused');

select throws_ok($$
  insert into public.page_blocks (page_key, block_key, items, status)
  values ('zz-test-page', 'nested', '[[{"title":"One"}]]'::jsonb, 'draft')
$$, '23514', null, 'a list inside a list is refused');

select throws_ok($$
  insert into public.page_blocks (page_key, block_key, items, status)
  values ('zz-test-page', 'empty', '[]'::jsonb, 'draft')
$$, '23514', null, 'an empty list is refused: no items is null, not []');

select throws_ok($$
  insert into public.page_blocks (page_key, block_key, items, status)
  select 'zz-test-page', 'many', jsonb_agg(jsonb_build_object('title', 't' || n)), 'draft'
    from generate_series(1, 25) n
$$, '23514', null, 'twenty five items is refused');

select lives_ok($$
  insert into public.page_blocks (page_key, block_key, body, items, status)
  values ('zz-test-page', 'prose', 'Some words', null, 'draft')
$$, 'a prose block with no items is untouched by the rule');

-- An UPDATE goes through the same check as an insert. The Pages screen upserts,
-- and an upsert on an existing row is an update.
select throws_ok($$
  update public.page_blocks set items = '["just a string"]'::jsonb
   where page_key = 'zz-test-page' and block_key = 'cards'
$$, '23514', null, 'an update to a bad shape is refused as well');

-- Every block seeded by 0035 already meets it, or the migration would not have
-- applied. Asserted anyway, by shape, so a later seed is held to it too.
select is(
  (select count(*)::int from public.page_blocks
    where items is not null
      and (jsonb_typeof(items) <> 'array'
           or jsonb_path_exists(items, 'strict $[*] ? (@.type() != "object")'))),
  0, 'no stored block holds items of the wrong shape');

-- The ten repeating blocks are seeded as lists and the site can read them.
set local role anon;
select cmp_ok(
  (select count(*)::int from public.public_page
    where block_key in ('quick_cards','glance','purpose_cards','benefits','steps','faq',
                        'counts','how','cards','resources')
      and jsonb_typeof(items) = 'array'),
  '>=', 10, 'an anonymous visitor can read all ten repeating blocks as lists');
reset role;

-- -----------------------------------------------------------------------------
-- The public pictures bucket
-- -----------------------------------------------------------------------------
create or replace function pg_temp.bucket_setting(col text) returns text
language plpgsql as $f$
declare v text;
begin
  execute format('select %I::text from storage.buckets where id = %L', col, 'public-media') into v;
  return v;
exception when undefined_column then
  return 'n/a on the mirror';
end $f$;

select ok(
  pg_temp.bucket_setting('allowed_mime_types') in ('{image/webp,image/jpeg}', 'n/a on the mirror'),
  'public-media takes WebP and JPEG only, got ' || pg_temp.bucket_setting('allowed_mime_types'));

select ok(
  pg_temp.bucket_setting('file_size_limit') in ('2097152', 'n/a on the mirror'),
  'public-media takes two megabytes at most, got ' || pg_temp.bucket_setting('file_size_limit'));

select ok((select public from storage.buckets where id = 'public-media'),
          'and it is still public, or every picture on the site stops loading');

-- -----------------------------------------------------------------------------
-- num_failed(), as in files 01 to 10. Test 11 shipped on 30 October counting
-- rows of finish() that contain "not ok", and finish() never returns one: it
-- returns only the closing summary. So 11 printed ALL 30 TESTS PASSED whatever
-- happened, and run_tests.sh, which reads that line, agreed. Found on
-- 30 October when 17 was written by copying it and then failed to fail with
-- its constraint deliberately dropped.
do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 14. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 14 TESTS PASSED' as result;

rollback;
