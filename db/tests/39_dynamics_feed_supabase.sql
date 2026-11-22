-- =============================================================================
-- 0048, CPD from ARCA's records in Dynamics, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: rows are written only by the sync, into a run that is
-- running; nothing is read until the office has said which column is which;
-- a match is an email held by one current member or a link the office made,
-- shared with Zoom; one event awards once however often it is read; a
-- training course earns nothing until the office says it counts; nothing
-- before 2027 is awarded; a sync never takes points away.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(52);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('zz-dyn', 'ZZ TEST Dynamics grade', 'ZZD', true, false, true, 92)
on conflict (code) do nothing;

insert into auth.users (id, email) values
  ('3d3d0000-0000-0000-0000-000000000001', 'dyn.one@test.invalid'),
  ('3d3d0000-0000-0000-0000-000000000009', 'dyn.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('3d3d1111-0000-0000-0000-000000000001','3d3d0000-0000-0000-0000-000000000001','Dina','One','dyn.one@test.invalid'),
  ('3d3d1111-0000-0000-0000-000000000002', null,'Dan','Two','dyn.two@test.invalid'),
  ('3d3d1111-0000-0000-0000-000000000003', null,'Del','Lapsed','dyn.lapsed@test.invalid'),
  ('3d3d1111-0000-0000-0000-000000000004', null,'Dot','Four','dyn.four@test.invalid'),
  ('3d3d1111-0000-0000-0000-000000000009','3d3d0000-0000-0000-0000-000000000009','Olga','Office','dyn.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('3d3d1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', v.act, v.st::public.member_status
  from (values
    ('3d3d2222-0000-0000-0000-000000000001','3d3d1111-0000-0000-0000-000000000001','TEST-D-0001', true,  'current'),
    ('3d3d2222-0000-0000-0000-000000000002','3d3d1111-0000-0000-0000-000000000002','TEST-D-0002', true,  'current'),
    ('3d3d2222-0000-0000-0000-000000000003','3d3d1111-0000-0000-0000-000000000003','TEST-D-0003', false, 'lapsed'),
    ('3d3d2222-0000-0000-0000-000000000004','3d3d1111-0000-0000-0000-000000000004','TEST-D-0004', true,  'current')
  ) v(mid, pid, num, act, st)
  join public.membership_grades g on g.code = 'zz-dyn';

update public.system_settings set value = '2027-01-01' where key = 'cpd_feeds_from';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- The rows as Dynamics gives them: lookups as ids with the words beside them,
-- a linked contact's email under its alias, dates and times in UTC.
create temporary table rows_in (feed text, j jsonb) on commit drop;
insert into rows_in values
  ('regional_meetings', '{"_ami_id":"r1","c.emailaddress1":"Dyn.One@Test.Invalid ","c.fullname":"Dina One",
     "_arca_meetingid_value":"9f0e-guid","_arca_meetingid_value@OData.Community.Display.V1.FormattedValue":"North West regional meeting",
     "arca_date":"2027-03-31T23:30:00Z"}'),
  ('regional_meetings', '{"_ami_id":"r2","c.emailaddress1":"stranger@test.invalid","c.fullname":"Dot Four",
     "_arca_meetingid_value":"9f0e-guid","_arca_meetingid_value@OData.Community.Display.V1.FormattedValue":"North West regional meeting",
     "arca_date":"2027-03-31T23:30:00Z"}'),
  ('regional_meetings', '{"_ami_id":"r3","c.emailaddress1":"dyn.lapsed@test.invalid","c.fullname":"Del Lapsed",
     "_arca_meetingid_value@OData.Community.Display.V1.FormattedValue":"North West regional meeting","arca_date":"2027-03-31T23:30:00Z"}'),
  ('regional_meetings', '{"_ami_id":"r4","c.emailaddress1":null,"c.fullname":"Dan Two",
     "_arca_meetingid_value@OData.Community.Display.V1.FormattedValue":"North West regional meeting","arca_date":"2027-03-31T23:30:00Z"}'),
  ('regional_meetings', '{"_ami_id":"r5","c.emailaddress1":"dyn.two@test.invalid",
     "_arca_meetingid_value@OData.Community.Display.V1.FormattedValue":"Scotland regional meeting","arca_date":"2026-11-12"}'),
  ('regional_meetings', '{"c.emailaddress1":"dyn.two@test.invalid",
     "_arca_meetingid_value@OData.Community.Display.V1.FormattedValue":"No id meeting","arca_date":"2027-02-02"}'),
  ('regional_meetings', '{"_ami_id":"r7","c.emailaddress1":"dyn.two@test.invalid",
     "_arca_meetingid_value@OData.Community.Display.V1.FormattedValue":"Bad date meeting","arca_date":"not a date"}');
grant select on rows_in to service_role;

-- -----------------------------------------------------------------------------
-- 1. Who may do what
-- -----------------------------------------------------------------------------
select is((select count(*)::int from public.dynamics_feeds where code <> 'ami_members'), 3, 'the three attendance feeds are there, one per view (0054 adds the members feed)');
select is((select view_name from public.dynamics_feeds where code = 'arca_training'), 'AMI Sync: Training completions',
          'each named for the view the Dynamics admin creates');

select sign_in_as('3d3d0000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.dynamics_feeds), 0, 'a member cannot see the feeds');
select throws_ok($$ select public.dynamics_sync_request() $$, '42501', null, 'or ask for a sync');
select throws_ok($$ select public.dynamics_run_begin() $$, '42501', null, 'or begin one');
select throws_ok($$ select public.dynamics_record(gen_random_uuid(), 'arca_agm', '{}', '[]') $$,
  '42501', null, 'or write a row');
reset role;
set local role anon;
select throws_ok($$ select public.dynamics_record(gen_random_uuid(), 'arca_agm', '{}', '[]') $$,
  '42501', null, 'and nor can anybody signed out');
reset role;

-- -----------------------------------------------------------------------------
-- 2. Nothing is read until the columns are named
-- -----------------------------------------------------------------------------
set local role service_role;
create temporary table run1 (j jsonb) on commit drop;
grant all on run1 to service_role;
insert into run1 select public.dynamics_run_begin();
select ok((select (j ->> 'run') is not null and jsonb_array_length(j -> 'feeds') = 4 from run1),
          'a scheduled run begins, and is told which views to read');
select is((public.dynamics_run_begin() ->> 'skip'), 'A sync is running already.',
          'a second cannot begin on top of it');
select is((public.dynamics_record((select (j ->> 'run')::uuid from run1), 'regional_meetings',
             '{"entity":"arca_meetingattendance","fields":["c.emailaddress1","arca_date","bad name!"]}',
             (select jsonb_agg(j) from rows_in)) ->> 'ready'), 'false',
          'with no columns named the rows are not used');
reset role;
select is((select count(*)::int from public.dynamics_attendance), 0, 'and nothing is stored');
select is((select seen_fields from public.dynamics_feeds where code = 'regional_meetings'),
          '["arca_date", "c.emailaddress1"]'::jsonb,
          'but the column names it found are kept for the office, and only names');

-- The office names them.
create temporary table feeds_audit as select count(*)::int as n from public.audit_log where table_name = 'dynamics_feeds';
select sign_in_as('3d3d0000-0000-0000-0000-000000000009');
select lives_ok($$ update public.dynamics_feeds
                      set email_field = 'c.emailaddress1', name_field = 'c.fullname',
                          event_field = '_arca_meetingid_value', date_field = 'arca_date'
                    where code = 'regional_meetings' $$,
  'membership staff name the columns');
select throws_ok($$ update public.dynamics_feeds set email_field = 'x; drop table people' where code = 'arca_agm' $$,
  '22023', null, 'and a column name has to be a column name');
select throws_ok($$ update public.dynamics_feeds set activity_code = 'ami_seminar' where code = 'arca_agm' $$,
  '42501', null, 'which activity a feed earns is not theirs to change');
select throws_ok($$ update public.dynamics_feeds set seen_fields = '[]' where code = 'arca_agm' $$,
  '42501', null, 'nor what the sync saw');
update public.dynamics_feeds set email_field = 'c.emailaddress1', date_field = 'arca_date' where code = 'arca_agm';
update public.dynamics_feeds set email_field = 'c.emailaddress1', event_field = 'arca_course', date_field = 'arca_completed'
 where code = 'arca_training';
reset role;
select is((select count(*)::int from public.audit_log where table_name = 'dynamics_feeds') - (select n from feeds_audit), 3,
          'each change the office made is in the audit log, and what the run saw is not');

-- -----------------------------------------------------------------------------
-- 3. Reading the rows
-- -----------------------------------------------------------------------------
set local role service_role;
create temporary table got (j jsonb) on commit drop;
grant all on got to service_role;
insert into got select public.dynamics_record((select (j ->> 'run')::uuid from run1), 'regional_meetings',
  '{"entity":"x","fields":[]}', (select jsonb_agg(j) from rows_in where feed = 'regional_meetings'));
reset role;
select is((select (j ->> 'read')::int from got), 7, 'every row is read: ' || (select j::text from got));
select is((select (j ->> 'unreadable')::int from got), 2, 'a row with no id or no usable date is counted and left');

select is((select outcome from public.dynamics_attendance where dynamics_id = 'r1'), 'awarded',
          'an address held by one current member is matched, and awarded');
select is((select count(*)::int from public.cpd_entries
            where member_id = '3d3d2222-0000-0000-0000-000000000001' and how_recorded = 'automatic'
              and status = 'accepted' and points = 1), 1, 'one point, accepted, on their record');
select is((select title from public.dynamics_sessions where feed = 'regional_meetings' and held_on = date '2027-04-01'),
          'North West regional meeting', 'the meeting''s name, not its id; on the London date, not the UTC one');
select is((select count(*)::int from public.email_outbox where to_email = 'dyn.one@test.invalid' and template_code = 'cpd_awarded'), 1,
          'with the same receipt every automatic award sends');
select is((select outcome from public.dynamics_attendance where dynamics_id = 'r2'), 'unmatched',
          'an address nobody holds waits to be matched');
select is((select outcome from public.dynamics_attendance where dynamics_id = 'r3'), 'not_current',
          'an address on a lapsed membership is said so, and earns nothing');
select is((select outcome from public.dynamics_attendance where dynamics_id = 'r4'), 'no_email',
          'a row with no email waits too');
select is((select outcome from public.dynamics_attendance where dynamics_id = 'r5'), 'before_scheme',
          'a meeting before 2027 is recorded and awards nothing');
select is((select raw ->> 'c.fullname' from public.dynamics_attendance where dynamics_id = 'r1'), 'Dina One',
          'the row is kept exactly as Dynamics gave it');

-- Read again, as every run does.
create temporary table audit_before as select count(*)::int as n from public.audit_log where table_name = 'dynamics_attendance';
set local role service_role;
select public.dynamics_record((select (j ->> 'run')::uuid from run1), 'regional_meetings',
  '{"entity":"x","fields":[]}', (select jsonb_agg(j) from rows_in where feed = 'regional_meetings'));
reset role;
select is((select count(*)::int from public.cpd_entries where member_id = '3d3d2222-0000-0000-0000-000000000001'), 1,
          'reading the same rows again awards nobody twice');
select is((select count(*)::int from public.audit_log where table_name = 'dynamics_attendance'), (select n from audit_before),
          'and writes nothing to the audit log, because nothing changed');

-- A row that disappears from the view takes nothing away.
set local role service_role;
select public.dynamics_record((select (j ->> 'run')::uuid from run1), 'regional_meetings', '{"entity":"x","fields":[]}', '[]');
reset role;
select is((select status::text from public.cpd_entries where member_id = '3d3d2222-0000-0000-0000-000000000001'), 'accepted',
          'a row gone from the view leaves its points where they are');

-- -----------------------------------------------------------------------------
-- 4. One People to match queue for both feeds
-- -----------------------------------------------------------------------------
select is((select source from public.admin_cpd_feed_queue where id = (select id from public.dynamics_attendance where dynamics_id = 'r2')),
          'ARCA records', 'ARCA''s rows are in the same queue as Zoom''s, said to be from ARCA''s records');
select sign_in_as('3d3d0000-0000-0000-0000-000000000009');
select is(public.feed_link((select id from public.dynamics_attendance where dynamics_id = 'r2'), 'test-d-0004'), 'awarded',
          'the office links the stranger by membership number and the point follows');
select is((select member_id from public.cpd_feed_links where email = 'stranger@test.invalid'),
          '3d3d2222-0000-0000-0000-000000000004'::uuid, 'and the address is remembered');
select is(public.feed_link((select id from public.dynamics_attendance where dynamics_id = 'r4'), 'TEST-D-0002'), 'awarded',
          'a row with no email is linked for that meeting only');
select is((select count(*)::int from public.cpd_feed_links where member_id = '3d3d2222-0000-0000-0000-000000000002'), 0,
          'and nothing is remembered for it');
reset role;

-- An address linked once is linked for every feed: Zoom's queue settles it too.
insert into public.zoom_sessions (id, title, kind, zoom_id, held_on, activity_type_id, event_key)
select '3d3d3333-0000-0000-0000-000000000001', 'ZZ TEST Dynamics seminar', 'webinar', '81234567899', date '2027-04-08',
       id, 'zz-test-dyn-seminar' from public.cpd_activity_types where code = 'ami_seminar';
insert into public.zoom_attendance (session_id, identity, email, name, minutes, percent)
values ('3d3d3333-0000-0000-0000-000000000001', 'guest@test.invalid', 'guest@test.invalid', 'Gus Guest', 60, 100);
set local role service_role;
select public.dynamics_record((select (j ->> 'run')::uuid from run1), 'regional_meetings', '{"entity":"x","fields":[]}',
  '[{"_ami_id":"r8","c.emailaddress1":"guest@test.invalid","c.fullname":"Dina One","_arca_meetingid_value":"Midlands regional meeting","arca_date":"2027-05-05"}]');
reset role;
select sign_in_as('3d3d0000-0000-0000-0000-000000000009');
select is(public.feed_dismiss((select id from public.dynamics_attendance where dynamics_id = 'r8')), 'not_member',
          'the office says a guest is not a member');
select is((select outcome from public.zoom_attendance where identity = 'guest@test.invalid'), 'not_member',
          'and the same guest waiting from Zoom is settled in the same breath');
select throws_ok($$ select public.feed_dismiss((select id from public.dynamics_attendance where dynamics_id = 'r1')) $$,
  '22023', null, 'an awarded row cannot be dismissed');
reset role;

-- -----------------------------------------------------------------------------
-- 5. Training: a course counts once the office says so
-- -----------------------------------------------------------------------------
set local role service_role;
create temporary table tr (j jsonb) on commit drop;
grant all on tr to service_role;
insert into tr select public.dynamics_record((select (j ->> 'run')::uuid from run1), 'arca_training', '{"entity":"x","fields":[]}',
  '[{"_ami_id":"t1","c.emailaddress1":"dyn.one@test.invalid","arca_course":"Asbestos  Supervisor refresher","arca_completed":"2027-02-10"},
    {"_ami_id":"t2","c.emailaddress1":"dyn.four@test.invalid","arca_course":"asbestos supervisor refresher","arca_completed":"2027-02-10"}]');
reset role;
select is((select outcome from public.dynamics_attendance where dynamics_id = 't1'), 'course_waiting',
          'a completion of a course nobody has decided on waits');
select is((select count(*)::int from public.dynamics_courses), 1,
          'the same course written two ways is one course');
select sign_in_as('3d3d0000-0000-0000-0000-000000000009');
select ok((public.dynamics_course_decide((select id from public.dynamics_courses), true) ->> 'awarded')::int = 2,
          'the office says it counts, and both completions are awarded at once');
select is((select is_core from public.cpd_entries e join public.dynamics_attendance a on a.entry_id = e.id where a.dynamics_id = 't1'),
          true, 'as core points, the activity''s');
select throws_ok($$ select public.dynamics_course_decide((select id from public.dynamics_courses), false) $$,
  '22023', null, 'once awarded, the course cannot be quietly switched off');
reset role;
select sign_in_as('3d3d0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.dynamics_course_decide((select id from public.dynamics_courses), true) $$,
  '42501', null, 'and a member cannot decide one');
reset role;

-- -----------------------------------------------------------------------------
-- 6. The ARCA AGM, and the monthly email
-- -----------------------------------------------------------------------------
set local role service_role;
select public.dynamics_record((select (j ->> 'run')::uuid from run1), 'arca_agm', '{"entity":"x","fields":[]}',
  '[{"_ami_id":"a1","c.emailaddress1":"dyn.two@test.invalid","arca_date":"2027-06-17T09:00:00Z"}]');
reset role;
select is((select event_key from public.dynamics_sessions where feed = 'arca_agm'), 'arca-agm-2027-06-17',
          'the AGM is one event a day, with a key a recording can share');
select is((select count(*)::int from public.cpd_feed_sessions where source = 'dynamics' and activity_code = 'regional_meeting_2027'), 3,
          'ARCA''s regional meetings are in what the monthly email lists as missed');
select is((select count(*)::int from public.cpd_feed_sessions where activity_code = 'arca_training'), 0,
          'a training course is not, being somebody''s own');

-- -----------------------------------------------------------------------------
-- 7. Runs: finished, and asked for
-- -----------------------------------------------------------------------------
set local role service_role;
select public.dynamics_run_finish((select (j ->> 'run')::uuid from run1), '{"ok":true}');
select throws_ok($$ select public.dynamics_record((select (j ->> 'run')::uuid from run1), 'arca_agm', '{}', '[]') $$,
  '42501', null, 'a finished run takes no more rows');
select throws_ok($$ select public.dynamics_run_begin(gen_random_uuid()) $$,
  '42501', null, 'a run nobody asked for is refused');
reset role;
select is((select status from public.dynamics_runs where id = (select (j ->> 'run')::uuid from run1)), 'ok',
          'and is marked as having gone well');

select sign_in_as('3d3d0000-0000-0000-0000-000000000009');
create temporary table req (id uuid) on commit drop;
insert into req select public.dynamics_sync_request();
reset role;
grant all on req to service_role;
set local role service_role;
select ok((public.dynamics_run_begin((select id from req)) ->> 'run')::uuid = (select id from req),
          'the office presses Sync now and that run begins');
reset role;
select is((select requested_by from public.dynamics_runs where id = (select id from req)),
          '3d3d1111-0000-0000-0000-000000000009'::uuid, 'and it says who asked');
select sign_in_as('3d3d0000-0000-0000-0000-000000000009');
select throws_ok($$ select public.dynamics_sync_request() $$, '22023', null,
  'pressing it again while it runs is refused');
reset role;
update public.dynamics_runs set started_at = now() - interval '25 minutes' where id = (select id from req);
set local role service_role;
select ok((public.dynamics_run_begin() ->> 'run') is not null, 'a run that never finished does not block the next');
reset role;
select is((select status from public.dynamics_runs where id = (select id from req)), 'failed',
          'and is marked as having stopped');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 52. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 52 TESTS PASSED' as result;

rollback;
