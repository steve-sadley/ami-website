-- =============================================================================
-- 0043, CPD reflections reviewed with AI help, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: AI never decides an entry; the record says when it assisted;
-- Claude is sent the reflection and nothing about the person; a recommendation
-- can be written only by the site, for an entry staff asked about just now;
-- a recommendation on words the member has since changed stops counting; a
-- guide that has been used is not rewritten.
--
-- Every fixture value is prefixed or uses a .invalid address. A person's id and
-- their login id differ on purpose.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(37);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;
insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select extract(year from current_date)::int, g.id, 5, 5 from public.membership_grades g where g.code = 'member'
on conflict (year, grade_id) do nothing;

insert into auth.users (id, email) values
  ('3a3a0000-0000-0000-0000-000000000001', 'ai.member@test.invalid'),
  ('3a3a0000-0000-0000-0000-000000000009', 'ai.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('3a3a1111-0000-0000-0000-000000000001','3a3a0000-0000-0000-0000-000000000001','Rhiannon','Reflects','ai.member@test.invalid'),
  ('3a3a1111-0000-0000-0000-000000000009','3a3a0000-0000-0000-0000-000000000009','Owen','Office','ai.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('3a3a1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '3a3a2222-0000-0000-0000-000000000001', '3a3a1111-0000-0000-0000-000000000001', 'TEST-AI-0001',
       g.id, date '2021-01-01', true, 'current'
  from public.membership_grades g where g.code = 'member';
insert into public.member_preferences (member_id) values ('3a3a2222-0000-0000-0000-000000000001');

create or replace function type_id(c text) returns uuid language sql as $$
  select id from public.cpd_activity_types where code = c $$;
create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function words(n int) returns text language sql as $$
  select btrim(repeat('asbestos ', n)) $$;

-- Three pending reflections and one entry that needs none. Written as the
-- owner, the way log_cpd writes them.
insert into public.cpd_entries
  (id, member_id, year, occurred_on, activity_type_id, title, provider, points, is_core, status, how_recorded, reflection, recorded_at)
values
  ('3a3a4444-0000-0000-0000-000000000001', '3a3a2222-0000-0000-0000-000000000001',
   extract(year from current_date)::int, current_date - 3, type_id('training_reflection'),
   'ZZ TEST reflection one', 'ZZ TEST provider', 2, false, 'pending', 'self_declared', words(520), now() - interval '3 hours'),
  ('3a3a4444-0000-0000-0000-000000000002', '3a3a2222-0000-0000-0000-000000000001',
   extract(year from current_date)::int, current_date - 2, type_id('training_reflection'),
   'ZZ TEST reflection two', null, 2, false, 'pending', 'self_declared', words(510), now() - interval '2 hours'),
  ('3a3a4444-0000-0000-0000-000000000003', '3a3a2222-0000-0000-0000-000000000001',
   extract(year from current_date)::int, current_date - 1, type_id('training_reflection'),
   'ZZ TEST reflection three', null, 2, false, 'pending', 'self_declared', words(505), now() - interval '1 hour'),
  ('3a3a4444-0000-0000-0000-000000000004', '3a3a2222-0000-0000-0000-000000000001',
   extract(year from current_date)::int, current_date - 1, type_id('self_directed'),
   'ZZ TEST no reflection needed', null, 1, false, 'pending', 'self_declared', null, now() - interval '4 hours');

create temporary table asked (n int, body jsonb) on commit drop;
grant all on asked to public;

-- -----------------------------------------------------------------------------
-- 1. The guide
-- -----------------------------------------------------------------------------
select ok((select count(*) from public.cpd_review_guides where active and body like '%Recommend ACCEPT%') >= 1,
          'a first guide is in place for the office to change');

-- -----------------------------------------------------------------------------
-- 2. A member reaches none of it
-- -----------------------------------------------------------------------------
select sign_in_as('3a3a0000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.cpd_review_guides), 0, 'a member reads no guide');
select is((select count(*)::int from public.cpd_ai_reviews), 0, 'and no recommendation');
select throws_ok($$ select public.ai_review_begin(3) $$, '42501', null, 'and cannot ask Claude anything');
select lives_ok($$
  insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points, is_core,
                                  status, how_recorded, ai_assisted)
  values ('3a3a2222-0000-0000-0000-000000000001', extract(year from current_date)::int, current_date,
          type_id('self_directed'), 'ZZ TEST console entry', 1, false, 'pending', 'self_declared', true) $$,
  'a member inserting their own entry from a console is not refused');
reset role;
select is((select ai_assisted from public.cpd_entries where title = 'ZZ TEST console entry'), false,
          'but cannot mark it as AI assisted');

-- -----------------------------------------------------------------------------
-- 3. Asking
-- -----------------------------------------------------------------------------
select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
insert into asked values (1, public.ai_review_begin(2));
reset role;

select is((select jsonb_array_length(body -> 'items') from asked where n = 1), 2,
          'staff ask about two, and get the two oldest reflections waiting');
select is((select array_agg(i ->> 'id' order by i ->> 'id') from asked, jsonb_array_elements(body -> 'items') i where n = 1),
          array['3a3a4444-0000-0000-0000-000000000001', '3a3a4444-0000-0000-0000-000000000002'],
          'oldest first, and never the entry that needs no reflection');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(i) k)
                            = array['activity','id','min_words','occurred_on','provider','reflection','title','words'])
             from asked, jsonb_array_elements(body -> 'items') i where n = 1),
          'each carries the activity, the title, the provider, the date and the words, and NOTHING about the person');
select ok((select body::text from asked where n = 1) !~* '(Rhiannon|Reflects|TEST-AI-0001|ai\.member)',
          'no name, no membership number and no address anywhere in what goes to Claude');
select ok((select (body ->> 'guide') like '%Recommend ACCEPT%' and body ->> 'model' <> '' from asked where n = 1),
          'with the guide and the model to use');

select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
insert into asked values (2, public.ai_review_begin(5));
reset role;
select is((select array_agg(i ->> 'id') from asked, jsonb_array_elements(body -> 'items') i where n = 2),
          array['3a3a4444-0000-0000-0000-000000000003'],
          'asking again straight away does not hand out the two already being read');

-- -----------------------------------------------------------------------------
-- 4. Only the site records, and only what it was asked
-- -----------------------------------------------------------------------------
select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
select throws_ok($$ select public.ai_review_record('3a3a4444-0000-0000-0000-000000000001',
                     '3a3a1111-0000-0000-0000-000000000009', (select id from public.cpd_review_guides limit 1),
                     'x', 'accept', 'made up') $$,
  '42501', null, 'staff cannot write a recommendation, even on an entry they asked about');
reset role;
select ok(not has_function_privilege('authenticated', 'public.ai_review_record(uuid,uuid,uuid,text,text,text,text)', 'execute')
          and not has_function_privilege('anon', 'public.ai_review_record(uuid,uuid,uuid,text,text,text,text)', 'execute'),
          'recording a recommendation is granted to the service role and nobody else');

set local role service_role;
select throws_ok($$ select public.ai_review_record('3a3a4444-0000-0000-0000-000000000003',
                     '3a3a1111-0000-0000-0000-000000000001', (select id from public.cpd_review_guides limit 1),
                     'x', 'accept', 'by somebody else') $$,
  '42501', null, 'the site cannot record for a person who did not ask');
select throws_ok($$ select public.ai_review_record('3a3a4444-0000-0000-0000-000000000002',
                     '3a3a1111-0000-0000-0000-000000000009', (select (body ->> 'guide_id')::uuid from asked where n = 1),
                     'x', 'maybe', 'unsure') $$,
  '22023', null, 'a recommendation is accept or query and nothing else');

select isnt(public.ai_review_record('3a3a4444-0000-0000-0000-000000000001',
              '3a3a1111-0000-0000-0000-000000000009', (select (body ->> 'guide_id')::uuid from asked where n = 1),
              'claude-test', 'accept', 'All four points are met.', 'should be dropped'), null,
            'the site records Claude''s recommendation');
select isnt(public.ai_review_record('3a3a4444-0000-0000-0000-000000000002',
              '3a3a1111-0000-0000-0000-000000000009', (select (body ->> 'guide_id')::uuid from asked where n = 1),
              'claude-test', 'query', 'Point 3 is missing.', 'Please add how the course changes the way you work.'), null,
            'and a query, with a note to the member');
reset role;

select is((select member_note from public.cpd_ai_reviews where entry_id = '3a3a4444-0000-0000-0000-000000000001'), null,
          'an accept carries no note to the member');
select is((select status::text from public.cpd_entries where id = '3a3a4444-0000-0000-0000-000000000001'), 'pending',
          'AND THE ENTRY IS STILL PENDING: a recommendation decides nothing');
select is((select reviewed_by from public.cpd_entries where id = '3a3a4444-0000-0000-0000-000000000001'), null,
          'and nobody is recorded as having reviewed it');

select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
select is((select ai_recommendation from public.admin_cpd_queue where id = '3a3a4444-0000-0000-0000-000000000001'),
          'accept', 'the office sees the recommendation on the card');
select is((select ai_member_note from public.admin_cpd_queue where id = '3a3a4444-0000-0000-0000-000000000002'),
          'Please add how the course changes the way you work.', 'and the suggested note on a query');
select throws_ok($$ update public.cpd_entries set ai_assisted = true
                     where id = '3a3a4444-0000-0000-0000-000000000003' $$,
  '42501', null, 'staff cannot mark an entry as AI assisted by hand');
reset role;

-- -----------------------------------------------------------------------------
-- 5. A person decides, and the record says AI assisted
-- -----------------------------------------------------------------------------
select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
select is(public.review_cpd(array['3a3a4444-0000-0000-0000-000000000001'::uuid], 'accepted'), 1,
          'the office accepts the recommended entry');
reset role;
select is((select reviewed_by from public.cpd_entries where id = '3a3a4444-0000-0000-0000-000000000001'),
          '3a3a1111-0000-0000-0000-000000000009'::uuid, 'and the PERSON is recorded as the reviewer');
select ok((select ai_assisted and ai_review_id = (select id from public.cpd_ai_reviews
                                                   where entry_id = '3a3a4444-0000-0000-0000-000000000001')
             from public.cpd_entries where id = '3a3a4444-0000-0000-0000-000000000001'),
          'with the entry marked AI assisted, pointing at the recommendation used');

select sign_in_as('3a3a0000-0000-0000-0000-000000000001');
select is((select ai_assisted from public.my_cpd where id = '3a3a4444-0000-0000-0000-000000000001'), true,
          'the member''s own record says so too');
reset role;

select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
select is(public.review_cpd(array['3a3a4444-0000-0000-0000-000000000004'::uuid], 'accepted'), 1,
          'an entry with no recommendation is accepted as before');
reset role;
select is((select ai_assisted from public.cpd_entries where id = '3a3a4444-0000-0000-0000-000000000004'), false,
          'and is not marked AI assisted');

-- -----------------------------------------------------------------------------
-- 6. New words, old recommendation
-- -----------------------------------------------------------------------------
select sign_in_as('3a3a0000-0000-0000-0000-000000000001');
update public.cpd_entries set reflection = words(530) where id = '3a3a4444-0000-0000-0000-000000000002';
reset role;
select is((select ai_recommendation from public.admin_cpd_queue where id = '3a3a4444-0000-0000-0000-000000000002'),
          null, 'when the member rewrites a reflection, the old recommendation no longer shows');

-- Entry three: asked about, then decided by a person while Claude was reading.
select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
select public.review_cpd(array['3a3a4444-0000-0000-0000-000000000003'::uuid], 'accepted');
reset role;
set local role service_role;
select is(public.ai_review_record('3a3a4444-0000-0000-0000-000000000003',
            '3a3a1111-0000-0000-0000-000000000009', (select (body ->> 'guide_id')::uuid from asked where n = 1),
            'claude-test', 'query', 'Too late.'), null,
          'a recommendation arriving after a person has decided is not recorded');
reset role;

-- -----------------------------------------------------------------------------
-- 7. The guide is versioned, not rewritten
-- -----------------------------------------------------------------------------
select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
select throws_ok($$ update public.cpd_review_guides set body = body || ' changed' $$,
  '22023', null, 'a saved guide is not rewritten');
select lives_ok($$ insert into public.cpd_review_guides (body)
                   values (repeat('A second version of the guide. ', 10)) $$,
  'a new version is added instead');
reset role;
select is((select created_by from public.cpd_review_guides order by version desc limit 1),
          '3a3a1111-0000-0000-0000-000000000009'::uuid, 'stamped with who added it');

-- Entry two was rewritten, so it is waiting again; under the new guide.
update public.cpd_entries set ai_requested_at = null, ai_requested_by = null
 where id = '3a3a4444-0000-0000-0000-000000000002';
select sign_in_as('3a3a0000-0000-0000-0000-000000000009');
insert into asked values (3, public.ai_review_begin(50));
reset role;
select is((select (body ->> 'guide_version')::int from asked where n = 3),
          (select max(version) from public.cpd_review_guides), 'the newest guide is the one used');
select ok((select bool_or(i ->> 'id' = '3a3a4444-0000-0000-0000-000000000002')
             from asked, jsonb_array_elements(body -> 'items') i where n = 3),
          'and the rewritten reflection is offered to Claude again');
select ok((select jsonb_array_length(body -> 'items') <= 5 from asked where n = 3),
          'never more than five at a time, however many are asked for');

-- -----------------------------------------------------------------------------
do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 37. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 37 TESTS PASSED' as result;

rollback;
