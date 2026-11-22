-- =============================================================================
-- 0037, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- Thirteen photographs became blocks. Each holds one address that the site
-- writes into a CSS url(), so the address is held to a pattern that cannot
-- close that url(): a bundle photograph, /assets/<name>.webp, or a converted
-- upload in public-media ending .webp or .jpg.
--
-- Every fixture value is prefixed.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(16);

select ok(exists(select 1 from pg_constraint
                  where conname = 'page_blocks_photo_address'
                    and conrelid = 'public.page_blocks'::regclass),
          'page_blocks has the photograph address check');

-- Accepted
select lives_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'a_photo', '/assets/photo-team.webp', 'draft') $$,
  'a bundle photograph is accepted');
select lives_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'b_photo', 'pages/2026/about-banner-k3x9qa.webp', 'draft') $$,
  'a converted upload is accepted');
select lives_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'c_photo', 'pages/2026/about-banner-k3x9qa.jpg', 'draft') $$,
  'a JPEG upload, which is what Safari produces, is accepted');

-- Refused, each because the site would write it into url('...')
select throws_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'd_photo', 'x'') ; background:url(''https://evil.example/a.webp', 'draft') $$,
  '23514', null, 'an address with a quote in it is refused');
select throws_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'e_photo', 'https://evil.example/a.webp', 'draft') $$,
  '23514', null, 'an address on another host is refused');
select throws_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'f_photo', '//evil.example/a.webp', 'draft') $$,
  '23514', null, 'another host written to look like a path is refused');
select throws_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'g_photo', '../secret.webp', 'draft') $$,
  '23514', null, 'an address climbing out of the folder is refused');
select throws_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'h_photo', 'pages/2026/a.png', 'draft') $$,
  '23514', null, 'a PNG, which the bucket no longer takes, is refused');
select throws_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'i_photo', '/assets/../_worker.webp', 'draft') $$,
  '23514', null, 'a bundle address with a climb in it is refused');
select throws_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'j_photo', null, 'draft') $$,
  '23514', null, 'a photograph block with no address is refused');
select throws_ok($$ update public.page_blocks set body = 'javascript:alert(1)'
   where page_key = 'zz-test-page' and block_key = 'a_photo' $$,
  '23514', null, 'an update to a bad address is refused as well');

-- A block that is not a photograph is untouched by the rule.
select lives_ok($$ insert into public.page_blocks (page_key, block_key, body, status)
  values ('zz-test-page', 'photo_caption', 'It''s a (lovely) picture', 'draft') $$,
  'a block whose key merely mentions photo is not held to it');

-- The seed, by shape rather than by value.
select is((select count(*)::int from public.page_blocks
            where block_key like '%\_photo' and page_key not like 'zz-%'), 16,
          'sixteen page photographs are seeded (0065 added three banners)');
select is((select count(*)::int from public.page_blocks
            where block_key like '%\_photo' and page_key not like 'zz-%'
              and body !~ '^/assets/[a-z0-9-]+\.webp$'), 0,
          'every seeded photograph starts as one of the bundle''s own');

set local role anon;
select is((select count(*)::int from public.public_page where block_key like '%\_photo'), 16,
          'an anonymous visitor can read all sixteen');
reset role;

-- -----------------------------------------------------------------------------
do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 16. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 16 TESTS PASSED' as result;

rollback;
