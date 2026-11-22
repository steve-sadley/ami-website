-- =============================================================================
-- The page copy is content, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- 0035 added `items`, seeded 135 blocks off the markup of eleven public pages,
-- and put `items` into public_page. Three of those are the sort of change that
-- goes wrong quietly:
--
--   A seed that is not idempotent gets run twice and overwrites copy somebody
--   has edited, which looks like the admin app losing a save.
--
--   A view replaced to carry a new column can lose its grants, and a view the
--   public cannot read is a site with no words on it.
--
--   FORCE row level security was lifted to let the seed in. If it were left
--   off, any signed in user could write to the table and every policy on it
--   would still read correctly in the migration.
--
-- So the file is mostly about those three, plus the shape of what was seeded,
-- because a seed that inserted 135 empty rows would satisfy a count.
--
-- Same discipline as the other ten. Every fixture value is prefixed.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(30);

-- -----------------------------------------------------------------------------
-- The column, and the rule about what may be in it
-- -----------------------------------------------------------------------------
select has_column('public', 'page_blocks', 'items', 'page_blocks has items');
select col_type_is('public', 'page_blocks', 'items', 'jsonb', 'items is jsonb');
select col_is_null('public', 'page_blocks', 'items', 'items is nullable: a prose block has none');

-- A block is prose or a list and never both. The constraint exists because the
-- alternative is every writer remembering, and the admin app is not the only
-- thing that can write here.
select throws_ok($$
  insert into public.page_blocks (page_key, block_key, body, items, status)
  values ('zz-test-page', 'both', 'some prose', '[{"a":1}]'::jsonb, 'draft')
$$, '23514', null, 'a block carrying prose AND a list is refused');

-- An empty string is not prose. A browser sending a cleared field sends '' at
-- least as often as it sends null, and a list block whose body arrived as ''
-- must still save.
select lives_ok($$
  insert into public.page_blocks (page_key, block_key, body, items, status)
  values ('zz-test-page', 'empty-body-list', '', '[{"a":1}]'::jsonb, 'draft')
$$, 'an empty body beside a list is allowed');

select lives_ok($$
  insert into public.page_blocks (page_key, block_key, body, items, status)
  values ('zz-test-page', 'just-prose', 'some prose', null, 'draft')
$$, 'prose with no list is allowed');

-- -----------------------------------------------------------------------------
-- The public can read the copy, which is the assertion that matters
-- -----------------------------------------------------------------------------
-- The first version of 0035 lifted FORCE row level security to let the seed in
-- and then turned it ON, which it had never been on this database since 0018.
-- Under FORCE, public_page is owned by the role that forcing binds, so it
-- returns nothing to an anonymous visitor: every public page silently falls
-- back to its markup, which looks identical, and nobody finds out until
-- somebody edits a block and the site does not change.
--
-- The first draft of this file asserted the flag was ON and read it as OFF,
-- which looked like the migration forgetting to restore it. It was the
-- opposite. The mirror reads OFF because run_tests.sh runs
-- seeds/optional_starting_lists.sql after the migrations and its last block
-- un-forces every table in public. That seed is optional and staging never
-- runs it, so the suite would have been green while the migration was wrong.
--
-- SO THE FLAG ITSELF IS THE ASSERTION THAT CATCHES THIS, and the anonymous
-- read below is not, which is worth saying plainly rather than letting the file
-- imply otherwise.
--
-- The anonymous read passes here even with forcing ON. A view runs as its
-- owner, the owner in the mirror is owner_test, and run_tests.sh grants
-- owner_test membership of `authenticated` so the suites can switch roles. So
-- under FORCE the published-rows policy applies to it and the view still
-- answers. On Supabase the owner is in no such role, no policy matches it at
-- all, and the view returns nothing.
--
-- That is the mirror being unable to reproduce the failure rather than the
-- failure not existing, and it is the same shape as the pgcrypto schema problem
-- in 0033: the mirror differs from staging in one detail and the difference is
-- invisible until it matters. The anonymous read stays because it is the thing
-- that matters and it is right to assert it; the flag is what bites.
select is(
  (select relrowsecurity from pg_class where oid = 'public.page_blocks'::regclass),
  true, 'row level security is enabled on page_blocks');

select is(
  (select relforcerowsecurity from pg_class where oid = 'public.page_blocks'::regclass),
  false, 'FORCE is OFF, as it has been on every table since 0018');

set local role anon;
select cmp_ok((select count(*) from public.public_page), '>=', 135::bigint,
  'an anonymous visitor can read the page copy');
select is(
  (select body from public.public_page
    where page_key = 'about' and block_key = 'banner_heading'),
  'About the Asbestos Management Institute',
  'and reads the words, not just a row count');
reset role;

-- -----------------------------------------------------------------------------
-- The seed went in, and it went in with words in it
-- -----------------------------------------------------------------------------
select cmp_ok(
  (select count(*) from public.page_blocks where page_key <> 'zz-test-page'),
  '>=', 135::bigint, 'at least 135 blocks were seeded');

select is(
  (select count(distinct page_key) from public.page_blocks
    where page_key not like 'zz-%'),
  16::bigint, 'sixteen pages have blocks (0065 added professional conduct, committees and guidance, 0069 the rules, 0070 resources), and the privacy notice is not one of them');

select is(
  (select count(*) from public.page_blocks where page_key = 'privacy'),
  0::bigint, 'the privacy notice is deliberately NOT in the CMS');

-- A seed of 135 empty rows would satisfy a count, so this asserts there are
-- words in them. Every row must carry prose or a list, never neither.
select is(
  (select count(*) from public.page_blocks
    where page_key not like 'zz-%'
      and coalesce(body, '') = '' and items is null),
  0::bigint, 'no seeded block is empty');

select is(
  (select status::text from public.page_blocks
    where page_key = 'about' and block_key = 'banner_heading'),
  'published', 'the seed is published, because these words are already on the site');

select is(
  (select body from public.page_blocks
    where page_key = 'about' and block_key = 'banner_heading'),
  'About the Asbestos Management Institute',
  'the words came off the page rather than being invented');

-- The two keys that existed before 0035 and had to keep working. They are in
-- the seed so the site goes on rendering them, and a key left out of the
-- generated map is a block that silently stops appearing.
select isnt_empty($$
  select 1 from public.page_blocks where page_key = 'about' and block_key = 'intro'
$$, 'the About intro, a block since August, is still there');

select isnt_empty($$
  select 1 from public.page_blocks where page_key = 'contact' and block_key = 'address'
$$, 'the office address, a block since August, is still there');

-- -----------------------------------------------------------------------------
-- A list block holds a list, and the items have the fields the editor offers
-- -----------------------------------------------------------------------------
select is(
  (select jsonb_typeof(items) from public.page_blocks
    where page_key = 'support' and block_key = 'resources'),
  'array', 'the six support cards are an array');

select is(
  (select jsonb_array_length(items) from public.page_blocks
    where page_key = 'support' and block_key = 'resources'),
  6, 'six of them');

select is(
  (select items -> 0 ->> 'icon' from public.page_blocks
    where page_key = 'support' and block_key = 'resources'),
  'document', 'an icon is a NAME from a set, not markup somebody typed');

select is(
  (select items -> 2 ->> 'href' from public.page_blocks
    where page_key = 'cscs-cards' and block_key = 'cards'),
  'https://www.atac.org.uk/asbestos-testing-consultancy-association-cscs-cards',
  'a card that leaves the site keeps its address, and the site works out the rest');
-- (The Support page's HSE card used to be the example; since 0070 it leads to /resources.)

-- -----------------------------------------------------------------------------
-- The seed is idempotent
-- -----------------------------------------------------------------------------
-- Not "running it twice does not error". Running it twice must not CHANGE
-- anything, because what it would change is somebody's edit.
update public.page_blocks set body = 'EDITED BY THE OFFICE'
  where page_key = 'about' and block_key = 'banner_heading';

insert into public.page_blocks (page_key, block_key, body, items, status, sort_order)
values ('about', 'banner_heading', 'About the Asbestos Management Institute',
        null, 'published', 10)
on conflict (page_key, block_key) do nothing;

select is(
  (select body from public.page_blocks
    where page_key = 'about' and block_key = 'banner_heading'),
  'EDITED BY THE OFFICE',
  're-seeding leaves edited copy alone, which is the whole point of on conflict do nothing');

-- -----------------------------------------------------------------------------
-- public_page
-- -----------------------------------------------------------------------------
select has_column('public', 'public_page', 'items', 'public_page carries items');

-- Appended at the end of the select list on purpose: a create or replace cannot
-- add a column in the middle, and dropping the view would drop these grants.
select table_privs_are('public', 'public_page', 'anon', array['SELECT'],
  'anon may still read public_page after the replace');
select table_privs_are('public', 'public_page', 'authenticated', array['SELECT'],
  'authenticated may still read public_page after the replace');

-- A draft must not reach the public, or draft and publish mean nothing.
insert into public.page_blocks (page_key, block_key, body, status, sort_order)
values ('zz-test-page', 'secret', 'Not ready to be read', 'draft', 1);

select is(
  (select count(*) from public.public_page
    where page_key = 'zz-test-page' and block_key = 'secret'),
  0::bigint, 'a draft block is not in public_page');

-- -----------------------------------------------------------------------------
-- Who may write one
-- -----------------------------------------------------------------------------
-- Editors already hold write on content and a Pages screen is reachable by an
-- editor by design. An ordinary member is not an editor, and the page copy of
-- the whole site is exactly the thing that must not be writable by one.
insert into auth.users (id, email)
values ('aa000000-0000-0000-0000-0000000000c1', 'pam.page@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email)
values ('e1000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-0000000000c1',
        'Pam', 'Page', 'pam.page@test.invalid');

set local role authenticated;
set local request.jwt.claims = '{"sub":"aa000000-0000-0000-0000-0000000000c1","role":"authenticated"}';

select throws_ok($$
  insert into public.page_blocks (page_key, block_key, body, status)
  values ('about', 'zz-member-wrote-this', 'A member wrote this', 'published')
$$, '42501', null, 'an ordinary member cannot write page copy');

-- An UPDATE a policy excludes does NOT raise. The USING clause takes the rows
-- out of the member's view, so the statement matches nothing and succeeds with
-- nothing changed. The first draft of this file expected an exception and was
-- asserting a bug, which is the fourth time in this project a test has been
-- wrong rather than the code. What matters is that the words did not change, so
-- that is what is asserted.
update public.page_blocks set body = 'changed by a member'
  where page_key = 'about' and block_key = 'intro';

reset role;
select isnt(
  (select body from public.page_blocks where page_key = 'about' and block_key = 'intro'),
  'changed by a member',
  'a member updating page copy changes no row, because the policy hides them all');
set local role authenticated;

reset role;

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
    raise exception 'TESTS FAILED: % of 30. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 30 TESTS PASSED' as result;

rollback;
