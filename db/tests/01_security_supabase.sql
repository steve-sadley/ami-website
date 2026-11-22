-- =============================================================================
-- The access rules, proved rather than asserted.
--
--   Supabase SQL editor: paste the whole file and run it
--
-- These are the point of phase 1. The schema is not finished when the tables
-- exist, it is finished when these pass.
-- =============================================================================
-- Supabase keeps extensions in their own schema by convention.
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(75);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
-- Reference data is no longer seeded by a migration: grades, activity types,
-- forum categories, fees and the banned word list are all set from the backend.
-- The tests therefore create the little they need.
-- Every one of these is written so the file runs on an EMPTY database and on a
-- populated one. The reference data may already be there, because a real project
-- has the starting lists loaded, and a test that only works on a fresh database is
-- a test nobody runs where it matters.
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;

insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select 2026, id, 5, 5 from public.membership_grades where code = 'member'
on conflict (year, grade_id) do nothing;

-- Test types of their own, with a value, since 0038 switched the August types
-- off and a member cannot log a switched off type.
insert into public.cpd_activity_types (code, name, is_core, sort_order, points, member_can_log) values
  ('test_course',  'TEST assessed training course', true, 1, 3, true),
  ('test_logged',  'TEST loggable activity',        true, 4, 2, true)
on conflict (code) do nothing;

insert into public.forum_categories (slug, name, sort_order) values
  ('analysis', 'Analysis and air monitoring', 2)
on conflict (slug) do nothing;

-- A year far enough out that no real fee will ever collide with it.
insert into public.grade_fees (grade_id, year, fee_pence)
select id, 2099, 12000 from public.membership_grades where code = 'member'
on conflict (grade_id, year) do nothing;

-- Every value in these fixtures is prefixed or uses a .invalid address, so none
-- of them can collide with anything a real project holds. A test that only runs
-- on an empty database is a test nobody runs where it matters.
--
-- The bootstrap test used to borrow the real address seeded by 0013. On a live
-- project that person already has an account and a people row, and both are
-- unique, so the fixture collided with them. It brings its own address instead.
insert into public.bootstrap_super_users (email)
values ('bootstrap-fixture@test.invalid')
on conflict (email) do nothing;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.invalid'),
  ('33333333-3333-3333-3333-333333333333', 'office@test.invalid'),
  ('44444444-4444-4444-4444-444444444444', 'root@test.invalid'),
  ('55555555-5555-5555-5555-555555555555', 'lapsed@test.invalid'),
  ('66666666-6666-6666-6666-666666666666', 'bootstrap-fixture@test.invalid');

-- id and auth_user_id are the same value here only because it keeps the fixtures
-- readable. In real life they are unrelated, and most people have no account at all.
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('11111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','Alice','Adeyemi','alice@test.invalid'),
  ('22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','Bob','Brennan','bob@test.invalid'),
  ('33333333-3333-3333-3333-333333333333','33333333-3333-3333-3333-333333333333','Olive','Office','office@test.invalid'),
  ('44444444-4444-4444-4444-444444444444','44444444-4444-4444-4444-444444444444','Root','User','root@test.invalid'),
  ('55555555-5555-5555-5555-555555555555','55555555-5555-5555-5555-555555555555','Liam','Lapsed','lapsed@test.invalid'),
  -- listed in bootstrap_super_users by the fixture above, so this insert should
  -- grant the role
  ('66666666-6666-6666-6666-666666666666','66666666-6666-6666-6666-666666666666','Ada','Bootstrap','bootstrap-fixture@test.invalid');

-- a member who has never signed in, which is the normal case
insert into public.people (id, given_name, family_name, email) values
  ('77777777-7777-7777-7777-777777777777', 'Nina', 'Nolan', 'nina@test.invalid');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'dddddddd-0000-0000-0000-000000000007', '77777777-7777-7777-7777-777777777777',
       'TEST-M-0007', g.id, date '2021-04-01', true, 'current'
  from public.membership_grades g where g.code = 'member';
insert into public.member_preferences (member_id) values ('dddddddd-0000-0000-0000-000000000007');
insert into public.register_slugs (slug, member_id) values ('test-nina-nolan','dddddddd-0000-0000-0000-000000000007');

insert into public.role_grants (person_id, role_code) values
  ('33333333-3333-3333-3333-333333333333', 'membership'),
  ('33333333-3333-3333-3333-333333333333', 'moderator'),
  ('44444444-4444-4444-4444-444444444444', 'super_user');

insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
       'TEST-M-0001', g.id, date '2019-03-01', true, 'current'
  from public.membership_grades g where g.code = 'member';
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
       'TEST-M-0002', g.id, date '2020-06-01', true, 'current'
  from public.membership_grades g where g.code = 'member';
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'cccccccc-0000-0000-0000-000000000003', '55555555-5555-5555-5555-555555555555',
       'TEST-M-0003', g.id, date '2018-01-01', true, 'current'
  from public.membership_grades g where g.code = 'member';

insert into public.member_preferences (member_id) values
  ('aaaaaaaa-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000002'),
  ('cccccccc-0000-0000-0000-000000000003');

insert into public.register_slugs (slug, member_id) values
  ('test-alice-adeyemi', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('test-liam-lapsed',   'cccccccc-0000-0000-0000-000000000003');

insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points, is_core,
                                how_recorded, status, reviewed_by, reviewed_at)
select 'aaaaaaaa-0000-0000-0000-000000000001', 2026, date '2026-02-01', t.id,
       'Four stage clearance refresher', 3, true, 'self_declared', 'accepted',
       '33333333-3333-3333-3333-333333333333', now()
  from public.cpd_activity_types t where t.code = 'test_course' limit 1;

insert into public.banned_words (word, match_type) values ('badger', 'whole_word');

insert into public.forum_threads (id, category_id, author_id, title, slug)
select 'dddddddd-0000-0000-0000-000000000001', c.id, 'aaaaaaaa-0000-0000-0000-000000000001',
       'A question about clearance', 'a-question-about-clearance'
  from public.forum_categories c where c.slug = 'analysis' limit 1;

insert into public.forum_posts (id, thread_id, author_id, body) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'The opening post.');

insert into public.membership_applications (id, reference, given_name, family_name, email, status)
values ('ffffffff-0000-0000-0000-000000000001', 'TEST-APP-0001', 'Nadia', 'Nash', 'nadia@test.invalid', 'submitted');
insert into public.application_tokens (application_id, token_hash, expires_at)
values ('ffffffff-0000-0000-0000-000000000001', 'notarealhash', now() + interval '7 days');

insert into storage.objects (bucket_id, name) values
  ('member-photos', '11111111-1111-1111-1111-111111111111/face.jpg'),
  ('member-photos', '22222222-2222-2222-2222-222222222222/face.jpg');

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- Runs a statement as the CURRENT role and returns how many rows it touched.
-- Security invoker, so row level security applies exactly as it would to the
-- application. Zero rows means a policy refused it silently, which is what an
-- update or delete does when no policy allows the row.
create or replace function try_dml(p_sql text) returns int language plpgsql as $$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- =============================================================================
-- 1. Row level security is enabled AND forced on every table in public
-- =============================================================================
-- This runs over the catalogue, so a table added later without policies fails
-- the build rather than sitting there quietly readable.
select is(
  (select count(*)::int from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and not c.relrowsecurity),
  0,
  'Every table in public has row level security enabled');

-- Nothing is forced, deliberately. See migration 0018 for the four separate
-- failures that setting caused, the last of which was a blank public register.
-- FORCE only ever bound the table owner, and no browser is the owner.
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public','restricted') and c.relkind = 'r'
      and c.relforcerowsecurity),
  0,
  'No table is forced, because forcing only ever bound the owner and broke this schema four times');

select is(
  (select count(*)::int from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'restricted' and c.relkind = 'r'
     and not c.relrowsecurity),
  0,
  'Every table in restricted has row level security enabled');

-- The real protection on that schema is not a policy at all: the browser roles
-- hold no privileges on it, not even usage, so nothing they send can name it.
select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'restricted' and grantee in ('anon','authenticated')),
  0,
  'and anon and authenticated hold no grant on anything in it');

-- =============================================================================
-- 2. anon reads and writes nothing, and cannot see the restricted schema
-- =============================================================================
set local role anon;
select throws_ok('select * from public.people',         '42501', null, 'anon cannot read people');
select throws_ok('select * from public.members',        '42501', null, 'anon cannot read members');
select throws_ok('select * from public.cpd_entries',    '42501', null, 'anon cannot read CPD entries');
select throws_ok('select * from public.forum_posts',    '42501', null, 'anon cannot read forum posts');
select throws_ok('select * from public.audit_log',      '42501', null, 'anon cannot read the audit log');
select throws_ok('select * from restricted.staff_notes','42501', null, 'anon cannot see the restricted schema');
select throws_ok($$insert into public.people (id, given_name, family_name, email)
                   values (gen_random_uuid(), 'X', 'Y', 'x@y.z')$$,
                 '42501', null, 'anon cannot write to people');
select lives_ok('select * from public.public_register', 'anon CAN read the public register view');
select lives_ok('select * from public.public_profile',  'anon CAN read the public profile view');

-- THE TEST WHOSE ABSENCE LET A BLANK REGISTER THROUGH. Checking that a query does
-- not error says nothing about whether it returns anything. Under FORCE these
-- views ran as their owner, were refused by the policies underneath, and returned
-- nothing at all to the public while raising no error whatsoever.
select cmp_ok((select count(*) from public.public_register), '>', 0::bigint,
              'anon actually SEES members on the register, not an empty list');
select is((select count(*)::int from public.public_register
            where membership_number = 'TEST-M-0007'), 1,
          'including a member who has never signed in');
select is((select count(*)::int from public.public_profile where slug = 'test-nina-nolan'), 1,
          'and anon can read that member''s profile page');
select is((select given_name from public.public_profile where slug = 'test-nina-nolan'), 'Nina',
          'and the row carries real data rather than nulls');
reset role;

-- =============================================================================
-- 3. Member A cannot reach member B
-- =============================================================================
select sign_in_as('11111111-1111-1111-1111-111111111111');
select is((select count(*)::int from public.people),  1, 'A member sees exactly one person row, their own');
select is((select count(*)::int from public.members), 1, 'A member sees exactly one membership row, their own');
select is((select count(*)::int from public.cpd_entries), 1, 'A member sees only their own CPD entries');
reset role;

select sign_in_as('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.cpd_entries), 0,
          'Member B sees none of member A''s CPD entries');
select is((select count(*)::int from public.membership_years), 0,
          'Member B sees none of member A''s membership years');
reset role;

-- =============================================================================
-- 4. The active switch is membership staff only
-- =============================================================================
select sign_in_as('11111111-1111-1111-1111-111111111111');
select is(
  try_dml($sql$update public.members set is_active = false where id = 'aaaaaaaa-0000-0000-0000-000000000001'$sql$),
  0, 'A member cannot switch their own membership active or inactive');
reset role;

select sign_in_as('33333333-3333-3333-3333-333333333333');
select is(
  try_dml($sql$update public.members set is_active = false where id = 'cccccccc-0000-0000-0000-000000000003'$sql$),
  1, 'Membership staff CAN switch a membership inactive');
reset role;

-- =============================================================================
-- 5. A member cannot write an accepted or an awarded CPD entry
-- =============================================================================
select sign_in_as('11111111-1111-1111-1111-111111111111');
select throws_ok($$
  insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points,
                                  is_core, how_recorded, status)
  select 'aaaaaaaa-0000-0000-0000-000000000001', 2026, current_date, t.id, 'Self accepted', 5, true,
         'self_declared', 'accepted'
    from public.cpd_activity_types t where t.code = 'test_logged' limit 1$$,
  '42501', null, 'A member cannot insert a CPD entry that is already accepted');

select throws_ok($$
  insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points,
                                  is_core, how_recorded, status)
  select 'aaaaaaaa-0000-0000-0000-000000000001', 2026, current_date, t.id, 'Self awarded', 5, true,
         'awarded_by_ami', 'pending'
    from public.cpd_activity_types t where t.code = 'test_logged' limit 1$$,
  '42501', null, 'A member cannot insert a CPD entry marked as awarded by AMI');

select lives_ok($$
  insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points,
                                  is_core, how_recorded, status)
  select 'aaaaaaaa-0000-0000-0000-000000000001', 2026, current_date, t.id, 'A genuine entry', 2, false,
         'self_declared', 'pending'
    from public.cpd_activity_types t where t.code = 'test_logged' limit 1$$,
  'A member CAN insert a self declared, pending entry');

select is(
  try_dml($sql$update public.cpd_entries set points = 99 where title = 'Four stage clearance refresher'$sql$),
  0, 'A member cannot edit an entry once staff have accepted it');
reset role;

-- An automatic entry with no rule and no source behind it is impossible, whoever
-- writes it. This is the constraint that will matter when automatic CPD arrives.
select throws_ok($$
  insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points,
                                  is_core, how_recorded, status, reviewed_by, reviewed_at)
  select 'aaaaaaaa-0000-0000-0000-000000000001', 2026, current_date, t.id, 'No rule', 1, true,
         'automatic', 'accepted', '33333333-3333-3333-3333-333333333333', now()
    from public.cpd_activity_types t where t.code = 'test_logged' limit 1$$,
  '23514', null, 'An automatic CPD entry cannot exist without a rule and a source');

-- The summary counts accepted entries only.
select is((select core_points from public.cpd_year_summaries
            where member_id = 'aaaaaaaa-0000-0000-0000-000000000001' and year = 2026),
          3.0::numeric(6,1), 'The year summary counts accepted entries only');

-- =============================================================================
-- 6. A forum post is editable until it receives a reply
-- =============================================================================
select sign_in_as('11111111-1111-1111-1111-111111111111');
select is(
  try_dml($sql$update public.forum_posts set body = 'The opening post, edited.' where id = 'eeeeeeee-0000-0000-0000-000000000001'$sql$),
  1, 'A member CAN edit their own post while it has no reply');
reset role;

select sign_in_as('22222222-2222-2222-2222-222222222222');
insert into public.forum_posts (thread_id, author_id, body)
values ('dddddddd-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', 'A reply.');
reset role;

select sign_in_as('11111111-1111-1111-1111-111111111111');
select is(
  try_dml($sql$update public.forum_posts set body = 'Rewritten after the reply.' where id = 'eeeeeeee-0000-0000-0000-000000000001'$sql$),
  0, 'A member cannot edit their own post once it has a reply');
select is(
  try_dml($sql$delete from public.forum_posts where id = 'eeeeeeee-0000-0000-0000-000000000001'$sql$),
  0, 'A member cannot delete their own post once it has a reply');
reset role;

select is((select count(*)::int from public.forum_post_revisions
            where post_id = 'eeeeeeee-0000-0000-0000-000000000001'),
          1, 'The previous body is kept on every edit');

-- =============================================================================
-- 7. The banned word filter holds a post rather than dropping it
-- =============================================================================
select sign_in_as('22222222-2222-2222-2222-222222222222');
insert into public.forum_posts (id, thread_id, author_id, body)
values ('eeeeeeee-0000-0000-0000-000000000009', 'dddddddd-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000002', 'This post mentions a badger.');
select is((select status from public.forum_posts where id = 'eeeeeeee-0000-0000-0000-000000000009'),
          'held'::public.forum_post_status, 'A post containing a banned word is held, not published');
select is((select count(*)::int from public.forum_posts
            where id = 'eeeeeeee-0000-0000-0000-000000000009'),
          1, 'The author can still see their own held post');
reset role;

select sign_in_as('11111111-1111-1111-1111-111111111111');
select is((select count(*)::int from public.forum_posts
            where id = 'eeeeeeee-0000-0000-0000-000000000009'),
          0, 'Another member cannot see a held post');
select is((select count(*)::int from public.banned_words), 0,
          'A member cannot read the banned word list');
reset role;

-- Whole word matching does not catch an innocent word that contains a banned one.
select ok(app.find_banned_word('The badgerwatch society met on Tuesday.') is null,
          'Whole word matching does not catch an innocent word containing a banned one');
select is(app.find_banned_word('what a baaadger'), 'badger',
          'A padded word is still caught: baaadger matches badger');

-- The trap this schema very nearly walked into. The old matcher collapsed any
-- run of a repeated character to one, in the post AND in the word, which turned
-- "ass" into "as". On a forum where every other sentence contains an assessment
-- or an analysis, that would have held a great many innocent posts.
-- on conflict, because the real word list may or may not have been loaded on
-- this database and the test must behave the same either way
insert into public.banned_words (word, match_type) values ('ass', 'whole_word')
on conflict (lower(word)) do nothing;

select ok(app.find_banned_word('The assessment was completed on Tuesday.') is null,
          'assessment is not caught by ass');
select ok(app.find_banned_word('Bulk analysis confirmed chrysotile.') is null,
          'analysis is not caught by anal');
select ok(app.find_banned_word('Send it to me as soon as you can.') is null,
          'the ordinary word as is not caught by ass');
select is(app.find_banned_word('do not be an ass about it'), 'ass',
          'but the actual word is still caught');

-- =============================================================================
-- 8. Application tokens are readable by nobody
-- =============================================================================
set local role anon;
select throws_ok('select * from public.application_tokens', '42501', null,
                 'anon cannot read application tokens');
reset role;
select sign_in_as('33333333-3333-3333-3333-333333333333');
select throws_ok('select * from public.application_tokens', '42501', null,
                 'Even membership staff cannot read application tokens');
reset role;

-- =============================================================================
-- 9. The audit log is append only, including for the service role
-- =============================================================================
select sign_in_as('33333333-3333-3333-3333-333333333333');
select throws_ok('update public.audit_log set note = ''changed''', null, null,
                 'Staff cannot update the audit log');
reset role;

set local role service_role;
select throws_ok('update public.audit_log set note = ''changed''', '42501', null,
                 'The SERVICE ROLE cannot update the audit log either');
select throws_ok('delete from public.audit_log', '42501', null,
                 'The service role cannot delete from the audit log');
reset role;

select cmp_ok((select count(*) from public.audit_log where table_name = 'members'), '>', 0::bigint,
              'Changes to a membership are written to the audit log');

-- =============================================================================
-- 10. Roles are granted only by a super user
-- =============================================================================
select sign_in_as('33333333-3333-3333-3333-333333333333');
select throws_ok($$insert into public.role_grants (person_id, role_code)
                   values ('33333333-3333-3333-3333-333333333333', 'super_user')$$,
                 '42501', null,
                 'A member of staff who is not a super user cannot grant themselves a role');
reset role;

select sign_in_as('44444444-4444-4444-4444-444444444444');
select throws_ok($$delete from public.role_grants
                   where person_id = '44444444-4444-4444-4444-444444444444'
                     and role_code = 'super_user'$$,
                 '42501', null, 'A super user cannot remove their own super user role');
reset role;

-- =============================================================================
-- 11. Storage: a member cannot fetch another member's photograph
-- =============================================================================
select sign_in_as('11111111-1111-1111-1111-111111111111');
select is((select count(*)::int from storage.objects
            where bucket_id = 'member-photos'), 1,
          'A member sees only their own photograph in storage');
reset role;

-- =============================================================================
-- 12. Switching a membership off removes it from both public views
-- =============================================================================
-- cccccccc was switched inactive in test 4.
select is((select count(*)::int from public.public_register
            where membership_number = 'TEST-M-0003'), 0,
          'An inactive membership disappears from the public register');
-- Changed by 0026, on Steve's decision of 9 August 2026. An inactive membership
-- used to disappear from here, which meant a card already printed led to a page
-- saying the same thing a mistyped address gets, and a duty holder could not tell
-- a lapsed member from a forged card.
--
-- It now answers, and says no. What it must NOT do is keep publishing the things
-- somebody agreed to while they were a member, so the next three assertions are
-- as much the point as the first.
select is((select count(*)::int from public.public_profile where slug = 'test-liam-lapsed'), 1,
          'An inactive membership still answers on the public profile view');
select is((select is_active from public.public_profile where slug = 'test-liam-lapsed'), false,
          'and says plainly that it is not current');
select is((select photo_path from public.public_profile where slug = 'test-liam-lapsed'), null,
          'and its photograph is not published once the membership has gone');
select is((select employer from public.public_profile where slug = 'test-liam-lapsed'), null,
          'nor the employer');
select is((select cpd_status from public.public_profile where slug = 'test-liam-lapsed'), null,
          'nor the CPD position, which is nobody''s business without a membership behind it');
select isnt((select membership_number from public.public_profile where slug = 'test-liam-lapsed'), null,
          'but the membership number stays, because that is what a duty holder is matching');
select is((select count(*)::int from public.public_profile where slug = 'test-alice-adeyemi'), 1,
          'An active membership still resolves on the public profile view');

-- =============================================================================
-- 13. The photograph appears on the public page only where the member allows it
-- =============================================================================
update public.people set photo_path = 'member-photos/1111/face.jpg', photo_consent = true,
       photo_consent_at = now()
 where id = '11111111-1111-1111-1111-111111111111';

select is((select photo_path from public.public_profile where slug = 'test-alice-adeyemi'), null,
          'The photograph is absent from the public page until the member switches it on');

update public.member_preferences set photo_on_public_page = true
 where member_id = 'aaaaaaaa-0000-0000-0000-000000000001';

select isnt((select photo_path from public.public_profile where slug = 'test-alice-adeyemi'), null,
            'The photograph appears once the member switches it on');

-- =============================================================================
-- 13b. Lifting FORCE weakens nothing for a client
-- =============================================================================
-- FORCE only ever bound the table owner. These prove a signed in member still
-- cannot write to the tables where it was lifted.
set local role anon;
select throws_ok('insert into public.audit_log (action, table_name) values (''X'', ''y'')',
                 '42501', null, 'anon still cannot write to the audit log');
reset role;

select sign_in_as('11111111-1111-1111-1111-111111111111');
select throws_ok('insert into public.audit_log (action, table_name) values (''X'', ''y'')',
                 '42501', null, 'A member still cannot write to the audit log');
select throws_ok($$insert into public.role_grants (person_id, role_code)
                   values ('11111111-1111-1111-1111-111111111111', 'super_user')$$,
                 '42501', null, 'A member still cannot grant themselves a role');
select is((select count(*)::int from public.people), 1,
          'and a member still sees only their own person row, forcing or not');
reset role;

-- =============================================================================
-- 13c. A member without an account is still a member
-- =============================================================================
select is((select count(*)::int from public.public_register
            where membership_number = 'TEST-M-0007'), 1,
          'A member who has never signed in still appears on the public register');
select is((select count(*)::int from public.public_profile where slug = 'test-nina-nolan'), 1,
          'and their profile page still resolves');

-- Linking: an account signing in for the first time joins the record waiting for it.
insert into auth.users (id, email) values
  ('88888888-8888-8888-8888-888888888888', 'nina@test.invalid');
select sign_in_as('88888888-8888-8888-8888-888888888888');
select is(app.link_account(), '77777777-7777-7777-7777-777777777777'::uuid,
          'Signing in for the first time links the account to the person already there');
reset role;

-- Somebody who signs up and is not a member gets nothing, which is not an error.
insert into auth.users (id, email) values
  ('99999999-9999-9999-9999-999999999999', 'stranger@test.invalid');
select sign_in_as('99999999-9999-9999-9999-999999999999');
select is(app.link_account(), null, 'An account with no member record links to nothing');
reset role;

-- =============================================================================
-- 14. The first super user gets in, and nobody else does
-- =============================================================================
select is(
  (select count(*)::int from public.role_grants
    where person_id = '66666666-6666-6666-6666-666666666666' and role_code = 'super_user'),
  1, 'An email listed in bootstrap_super_users is granted super_user on first sign in');

select is(
  (select count(*)::int from public.role_grants
    where person_id = '11111111-1111-1111-1111-111111111111' and role_code = 'super_user'),
  0, 'An email that is not listed is granted nothing');

select sign_in_as('11111111-1111-1111-1111-111111111111');
select is((select count(*)::int from public.bootstrap_super_users), 0,
          'A member cannot read the list of bootstrap super users');
reset role;

-- =============================================================================
-- 15. A membership year takes the fee set for the grade
-- =============================================================================
insert into public.membership_years (member_id, year)
values ('aaaaaaaa-0000-0000-0000-000000000001', 2099);

select is((select fee_pence from public.membership_years
            where member_id = 'aaaaaaaa-0000-0000-0000-000000000001' and year = 2099),
          12000, 'A membership year created without a fee takes the fee set for that grade and year');

-- -----------------------------------------------------------------------------
-- The verdict
-- -----------------------------------------------------------------------------
-- The Supabase SQL editor shows only the last result, and pgTAP reports a failed
-- test as a row rather than as an error, so a quiet run would look like a pass.
-- This turns any failure into a red error you cannot miss.
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 75. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 75 TESTS PASSED' as result;

rollback;
