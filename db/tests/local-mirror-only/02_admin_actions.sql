-- =============================================================================
-- The admin actions, proved rather than asserted.
--
--   psql -d ami -f tests/02_admin_actions.sql
--
-- 01_security.sql proves that nobody can read what they should not. This file
-- proves the other half: that the four things the office actually does work when
-- the right person does them, and fail when anybody else tries.
--
-- Same discipline as 01. Every fixture value is prefixed or uses a .invalid
-- address, so the file runs on an empty database and on a populated one.
-- =============================================================================
create extension if not exists pgtap;

begin;
select plan(30);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;

insert into public.cpd_activity_types (code, name, is_core, sort_order) values
  ('webinar', 'AMI webinar or recorded session', true, 4)
on conflict (code) do nothing;

insert into public.forum_categories (slug, name, sort_order) values
  ('analysis', 'Analysis and air monitoring', 2)
on conflict (slug) do nothing;

insert into auth.users (id, email) values
  ('a1a1a1a1-0000-0000-0000-000000000001', 'ada@test.invalid'),
  ('a2a2a2a2-0000-0000-0000-000000000002', 'olive.office@test.invalid'),
  ('a3a3a3a3-0000-0000-0000-000000000003', 'mo.moderator@test.invalid');

insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('a1a1a1a1-0000-0000-0000-000000000001','a1a1a1a1-0000-0000-0000-000000000001','Ada','Member','ada@test.invalid'),
  ('a2a2a2a2-0000-0000-0000-000000000002','a2a2a2a2-0000-0000-0000-000000000002','Olive','Office','olive.office@test.invalid'),
  ('a3a3a3a3-0000-0000-0000-000000000003','a3a3a3a3-0000-0000-0000-000000000003','Mo','Moderator','mo.moderator@test.invalid');

insert into public.role_grants (person_id, role_code) values
  ('a2a2a2a2-0000-0000-0000-000000000002', 'membership'),
  ('a3a3a3a3-0000-0000-0000-000000000003', 'moderator');

insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'b1b1b1b1-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
       'TEST-A-0001', g.id, date '2020-01-01', true, 'current'
  from public.membership_grades g where g.code = 'member' limit 1;
insert into public.member_preferences (member_id) values ('b1b1b1b1-0000-0000-0000-000000000001');

insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'b3b3b3b3-0000-0000-0000-000000000003', 'a3a3a3a3-0000-0000-0000-000000000003',
       'TEST-A-0003', g.id, date '2020-01-01', true, 'current'
  from public.membership_grades g where g.code = 'member' limit 1;
insert into public.member_preferences (member_id) values ('b3b3b3b3-0000-0000-0000-000000000003');

-- Two applications, so approving one leaves the other to refuse.
insert into public.membership_applications (id, reference, given_name, family_name, email, status, submitted_at, grade_id)
select 'c1c1c1c1-0000-0000-0000-000000000001', 'TEST-APP-A1', 'Nadia', 'Nash',
       'nadia@test.invalid', 'submitted', now(), g.id
  from public.membership_grades g where g.code = 'member' limit 1;
insert into public.membership_applications (id, reference, given_name, family_name, email, status, submitted_at, grade_id)
select 'c2c2c2c2-0000-0000-0000-000000000002', 'TEST-APP-A2', 'Owen', 'Oakes',
       'owen@test.invalid', 'submitted', now(), g.id
  from public.membership_grades g where g.code = 'member' limit 1;

-- Three pending CPD entries for the bulk accept, and one already accepted so the
-- batch has something to skip.
insert into public.cpd_entries (id, member_id, year, occurred_on, activity_type_id, title, points, is_core, how_recorded, status)
select v.id::uuid, 'b1b1b1b1-0000-0000-0000-000000000001', 2026, date '2026-02-01',
       (select t.id from public.cpd_activity_types t where t.code = 'webinar' limit 1),
       v.title, 1.0, true, 'self_declared', 'pending'
  from (values ('d1d1d1d1-0000-0000-0000-000000000001', 'Test entry 1'),
               ('d1d1d1d1-0000-0000-0000-000000000002', 'Test entry 2'),
               ('d1d1d1d1-0000-0000-0000-000000000003', 'Test entry 3')) as v(id, title);

-- An accepted entry has to name its reviewer: the check constraint says a
-- decision is attributed or it did not happen.
insert into public.cpd_entries (id, member_id, year, occurred_on, activity_type_id, title,
                                points, is_core, how_recorded, status, reviewed_by, reviewed_at)
select 'd9d9d9d9-0000-0000-0000-000000000009',
       'b1b1b1b1-0000-0000-0000-000000000001', 2026, date '2026-02-01', t.id,
       'Already accepted', 1.0, true, 'self_declared', 'accepted',
       'a2a2a2a2-0000-0000-0000-000000000002', now()
  from public.cpd_activity_types t where t.code = 'webinar' limit 1;

-- A thread and a held post. The word is inserted for the test and removed at the
-- end of the fixture, so the file does not depend on the real list.
insert into public.banned_words (word, match_type, active)
select 'zzbannedzz', 'whole_word', true
 where not exists (select 1 from public.banned_words where lower(word) = 'zzbannedzz');

insert into public.forum_threads (id, category_id, title, slug, author_id)
select 'e1e1e1e1-0000-0000-0000-000000000001', c.id, 'Test thread', 'test-thread-admin',
       'b1b1b1b1-0000-0000-0000-000000000001'
  from public.forum_categories c where c.slug = 'analysis' limit 1;

insert into public.forum_posts (id, thread_id, author_id, body)
values ('f1f1f1f1-0000-0000-0000-000000000001', 'e1e1e1e1-0000-0000-0000-000000000001',
        'b1b1b1b1-0000-0000-0000-000000000001', 'This post says zzbannedzz and should be held.');

-- -----------------------------------------------------------------------------
-- Helpers, the same two 01 uses
-- -----------------------------------------------------------------------------
create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function try_dml(p_sql text) returns void language plpgsql as $$
begin execute p_sql; end $$;

-- =============================================================================
-- 1. Who am I
-- =============================================================================
select sign_in_as('a2a2a2a2-0000-0000-0000-000000000002');

select is((select person_id from public.whoami()),
          'a2a2a2a2-0000-0000-0000-000000000002'::uuid,
          'whoami names the signed in person, not the account');

select ok((select 'membership' = any (roles) from public.whoami()),
          'whoami reports the roles that person holds');

select is((select member_id from public.whoami()), null,
          'and null for a member id when that person is not a member');
reset role;

-- =============================================================================
-- 2. Approving an application
-- =============================================================================
select sign_in_as('a1a1a1a1-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.approve_application('c1c1c1c1-0000-0000-0000-000000000001', 'TEST-N-0001')$$,
  '42501', null, 'A member cannot approve an application');
reset role;

select sign_in_as('a2a2a2a2-0000-0000-0000-000000000002');
select lives_ok(
  $$select public.approve_application('c1c1c1c1-0000-0000-0000-000000000001', 'TEST-N-0001')$$,
  'Membership staff CAN approve an application');

select is((select status::text from public.membership_applications
            where id = 'c1c1c1c1-0000-0000-0000-000000000001'),
          'approved', 'and the application is marked approved');

select is((select count(*)::int from public.members where membership_number = 'TEST-N-0001'), 1,
          'and a member record exists');

select is((select is_active from public.members where membership_number = 'TEST-N-0001'), false,
          'created INACTIVE, because somebody still presses the switch');

select is((select p.auth_user_id from public.people p
             join public.members m on m.person_id = p.id
            where m.membership_number = 'TEST-N-0001'), null,
          'and with no account, because approving is not creating a login');

select is((select decided_by from public.membership_applications
            where id = 'c1c1c1c1-0000-0000-0000-000000000001'),
          'a2a2a2a2-0000-0000-0000-000000000002'::uuid,
          'The decision is recorded against the person who made it');

-- =============================================================================
-- 3. Refusing an application
-- =============================================================================
select throws_ok(
  $$select public.refuse_application('c2c2c2c2-0000-0000-0000-000000000002', '  ')$$,
  null, null, 'A refusal without a reason is refused');

select lives_ok(
  $$select public.refuse_application('c2c2c2c2-0000-0000-0000-000000000002', 'Insufficient experience.')$$,
  'A refusal with a reason goes through');

select is((select count(*)::int from public.application_events
            where application_id = 'c2c2c2c2-0000-0000-0000-000000000002' and to_status = 'refused'), 1,
          'and it writes an event, so the history is not just the current status');

-- =============================================================================
-- 4. The active switch
-- =============================================================================
select lives_ok(
  $$select public.set_member_active(
      (select id from public.members where membership_number = 'TEST-N-0001'), true)$$,
  'Membership staff CAN switch a new membership on');

-- 0059: staff read who switched it through member_activation(), not the column,
-- which signed in users can no longer read directly.
select is((public.member_activation((select id from public.members where membership_number = 'TEST-N-0001'))
            ->> 'activated_by_id')::uuid,
          'a2a2a2a2-0000-0000-0000-000000000002'::uuid,
          'and the database records who did it, not whatever the browser sent');

select is((select status::text from public.members where membership_number = 'TEST-N-0001'),
          'current', 'and an applicant becomes a current member');

select lives_ok(
  $$select public.set_member_active(
      (select id from public.members where membership_number = 'TEST-N-0001'), false, 'Fee unpaid')$$,
  'and it can be switched off again');

select is((select status::text from public.members where membership_number = 'TEST-N-0001'),
          'lapsed', 'which lapses them rather than deleting anything');
reset role;

select sign_in_as('a1a1a1a1-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_member_active('b1b1b1b1-0000-0000-0000-000000000001', false)$$,
  '42501', null, 'A member cannot switch their own membership');
reset role;

-- =============================================================================
-- 5. CPD review in bulk
-- =============================================================================
select sign_in_as('a1a1a1a1-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.review_cpd(array['d1d1d1d1-0000-0000-0000-000000000001']::uuid[], 'accepted')$$,
  '42501', null, 'A member cannot accept their own CPD');
reset role;

select sign_in_as('a2a2a2a2-0000-0000-0000-000000000002');
select is((select public.review_cpd(array[
             'd1d1d1d1-0000-0000-0000-000000000001',
             'd1d1d1d1-0000-0000-0000-000000000002',
             'd1d1d1d1-0000-0000-0000-000000000003',
             'd9d9d9d9-0000-0000-0000-000000000009']::uuid[], 'accepted')),
          3, 'Bulk accept takes the three pending and skips the one already accepted');

select is((select reviewed_by from public.cpd_entries
            where id = 'd1d1d1d1-0000-0000-0000-000000000001'),
          'a2a2a2a2-0000-0000-0000-000000000002'::uuid,
          'and the reviewer is stamped by the database');

select throws_ok(
  $$select public.review_cpd(array['d1d1d1d1-0000-0000-0000-000000000001']::uuid[], 'rejected')$$,
  null, null, 'A rejection without a reason is refused');
reset role;

-- =============================================================================
-- 6. Held posts
-- =============================================================================
select is((select status::text from public.forum_posts
            where id = 'f1f1f1f1-0000-0000-0000-000000000001'),
          'held', 'The banned word held the post, which is where this starts');

select sign_in_as('a1a1a1a1-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.release_post('f1f1f1f1-0000-0000-0000-000000000001')$$,
  '42501', null, 'The author cannot release their own held post');
reset role;

select sign_in_as('a3a3a3a3-0000-0000-0000-000000000003');
select lives_ok(
  $$select public.release_post('f1f1f1f1-0000-0000-0000-000000000001', 'Quoting a document')$$,
  'A moderator CAN release it');

-- This is the one that would fail silently. The screening trigger fires on
-- update as well as insert, so without the guard in 0020 the filter would hold
-- the post again the instant it was released and the button would look broken.
select is((select status::text from public.forum_posts
            where id = 'f1f1f1f1-0000-0000-0000-000000000001'),
          'published', 'and the filter does not immediately hold it again');
reset role;

-- =============================================================================
-- 7. The grant that made approving possible did not make it general
-- =============================================================================
-- 0020 grants INSERT on members to authenticated, because the policy asking for
-- it had been waiting since 0002. This is the check that keeps that honest.
select sign_in_as('a1a1a1a1-0000-0000-0000-000000000001');
select throws_ok($$insert into public.members
                     (person_id, membership_number, grade_id, joined_on, is_active, status)
                   select 'a1a1a1a1-0000-0000-0000-000000000001', 'TEST-FORGED-0001',
                          g.id, current_date, true, 'current'
                     from public.membership_grades g where g.code = 'member' limit 1$$,
          '42501', null, 'A member still cannot create a membership, grant or no grant');
reset role;

-- =============================================================================
-- 8. The admin queues are not a way round anything
-- =============================================================================
select sign_in_as('a1a1a1a1-0000-0000-0000-000000000001');
select is((select count(*)::int from public.admin_application_queue), 0,
          'A member sees no applications through the admin queue view');
reset role;

set local role anon;
select throws_ok('select * from public.admin_member_list',
                 '42501', null, 'anon holds no grant on the admin queues at all');
reset role;

select * from finish();
rollback;
