-- =============================================================================
-- 0041, read and answer and watch and answer, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: the answers never reach a member; marking is the database's;
-- 80% passes; one retake; points once, with a receipt; one event never awards
-- twice; nobody but a current member can answer; an editor cannot publish a
-- broken item.
--
-- Every fixture value is prefixed or uses a .invalid address. A person's id and
-- their login id differ on purpose.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(32);

-- -----------------------------------------------------------------------------
-- Fixtures: two current members, one lapsed, one editor
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;
insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select extract(year from current_date)::int, g.id, 5, 5 from public.membership_grades g where g.code = 'member'
on conflict (year, grade_id) do nothing;

insert into auth.users (id, email) values
  ('1e1e0000-0000-0000-0000-000000000001', 'learn.one@test.invalid'),
  ('1e1e0000-0000-0000-0000-000000000002', 'learn.two@test.invalid'),
  ('1e1e0000-0000-0000-0000-000000000003', 'learn.lapsed@test.invalid'),
  ('1e1e0000-0000-0000-0000-000000000004', 'learn.editor@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('1e1e1111-0000-0000-0000-000000000001','1e1e0000-0000-0000-0000-000000000001','Lena','One','learn.one@test.invalid'),
  ('1e1e1111-0000-0000-0000-000000000002','1e1e0000-0000-0000-0000-000000000002','Leo','Two','learn.two@test.invalid'),
  ('1e1e1111-0000-0000-0000-000000000003','1e1e0000-0000-0000-0000-000000000003','Lou','Lapsed','learn.lapsed@test.invalid'),
  ('1e1e1111-0000-0000-0000-000000000004','1e1e0000-0000-0000-0000-000000000004','Ed','Itor','learn.editor@test.invalid');
insert into public.role_grants (person_id, role_code) values ('1e1e1111-0000-0000-0000-000000000004', 'editor');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', v.act, v.st::public.member_status
  from (values
    ('1e1e2222-0000-0000-0000-000000000001','1e1e1111-0000-0000-0000-000000000001','TEST-L-0001', true,  'current'),
    ('1e1e2222-0000-0000-0000-000000000002','1e1e1111-0000-0000-0000-000000000002','TEST-L-0002', true,  'current'),
    ('1e1e2222-0000-0000-0000-000000000003','1e1e1111-0000-0000-0000-000000000003','TEST-L-0003', false, 'lapsed')
  ) as v(mid, pid, num, act, st), public.membership_grades g where g.code = 'member';
insert into public.member_preferences (member_id) values
  ('1e1e2222-0000-0000-0000-000000000001'), ('1e1e2222-0000-0000-0000-000000000002'),
  ('1e1e2222-0000-0000-0000-000000000003');

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function type_id(c text) returns uuid language sql as $$
  select id from public.cpd_activity_types where code = c $$;

-- Five questions, so 4 of 5 is exactly the 80% pass mark and 3 of 5 is not.
create or replace function five() returns jsonb language sql as $$
  select '[{"q":"One?","options":["a","b"],"answer":0},
           {"q":"Two?","options":["a","b"],"answer":1},
           {"q":"Three?","options":["a","b","c"],"answer":2},
           {"q":"Four?","options":["a","b"],"answer":0},
           {"q":"Five?","options":["a","b"],"answer":1}]'::jsonb $$;

-- -----------------------------------------------------------------------------
-- 1. An editor writes items, and the database refuses a broken one
-- -----------------------------------------------------------------------------
select sign_in_as('1e1e0000-0000-0000-0000-000000000004');

select lives_ok($$
  insert into public.cpd_learning_items (id, slug, title, kind, activity_type_id, points, body, questions, status)
  values ('1e1e3333-0000-0000-0000-000000000001', 'zz-test-review', 'ZZ TEST Technical Review',
          'read', type_id('technical_review'), 1.5,
          'A long enough piece of text about the regulations for a reader.', five(), 'published') $$,
  'an editor publishes a Technical Review');

select is((select points from public.cpd_learning_items where slug = 'zz-test-review'), 1.5::numeric,
          'valued within the Technical Review range as the editor set it');

select throws_ok($$
  insert into public.cpd_learning_items (slug, title, kind, activity_type_id, points, body, questions, status)
  values ('zz-test-toomuch', 'ZZ TEST too much', 'read', type_id('technical_review'), 3,
          'A long enough piece of text about the regulations.', five(), 'published') $$,
  '22023', null, 'a Technical Review worth 3 points is refused: the range is 0.5 to 2');

select lives_ok($$
  insert into public.cpd_learning_items (id, slug, title, kind, activity_type_id, points, vimeo_id, questions, status, event_key)
  values ('1e1e3333-0000-0000-0000-000000000002', 'zz-test-seminar', 'ZZ TEST seminar recording',
          'watch', type_id('ami_seminar'), 1, '123456789', five(), 'published', 'zz-test-seminar-2027') $$,
  'an editor publishes a seminar recording');
select is((select points from public.cpd_learning_items where slug = 'zz-test-seminar'), 3.0::numeric,
          'and it is worth what a seminar is worth, whatever was typed');

select throws_ok($$
  insert into public.cpd_learning_items (slug, title, kind, activity_type_id, points, body, questions, status)
  values ('zz-test-noq', 'ZZ TEST no questions', 'read', type_id('arca_news'), 1,
          'A long enough piece of text about the news.', '[]', 'published') $$,
  '22023', null, 'an item cannot be published with no questions');
select throws_ok($$
  insert into public.cpd_learning_items (slug, title, kind, activity_type_id, points, body, questions, status)
  values ('zz-test-badq', 'ZZ TEST bad answer', 'read', type_id('arca_news'), 1,
          'A long enough piece of text about the news.',
          '[{"q":"Which?","options":["a","b"],"answer":5}]', 'published') $$,
  '22023', null, 'a question whose right answer is not one of its options is refused');
select throws_ok($$
  insert into public.cpd_learning_items (slug, title, kind, activity_type_id, points, questions, status)
  values ('zz-test-novid', 'ZZ TEST no video', 'watch', type_id('ami_seminar'), 3, five(), 'published') $$,
  '22023', null, 'a video item cannot be published without its Vimeo number');
select lives_ok($$
  insert into public.cpd_learning_items (id, slug, title, kind, activity_type_id, points, questions, status)
  values ('1e1e3333-0000-0000-0000-000000000003', 'zz-test-draft', 'ZZ TEST draft', 'read',
          type_id('arca_news'), 1, '[]', 'draft') $$,
  'a draft can be saved half written');
reset role;

-- -----------------------------------------------------------------------------
-- 2. A member never sees an answer
-- -----------------------------------------------------------------------------
select sign_in_as('1e1e0000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.cpd_learning_items), 0,
          'a member reads nothing from the items table itself');
select is((select count(*)::int from public.my_learning where slug like 'zz-test-%'), 2,
          'and sees the two published items through my_learning, not the draft');
select ok(not exists (select 1 from public.my_learning, jsonb_array_elements(questions) q where q ? 'answer'),
          'no question that reaches a member carries its answer');
select is((select jsonb_array_length(questions) from public.my_learning where slug = 'zz-test-review'), 5,
          'while every question and its options do');
select throws_ok($$ select app.award_cpd(null, null, 1, 'x', current_date, null, null, 'x') $$,
          '42501', null, 'a member cannot reach the award function directly');

-- -----------------------------------------------------------------------------
-- 3. Marking, the pass mark and the retake
-- -----------------------------------------------------------------------------
select is((public.submit_learning('1e1e3333-0000-0000-0000-000000000001', array[0,1,2,1,0]) ->> 'passed'),
          'false', 'three of five is 60% and fails');
select is((public.submit_learning('1e1e3333-0000-0000-0000-000000000001', array[0,1,2,1,0]) ->> 'score'),
          '60', 'but the reply gives the score');
reset role;
select ok(not exists (select 1 from public.cpd_entries where title = 'ZZ TEST Technical Review'),
          'and two failures award nothing');
select sign_in_as('1e1e0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.submit_learning('1e1e3333-0000-0000-0000-000000000001', array[0,1,2,0,1]) $$,
          '22023', null, 'a third attempt is refused: one retake, two attempts in all');
reset role;

select sign_in_as('1e1e0000-0000-0000-0000-000000000002');
select is(public.submit_learning('1e1e3333-0000-0000-0000-000000000001', array[0,1,2,0,0]) ->> 'passed',
          'true', 'four of five is exactly 80% and passes');
select throws_ok($$ select public.submit_learning('1e1e3333-0000-0000-0000-000000000001', array[0,1,2,0,1]) $$,
          '22023', null, 'once passed, it cannot be taken again for more points');
select throws_ok($$ select public.submit_learning('1e1e3333-0000-0000-0000-000000000001', array[0,1]) $$,
          '22023', null, 'every question must be answered');
reset role;

select is((select points::text || ' ' || is_core::text || ' ' || how_recorded::text || ' ' || status::text
             from public.cpd_entries where member_id = '1e1e2222-0000-0000-0000-000000000002'
              and title = 'ZZ TEST Technical Review'),
          '1.5 true automatic accepted', 'the pass is 1.5 core points, automatic and accepted');
select ok((select rule_id = '1e1e3333-0000-0000-0000-000000000001' and source_id is not null and reviewed_at is not null
             from public.cpd_entries where member_id = '1e1e2222-0000-0000-0000-000000000002'
              and title = 'ZZ TEST Technical Review'),
          'naming the item as its rule and the attempt as its source');
select is((select count(*)::int from public.email_outbox
            where to_email = 'learn.two@test.invalid' and template_code = 'cpd_awarded'), 1,
          'and one receipt is queued');
select ok((select html like '%1.5 core CPD points%' and html like '%ZZ TEST Technical Review%' and html like '%1.5 of 5%'
             from public.email_outbox where to_email = 'learn.two@test.invalid' and template_code = 'cpd_awarded'),
          'saying what was earned, for what, and where the member now stands');

-- -----------------------------------------------------------------------------
-- 4. One event, once
-- -----------------------------------------------------------------------------
-- Leo attended the seminar live. The attendance feed is not built yet, so the
-- award it will make is made here directly, with the same event key.
select ok(app.award_cpd('1e1e2222-0000-0000-0000-000000000002', type_id('ami_seminar'), 3, 'ZZ TEST seminar live',
                        current_date, '1e1e3333-0000-0000-0000-000000000002', gen_random_uuid(),
                        'zz-test-seminar-2027') is not null, 'attending the seminar awards it');
select sign_in_as('1e1e0000-0000-0000-0000-000000000002');
select is(public.submit_learning('1e1e3333-0000-0000-0000-000000000002', array[0,1,2,0,1]) ->> 'already_counted',
          'true', 'passing its recording afterwards is a pass, and says it already counted');
reset role;
select is((select count(*)::int from public.cpd_entries where member_id = '1e1e2222-0000-0000-0000-000000000002'
            and event_key = 'zz-test-seminar-2027'), 1, 'and the seminar is on the record once');
select is((select count(*)::int from public.email_outbox
            where to_email = 'learn.two@test.invalid' and template_code = 'cpd_awarded'), 2,
          'with a receipt for the live attendance and none for the recording');

-- -----------------------------------------------------------------------------
-- 5. Who can answer
-- -----------------------------------------------------------------------------
select sign_in_as('1e1e0000-0000-0000-0000-000000000003');
select is((select count(*)::int from public.my_learning), 0, 'a lapsed member sees nothing to answer');
select throws_ok($$ select public.submit_learning('1e1e3333-0000-0000-0000-000000000001', array[0,1,2,0,1]) $$,
          '42501', null, 'and cannot answer');
reset role;
set local role anon;
select throws_ok($$ select * from public.my_learning $$, '42501', null, 'a visitor cannot read the items at all');
reset role;

-- -----------------------------------------------------------------------------
do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 32. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 32 TESTS PASSED' as result;

rollback;
