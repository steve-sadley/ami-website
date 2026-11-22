-- =============================================================================
-- 0038, the CPD scheme for 2027, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- The value of an entry now comes from its activity, some activities need a
-- reflection of a minimum length, some cannot be logged by hand at all, and one
-- can be logged once a year. Each of those is asserted here from both routes a
-- member has into cpd_entries: log_cpd, and a direct insert from a browser
-- console, which is the route a rule in the page alone would not cover.
--
-- Every fixture value is prefixed or uses a .invalid address. A person's id and
-- their login id are different on purpose (see "A PERSON IS NOT A LOGIN").
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(30);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;

insert into auth.users (id, email) values
  ('c2c20000-0000-0000-0000-000000000001', 'cpd27.one@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('c2c21111-0000-0000-0000-000000000001', 'c2c20000-0000-0000-0000-000000000001',
   'Cora', 'Twentyseven', 'cpd27.one@test.invalid');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'c2c22222-0000-0000-0000-000000000001', 'c2c21111-0000-0000-0000-000000000001',
       'TEST-C27-0001', g.id, date '2021-01-01', true, 'current'
  from public.membership_grades g where g.code = 'member';
insert into public.member_preferences (member_id) values ('c2c22222-0000-0000-0000-000000000001');

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function type_id(c text) returns uuid language sql as $$
  select id from public.cpd_activity_types where code = c $$;

-- 520 words, and 499.
create or replace function words(n int) returns text language sql as $$
  select string_agg('word' || i, ' ') from generate_series(1, n) i $$;

-- -----------------------------------------------------------------------------
-- 1. The agreed table
-- -----------------------------------------------------------------------------
select is((select count(*)::int from public.cpd_activity_types
            where active and code in ('ami_committee','ami_agm','ami_seminar','technical_review',
              'arca_training','practice_management','regional_meeting_2027','arca_agm',
              'external_training','qualification','training_reflection','arca_news','article',
              'self_directed')), 14,
          'the fourteen activities of the 2027 scheme are there and switched on');

select is((select count(*)::int from public.cpd_activity_types
            where active and code in ('course_assessed','course_unassessed','seminar','webinar',
              'reading_technical','site_learning','assessment_passed','regional_meeting','committee',
              'mentoring','writing_presenting','reading_general','soft_skills','briefing_delivered')), 0,
          'and none of the August fourteen is switched on');

select is((select points::text || ' ' || is_core::text from public.cpd_activity_types where code = 'ami_seminar'),
          '3.0 true', 'an AMI Seminar is 3 core points');
select is((select points::text || ' ' || is_core::text from public.cpd_activity_types where code = 'arca_training'),
          '1.0 true', 'an ARCA training course is 1 CORE point');
select is((select points::text || ' ' || is_core::text from public.cpd_activity_types where code = 'arca_agm'),
          '1.0 false', 'the ARCA AGM is 1 point, separate from the AMI AGM');
select is((select points_min::text || '-' || points_max::text from public.cpd_activity_types
            where code = 'technical_review' and points is null),
          '0.5-2.0', 'a Technical Review is valued item by item, half a point to two');
select is((select min_words from public.cpd_activity_types where code = 'training_reflection'),
          500, 'a reflection following a training course needs 500 words');
select ok((select once_per_year from public.cpd_activity_types where code = 'practice_management'),
          'Practice of Management is once a year');

select throws_ok($$
  insert into public.cpd_activity_types (code, name, is_core, active) values ('zz-test-novalue', 'No value', true, true)
$$, '23514', null, 'an activity cannot be switched on without a value');

-- -----------------------------------------------------------------------------
-- 2. Counting words
-- -----------------------------------------------------------------------------
select is(app.word_count('One two three.'), 3, 'three words are three');
select is(app.word_count('Don''t stop'), 2, 'an apostrophe does not split a word');
select is(app.word_count('--- ... *** ///'), 0, 'punctuation is not words');
select is(app.word_count(null), 0, 'nothing is no words');

-- -----------------------------------------------------------------------------
-- 3. log_cpd
-- -----------------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'log_cpd'), 1,
          'there is one log_cpd, and the version that took a points claim is gone');

select sign_in_as('c2c20000-0000-0000-0000-000000000001');

select lives_ok($$ select public.log_cpd(current_date - 3, type_id('self_directed'), 'TEST reading on RPE') $$,
  'a member logs self directed learning');
select is((select points::text || ' ' || is_core::text from public.my_cpd where title = 'TEST reading on RPE'),
          '1.0 false', 'and it is worth what the activity says, as non core');

select throws_ok($$ select public.log_cpd(current_date - 3, type_id('training_reflection'),
                    'TEST short reflection', null, null, null, words(499)) $$,
  '22023', null, 'a reflection of 499 words is refused');
select lives_ok($$ select public.log_cpd(current_date - 3, type_id('training_reflection'),
                    'TEST full reflection', null, null, null, words(520)) $$,
  'and one of 520 is taken');
select is((select points from public.my_cpd where title = 'TEST full reflection'), 2.0::numeric,
          'worth 2 points');

select throws_ok($$ select public.log_cpd(current_date - 3, type_id('ami_seminar'), 'TEST claimed seminar') $$,
  '22023', null, 'a seminar cannot be logged by hand: attendance or the recording awards it');
select throws_ok($$ select public.log_cpd(current_date - 3, type_id('technical_review'), 'TEST claimed review') $$,
  '22023', null, 'nor a Technical Review, which comes from its questions');

select lives_ok($$ select public.log_cpd(current_date - 3, type_id('practice_management'), 'TEST manager') $$,
  'Practice of Management is declared');
select throws_ok($$ select public.log_cpd(current_date - 2, type_id('practice_management'), 'TEST manager again') $$,
  '22023', null, 'and a second declaration in the same year is refused');

-- -----------------------------------------------------------------------------
-- 4. Round the side: a direct insert from a browser console
-- -----------------------------------------------------------------------------
insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points,
                                is_core, how_recorded, status)
values ('c2c22222-0000-0000-0000-000000000001', extract(year from current_date)::int,
        current_date - 1, type_id('self_directed'), 'TEST greedy direct', 10, true,
        'self_declared', 'pending');
reset role;
select is((select points::text || ' ' || is_core::text from public.cpd_entries where title = 'TEST greedy direct'),
          '1.0 false', 'a direct insert claiming 10 core points is stored as the 1 non core the activity is worth');

select sign_in_as('c2c20000-0000-0000-0000-000000000001');
select throws_ok($$
  insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points,
                                  is_core, how_recorded, status)
  values ('c2c22222-0000-0000-0000-000000000001', extract(year from current_date)::int,
          current_date - 1, type_id('ami_seminar'), 'TEST direct seminar', 3, true,
          'self_declared', 'pending') $$,
  '42501', null, 'a direct insert of an activity that cannot be logged by hand is refused');
select throws_ok($$
  insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points,
                                  is_core, how_recorded, status, reflection)
  values ('c2c22222-0000-0000-0000-000000000001', extract(year from current_date)::int,
          current_date - 1, type_id('training_reflection'), 'TEST direct reflection', 2, false,
          'self_declared', 'pending', 'Three words only') $$,
  '22023', null, 'a direct insert with a short reflection is refused');
reset role;

-- -----------------------------------------------------------------------------
-- 5. Receipts
-- -----------------------------------------------------------------------------
select ok((select cpd_receipts from public.member_preferences
            where member_id = 'c2c22222-0000-0000-0000-000000000001'),
          'a new member gets CPD receipts unless they turn them off');

-- 0039: and they cannot turn them off, by the table or by the token route.
select sign_in_as('c2c20000-0000-0000-0000-000000000001');
update public.member_preferences set cpd_receipts = false
 where member_id = 'c2c22222-0000-0000-0000-000000000001';
reset role;
select ok((select cpd_receipts from public.member_preferences
            where member_id = 'c2c22222-0000-0000-0000-000000000001'),
          'a member switching receipts off directly leaves them on');
select is(public.unsubscribe_all_by_token((select unsubscribe_token from public.member_preferences
            where member_id = 'c2c22222-0000-0000-0000-000000000001')), true,
          'stop everything still succeeds');
select ok((select cpd_receipts and not email_newsletter from public.member_preferences
            where member_id = 'c2c22222-0000-0000-0000-000000000001'),
          'and turns off what it may while the receipt stays on');

-- -----------------------------------------------------------------------------
do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 30. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 30 TESTS PASSED' as result;

rollback;
