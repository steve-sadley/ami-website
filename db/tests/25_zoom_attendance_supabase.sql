-- =============================================================================
-- 0042, Zoom attendance, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: attendance is written only from a report the Worker was asked
-- for; rejoins are put together and two devices are not counted twice; 75% of
-- the session earns the points and less does not; a match is an email held by
-- exactly one current member and never a display name; one event awards once,
-- however often it is imported; the office links an address once and it is
-- remembered; nothing before the scheme starts awards anything.
--
-- Every fixture value is prefixed or uses a .invalid address. A person's id and
-- their login id differ on purpose.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(46);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;
insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select y, g.id, 5, 5 from public.membership_grades g,
       (values (extract(year from current_date)::int), (extract(year from current_date - 40)::int)) v(y)
 where g.code = 'member'
on conflict (year, grade_id) do nothing;

insert into auth.users (id, email) values
  ('2e2e0000-0000-0000-0000-000000000001', 'zoom.one@test.invalid'),
  ('2e2e0000-0000-0000-0000-000000000002', 'zoom.two@test.invalid'),
  ('2e2e0000-0000-0000-0000-000000000003', 'zoom.short@test.invalid'),
  ('2e2e0000-0000-0000-0000-000000000004', 'zoom.four@test.invalid'),
  ('2e2e0000-0000-0000-0000-000000000009', 'zoom.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('2e2e1111-0000-0000-0000-000000000001','2e2e0000-0000-0000-0000-000000000001','Zoe','One','zoom.one@test.invalid'),
  ('2e2e1111-0000-0000-0000-000000000002','2e2e0000-0000-0000-0000-000000000002','Zak','Two','zoom.two@test.invalid'),
  ('2e2e1111-0000-0000-0000-000000000003','2e2e0000-0000-0000-0000-000000000003','Zia','Short','zoom.short@test.invalid'),
  ('2e2e1111-0000-0000-0000-000000000004','2e2e0000-0000-0000-0000-000000000004','Zed','Four','zoom.four@test.invalid'),
  ('2e2e1111-0000-0000-0000-000000000005', null,'Zara','Lapsed','zoom.lapsed@test.invalid'),
  ('2e2e1111-0000-0000-0000-000000000009','2e2e0000-0000-0000-0000-000000000009','Olive','Office','zoom.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('2e2e1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', v.act, v.st::public.member_status
  from (values
    ('2e2e2222-0000-0000-0000-000000000001','2e2e1111-0000-0000-0000-000000000001','TEST-Z-0001', true,  'current'),
    ('2e2e2222-0000-0000-0000-000000000002','2e2e1111-0000-0000-0000-000000000002','TEST-Z-0002', true,  'current'),
    ('2e2e2222-0000-0000-0000-000000000003','2e2e1111-0000-0000-0000-000000000003','TEST-Z-0003', true,  'current'),
    ('2e2e2222-0000-0000-0000-000000000004','2e2e1111-0000-0000-0000-000000000004','TEST-Z-0004', true,  'current'),
    ('2e2e2222-0000-0000-0000-000000000005','2e2e1111-0000-0000-0000-000000000005','TEST-Z-0005', false, 'lapsed')
  ) as v(mid, pid, num, act, st), public.membership_grades g where g.code = 'member';
insert into public.member_preferences (member_id)
select id from public.members where membership_number like 'TEST-Z-%';

-- The scheme starts in 2027. These sessions are held last week, so for most of
-- this file the start is moved back, inside this transaction only.
update public.system_settings set value = '2020-01-01' where key = 'cpd_feeds_from';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function type_id(c text) returns uuid language sql as $$
  select id from public.cpd_activity_types where code = c $$;
create or replace function at(hhmm text) returns text language sql as $$
  select to_char(current_date - 7, 'YYYY-MM-DD') || 'T' || hhmm || ':00Z' $$;
create or replace function line(email text, nm text, j text, l text, st text default 'in_meeting')
returns jsonb language sql as $$
  select jsonb_build_object('user_email', coalesce(email, ''), 'name', nm,
                            'join_time', at(j), 'leave_time', at(l), 'status', st) $$;
create or replace function outcome_of(sess uuid, ident text) returns text language sql as $$
  select outcome from public.zoom_attendance where session_id = sess and identity = ident $$;

-- A session from 10:00 to 11:00, sixty minutes, so 75% is 45 minutes.
create or replace function report_one() returns jsonb language sql as $$
  select jsonb_build_object('uuid', 'zz-test-uuid-1', 'topic', 'ZZ TEST seminar',
    'start_time', at('10:00'), 'end_time', at('11:00'),
    'participants', jsonb_build_array(
      line('zoom.one@test.invalid', 'Zoe One', '09:50', '10:00', 'in_waiting_room'),
      line('zoom.one@test.invalid', 'Zoe One', '10:00', '10:30'),
      line('ZOOM.One@test.invalid', 'Zoe One', '10:35', '11:00'),        -- rejoined, capitals
      line('zoom.two@test.invalid', 'Zak laptop', '10:00', '10:50'),
      line('zoom.two@test.invalid', 'Zak phone',  '10:00', '10:50'),     -- two devices at once
      line('zoom.short@test.invalid', 'Zia Short', '10:00', '10:30'),    -- half
      line('zoom.lapsed@test.invalid', 'Zara Lapsed', '10:00', '11:00'),
      line('guest@test.invalid', 'A Guest', '10:00', '11:00'),            -- not a member
      line('stranger@test.invalid', 'A Stranger', '09:30', '10:55'),     -- joined before the start
      line(null, 'iPhone', '10:00', '11:00'))) $$;

-- -----------------------------------------------------------------------------
-- 1. The office writes the session down
-- -----------------------------------------------------------------------------
select sign_in_as('2e2e0000-0000-0000-0000-000000000009');

select lives_ok($$
  insert into public.zoom_sessions (id, title, kind, zoom_id, held_on, activity_type_id, points)
  values ('2e2e3333-0000-0000-0000-000000000001', 'ZZ TEST seminar', 'meeting', '812 3456 7890',
          current_date - 7, type_id('ami_seminar'), 1) $$,
  'membership staff write a session down');
select is((select zoom_id from public.zoom_sessions where id = '2e2e3333-0000-0000-0000-000000000001'),
          '81234567890', 'the number is kept as digits, however it was pasted');
select is((select points from public.zoom_sessions where id = '2e2e3333-0000-0000-0000-000000000001'),
          3.0::numeric, 'and it is worth what a seminar is worth, whatever was typed');
select is((select event_key from public.zoom_sessions where id = '2e2e3333-0000-0000-0000-000000000001'),
          'ami-seminar-' || to_char(current_date - 7, 'YYYY-MM-DD'),
          'the event key is filled in from the activity and the date');
select throws_ok($$
  insert into public.zoom_sessions (title, zoom_id, held_on, activity_type_id)
  values ('ZZ TEST bad number', '12345', current_date, type_id('ami_seminar')) $$,
  '22023', null, 'a number that is not a Zoom number is refused');

select lives_ok($$
  insert into public.zoom_sessions (id, title, zoom_id, held_on, activity_type_id)
  values ('2e2e3333-0000-0000-0000-000000000009', 'ZZ TEST next month', '99988877766',
          current_date + 30, type_id('ami_seminar')) $$, 'a session can be written down in advance');
select throws_ok($$ select public.zoom_import_begin('2e2e3333-0000-0000-0000-000000000009') $$,
  '22023', null, 'but its attendance cannot be read before it has happened');
reset role;

-- -----------------------------------------------------------------------------
-- 2. Nobody else can touch it
-- -----------------------------------------------------------------------------
select sign_in_as('2e2e0000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.zoom_sessions), 0, 'a member sees no sessions');
select throws_ok($$
  insert into public.zoom_sessions (title, zoom_id, held_on, activity_type_id)
  values ('ZZ TEST by a member', '81234567891', current_date - 1, type_id('ami_seminar')) $$,
  '42501', null, 'and cannot write one');
select throws_ok($$ select public.zoom_import_begin('2e2e3333-0000-0000-0000-000000000001') $$,
  '42501', null, 'or begin an import');
select throws_ok($$ select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000001',
                     '{"participants":[]}', '2e2e1111-0000-0000-0000-000000000001') $$,
  '42501', null, 'or write attendance');
select throws_ok($$ select public.feed_link(gen_random_uuid(), 'TEST-Z-0001') $$,
  '42501', null, 'or link anybody');
reset role;

select sign_in_as('2e2e0000-0000-0000-0000-000000000009');
select throws_ok($$ select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000001',
                     '{"participants":[]}', '2e2e1111-0000-0000-0000-000000000009') $$,
  '42501', null, 'membership staff cannot write attendance either: it comes from Zoom');
-- The real test of the grant. A member of staff who has begun an import is the
-- one person the function's own check would let through, so only the grant
-- stands between their browser console and a report they made up.
select public.zoom_import_begin('2e2e3333-0000-0000-0000-000000000001');
select throws_ok($$ select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000001',
                     report_one(), '2e2e1111-0000-0000-0000-000000000009') $$,
  '42501', null, 'not even straight after beginning an import themselves');
reset role;
select ok(not has_function_privilege('authenticated', 'public.zoom_record_attendance(uuid,jsonb,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.zoom_record_attendance(uuid,jsonb,uuid)', 'execute'),
          'recording attendance is granted to the service role and nobody else');
update public.zoom_sessions set import_requested_by = null, import_requested_at = null
 where id = '2e2e3333-0000-0000-0000-000000000001';

set local role service_role;
select throws_ok($$ select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000001',
                     report_one(), '2e2e1111-0000-0000-0000-000000000009') $$,
  '42501', null, 'the Worker cannot record a session nobody on the staff asked for');
reset role;

-- -----------------------------------------------------------------------------
-- 3. Reading the report
-- -----------------------------------------------------------------------------
select sign_in_as('2e2e0000-0000-0000-0000-000000000009');
select is((public.zoom_import_begin('2e2e3333-0000-0000-0000-000000000001') ->> 'zoom_id'),
          '81234567890', 'staff begin an import and the Worker is told which meeting');
reset role;

set local role service_role;
select lives_ok($$ select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000001',
                    report_one(), '2e2e1111-0000-0000-0000-000000000009') $$,
  'and the Worker records what Zoom said');
reset role;

select is((select minutes from public.zoom_attendance
            where session_id = '2e2e3333-0000-0000-0000-000000000001' and identity = 'zoom.one@test.invalid'),
          55, 'somebody who left and rejoined has both stretches put together, 30 and 25');
select is((select count(*)::int from public.zoom_attendance
            where session_id = '2e2e3333-0000-0000-0000-000000000001' and identity = 'zoom.one@test.invalid'),
          1, 'and is one person whatever the capitals in their address');
select is((select minutes from public.zoom_attendance
            where session_id = '2e2e3333-0000-0000-0000-000000000001' and identity = 'zoom.two@test.invalid'),
          50, 'two devices over the same 50 minutes count 50, not 100');
select is((select minutes from public.zoom_attendance
            where session_id = '2e2e3333-0000-0000-0000-000000000001' and identity = 'stranger@test.invalid'),
          55, 'time before the session started does not count');

select is(outcome_of('2e2e3333-0000-0000-0000-000000000001', 'zoom.one@test.invalid'), 'awarded',
          '91% earns the points');
select is(outcome_of('2e2e3333-0000-0000-0000-000000000001', 'zoom.two@test.invalid'), 'awarded',
          '83% earns them too');
select is(outcome_of('2e2e3333-0000-0000-0000-000000000001', 'zoom.short@test.invalid'), 'too_short',
          '50% does not');
select is(outcome_of('2e2e3333-0000-0000-0000-000000000001', 'zoom.lapsed@test.invalid'), 'not_current',
          'a lapsed member is recognised and not awarded');
select is(outcome_of('2e2e3333-0000-0000-0000-000000000001', 'stranger@test.invalid'), 'unmatched',
          'an address nobody holds waits for the office');
select is(outcome_of('2e2e3333-0000-0000-0000-000000000001', 'name:iphone'), 'no_email',
          'a display name is never matched to anybody');

select is((select count(*)::int from public.cpd_entries
            where event_key = 'ami-seminar-' || to_char(current_date - 7, 'YYYY-MM-DD')
              and how_recorded = 'automatic' and status = 'accepted' and points = 3 and is_core),
          2, 'two automatic entries, three core points each');
select is((select count(*)::int from public.email_outbox
            where template_code = 'cpd_awarded' and to_email in ('zoom.one@test.invalid', 'zoom.two@test.invalid')),
          2, 'and a receipt to each');
select is((select (last_result ->> 'awarded')::int from public.zoom_sessions
            where id = '2e2e3333-0000-0000-0000-000000000001'), 2,
          'the session says what happened, for the office');

-- -----------------------------------------------------------------------------
-- 4. Importing again changes nothing
-- -----------------------------------------------------------------------------
select sign_in_as('2e2e0000-0000-0000-0000-000000000009');
select public.zoom_import_begin('2e2e3333-0000-0000-0000-000000000001');
reset role;
set local role service_role;
select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000001', report_one(),
                                     '2e2e1111-0000-0000-0000-000000000009');
reset role;
select is((select count(*)::int from public.cpd_entries
            where event_key = 'ami-seminar-' || to_char(current_date - 7, 'YYYY-MM-DD')),
          2, 'a second import of the same session awards nobody twice');
select is((select count(*)::int from public.email_outbox
            where template_code = 'cpd_awarded' and to_email in ('zoom.one@test.invalid', 'zoom.two@test.invalid')),
          2, 'and sends nobody a second receipt');
select is(outcome_of('2e2e3333-0000-0000-0000-000000000001', 'zoom.one@test.invalid'), 'awarded',
          'and still says awarded rather than already counted');
select is((app.award_cpd('2e2e2222-0000-0000-0000-000000000001', type_id('ami_seminar'), 3, 'recording',
                         current_date, gen_random_uuid(), gen_random_uuid(),
                         'ami-seminar-' || to_char(current_date - 7, 'YYYY-MM-DD'))), null,
          'the recording of the same seminar, sharing its key, awards nothing more');

-- -----------------------------------------------------------------------------
-- 5. The office settles the queue
-- -----------------------------------------------------------------------------
select sign_in_as('2e2e0000-0000-0000-0000-000000000009');
select throws_ok($$ select public.feed_link((select id from public.zoom_attendance
                     where identity = 'stranger@test.invalid'), 'TEST-NOBODY') $$,
  '22023', null, 'a membership number nobody holds is refused');
select is(public.feed_link((select id from public.zoom_attendance where identity = 'stranger@test.invalid'),
                           'test-z-0004'), 'awarded',
          'linking the stranger''s address to member four awards them at once');
select is((select member_id from public.cpd_feed_links where email = 'stranger@test.invalid'),
          '2e2e2222-0000-0000-0000-000000000004'::uuid, 'and the link is remembered');
select is(public.feed_link((select id from public.zoom_attendance where identity = 'name:iphone'),
                           'TEST-Z-0003'), 'awarded',
          'a display name can be linked by the office, for this session');
select is((select count(*)::int from public.cpd_feed_links where email like 'name:%'), 0,
          'but a display name is never remembered');
select throws_ok($$ select public.feed_dismiss((select id from public.zoom_attendance
                     where identity = 'zoom.one@test.invalid')) $$,
  '22023', null, 'an awarded row cannot be dismissed: the entry is rejected in CPD to review instead');
select is(public.feed_dismiss((select id from public.zoom_attendance where identity = 'guest@test.invalid')),
          'not_member', 'the office can say an address is not a member');
select is((select count(*)::int from public.admin_cpd_feed_queue
            where session_id = '2e2e3333-0000-0000-0000-000000000001'), 7,
          'staff read every row of the session through the queue view');

-- A second session: the remembered link and the dismissal both apply on their own.
insert into public.zoom_sessions (id, title, kind, zoom_id, held_on, activity_type_id, event_key)
values ('2e2e3333-0000-0000-0000-000000000002', 'ZZ TEST second seminar', 'webinar', '81234567892',
        current_date - 6, type_id('ami_seminar'), 'zz-test-second');
select public.zoom_import_begin('2e2e3333-0000-0000-0000-000000000002');
reset role;
set local role service_role;
select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000002',
  jsonb_build_object('start_time', at('10:00'), 'end_time', at('11:00'), 'participants', jsonb_build_array(
    line('stranger@test.invalid', 'A Stranger', '10:00', '11:00'),
    line('guest@test.invalid', 'A Guest', '10:00', '11:00'))),
  '2e2e1111-0000-0000-0000-000000000009');
reset role;
select is(outcome_of('2e2e3333-0000-0000-0000-000000000002', 'stranger@test.invalid'), 'awarded',
          'next time the linked address is matched without asking');
select is(outcome_of('2e2e3333-0000-0000-0000-000000000002', 'guest@test.invalid'), 'not_member',
          'and the dismissed one is not asked about again');

-- -----------------------------------------------------------------------------
-- 6. What is fixed, and what is stale
-- -----------------------------------------------------------------------------
select sign_in_as('2e2e0000-0000-0000-0000-000000000009');
select throws_ok($$ update public.zoom_sessions set activity_type_id = type_id('ami_agm')
                     where id = '2e2e3333-0000-0000-0000-000000000001' $$,
  '22023', null, 'once attendance is read, what the session counts as is fixed');
reset role;

update public.zoom_sessions set import_requested_by = '2e2e1111-0000-0000-0000-000000000009',
       import_requested_at = now() - interval '11 minutes'
 where id = '2e2e3333-0000-0000-0000-000000000002';
set local role service_role;
select throws_ok($$ select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000002',
                     '{"participants":[]}', '2e2e1111-0000-0000-0000-000000000009') $$,
  '42501', null, 'an import begun more than ten minutes ago is not accepted');
reset role;

-- -----------------------------------------------------------------------------
-- 7. Nothing before the scheme starts
-- -----------------------------------------------------------------------------
update public.system_settings set value = '2027-01-01' where key = 'cpd_feeds_from';
select sign_in_as('2e2e0000-0000-0000-0000-000000000009');
insert into public.zoom_sessions (id, title, zoom_id, held_on, activity_type_id, event_key)
values ('2e2e3333-0000-0000-0000-000000000003', 'ZZ TEST before the scheme', '81234567893',
        date '2026-10-01', type_id('ami_seminar'), 'zz-test-before');
select public.zoom_import_begin('2e2e3333-0000-0000-0000-000000000003');
reset role;
set local role service_role;
select public.zoom_record_attendance('2e2e3333-0000-0000-0000-000000000003',
  jsonb_build_object('start_time', '2026-10-01T10:00:00Z', 'end_time', '2026-10-01T11:00:00Z',
    'participants', jsonb_build_array(jsonb_build_object('user_email', 'zoom.four@test.invalid',
      'name', 'Zed', 'join_time', '2026-10-01T10:00:00Z', 'leave_time', '2026-10-01T11:00:00Z'))),
  '2e2e1111-0000-0000-0000-000000000009');
reset role;
select is(outcome_of('2e2e3333-0000-0000-0000-000000000003', 'zoom.four@test.invalid'), 'before_scheme',
          'a session before 1 January 2027 is recorded and awards nothing');

-- -----------------------------------------------------------------------------
do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 46. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 46 TESTS PASSED' as result;

rollback;
