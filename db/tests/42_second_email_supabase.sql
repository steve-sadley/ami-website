-- =============================================================================
-- 0049, two email addresses matched every time, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: a member's second address is set by the office only and
-- belongs to one person; Zoom and ARCA's records match an attendee by any of
-- their addresses against either of a member's; two addresses pointing at two
-- members is a question for the office, never a guess; linking or dismissing
-- remembers every address the attendee came with.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(20);

insert into public.membership_grades (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('zz-two', 'ZZ TEST two email grade', 'ZZE', true, false, true, 93)
on conflict (code) do nothing;
insert into auth.users (id, email) values
  ('4e4e0000-0000-0000-0000-000000000001', 'two.one@company.invalid'),
  ('4e4e0000-0000-0000-0000-000000000009', 'two.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('4e4e1111-0000-0000-0000-000000000001','4e4e0000-0000-0000-0000-000000000001','Tia','One','two.one@company.invalid'),
  ('4e4e1111-0000-0000-0000-000000000002', null,'Tom','Two','two.two@company.invalid'),
  ('4e4e1111-0000-0000-0000-000000000003', null,'Tess','Three','two.three@company.invalid'),
  ('4e4e1111-0000-0000-0000-000000000009','4e4e0000-0000-0000-0000-000000000009','Ola','Office','two.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('4e4e1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', true, 'current'
  from (values
    ('4e4e2222-0000-0000-0000-000000000001','4e4e1111-0000-0000-0000-000000000001','TEST-E-0001'),
    ('4e4e2222-0000-0000-0000-000000000002','4e4e1111-0000-0000-0000-000000000002','TEST-E-0002'),
    ('4e4e2222-0000-0000-0000-000000000003','4e4e1111-0000-0000-0000-000000000003','TEST-E-0003')
  ) v(mid, pid, num)
  join public.membership_grades g on g.code = 'zz-two';
update public.system_settings set value = '2027-01-01' where key = 'cpd_feeds_from';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- -----------------------------------------------------------------------------
-- 1. The second address on a person
-- -----------------------------------------------------------------------------
select sign_in_as('4e4e0000-0000-0000-0000-000000000001');
select throws_ok($$ update public.people set alt_email = 'anything@test.invalid'
                     where id = '4e4e1111-0000-0000-0000-000000000001' $$,
  '42501', null, 'a member cannot add a second address to their own record');
reset role;
select sign_in_as('4e4e0000-0000-0000-0000-000000000009');
select lives_ok($$ update public.people set alt_email = ' Tia.Home@Personal.invalid '
                    where id = '4e4e1111-0000-0000-0000-000000000001' $$,
  'membership staff can');
select is((select alt_email from public.people where id = '4e4e1111-0000-0000-0000-000000000001'),
          'tia.home@personal.invalid', 'and it is kept tidy, in lower case');
select throws_ok($$ update public.people set alt_email = 'TWO.TWO@company.invalid'
                     where id = '4e4e1111-0000-0000-0000-000000000001' $$,
  '23505', null, 'somebody else''s main address cannot be a second one');
select throws_ok($$ update public.people set alt_email = 'tia.home@personal.invalid'
                     where id = '4e4e1111-0000-0000-0000-000000000003' $$,
  '23505', null, 'nor can one address be two people''s second');
select throws_ok($$ update public.people set email = 'tia.home@personal.invalid'
                     where id = '4e4e1111-0000-0000-0000-000000000002' $$,
  '23505', null, 'nor can a main address be somebody else''s second');
select throws_ok($$ update public.people set alt_email = 'not an address'
                     where id = '4e4e1111-0000-0000-0000-000000000002' $$,
  '22023', null, 'and it has to be an address');
reset role;

-- -----------------------------------------------------------------------------
-- 2. Zoom matches the second address
-- -----------------------------------------------------------------------------
insert into public.zoom_sessions (id, title, kind, zoom_id, held_on, activity_type_id, event_key)
select '4e4e3333-0000-0000-0000-000000000001', 'ZZ TEST two email seminar', 'webinar', '81234567877', date '2027-04-08',
       id, 'zz-test-two-seminar' from public.cpd_activity_types where code = 'ami_seminar';
insert into public.zoom_attendance (id, session_id, identity, email, name, minutes, percent) values
  ('4e4e4444-0000-0000-0000-000000000001', '4e4e3333-0000-0000-0000-000000000001',
   'tia.home@personal.invalid', 'tia.home@personal.invalid', 'Tia at home', 90, 100);
select is(app.zoom_decide('4e4e4444-0000-0000-0000-000000000001'), 'awarded',
          'somebody who joins a webinar from their personal address is matched and awarded');
select is((select member_id from public.zoom_attendance where id = '4e4e4444-0000-0000-0000-000000000001'),
          '4e4e2222-0000-0000-0000-000000000001'::uuid, 'to the member who holds it as their second');

-- -----------------------------------------------------------------------------
-- 3. ARCA's records: both columns
-- -----------------------------------------------------------------------------
select sign_in_as('4e4e0000-0000-0000-0000-000000000009');
update public.dynamics_feeds
   set email_field = 'c.emailaddress1', email2_field = 'c.emailaddress2', name_field = 'c.fullname',
       event_field = 'ev', date_field = 'd'
 where code = 'regional_meetings';
reset role;
select is((select email2_field from public.dynamics_feeds where code = 'regional_meetings'), 'c.emailaddress2',
          'the office names a second email column');

set local role service_role;
create temporary table run (id uuid) on commit drop;
grant all on run to service_role;
insert into run select (public.dynamics_run_begin() ->> 'run')::uuid;
select public.dynamics_record((select id from run), 'regional_meetings', '{"entity":"x","fields":[]}', $j$[
  {"_ami_id":"e1","c.emailaddress1":"tom@newjob.invalid","c.emailaddress2":"two.two@company.invalid","ev":"Wales meeting","d":"2027-05-01"},
  {"_ami_id":"e2","c.emailaddress1":"stranger@x.invalid","c.emailaddress2":"TIA.HOME@personal.invalid","ev":"Wales meeting","d":"2027-05-01"},
  {"_ami_id":"e3","c.fullname":"Tom Two","c.emailaddress1":"two.two@company.invalid","c.emailaddress2":"two.three@company.invalid","ev":"Wales meeting","d":"2027-05-01"},
  {"_ami_id":"e4","c.fullname":"Tess Three","c.emailaddress1":null,"c.emailaddress2":"guest.home@x.invalid","ev":"Wales meeting","d":"2027-05-01"},
  {"_ami_id":"e5","c.fullname":"Tia One","c.emailaddress1":"pair.work@x.invalid","c.emailaddress2":"pair.home@x.invalid","ev":"Wales meeting","d":"2027-05-01"}
]$j$::jsonb);
reset role;
select is((select outcome from public.dynamics_attendance where dynamics_id = 'e1'), 'awarded',
          'an unknown first address and a member''s address second: matched by the second');
select is((select outcome from public.dynamics_attendance where dynamics_id = 'e2'), 'awarded',
          'a booking''s second address against a member''s second address: matched too');
select is((select outcome from public.dynamics_attendance where dynamics_id = 'e3'), 'unmatched',
          'two addresses belonging to two different members is left for the office, never guessed');
select is((select email from public.dynamics_attendance where dynamics_id = 'e4'), 'guest.home@x.invalid',
          'a booking with only the second column filled shows that address');
select is((select email2 from public.admin_cpd_feed_queue where id = (select id from public.dynamics_attendance where dynamics_id = 'e5')),
          'pair.home@x.invalid', 'the queue shows both addresses');

-- -----------------------------------------------------------------------------
-- 4. Linking and dismissing remember every address
-- -----------------------------------------------------------------------------
select sign_in_as('4e4e0000-0000-0000-0000-000000000009');
select is(public.feed_link((select id from public.dynamics_attendance where dynamics_id = 'e5'), 'TEST-E-0003'), 'awarded',
          'the office links a booking to a member');
select is((select count(*)::int from public.cpd_feed_links
            where email in ('pair.work@x.invalid', 'pair.home@x.invalid')
              and member_id = '4e4e2222-0000-0000-0000-000000000003'), 2,
          'and both its addresses are remembered as theirs');
select is(public.feed_dismiss((select id from public.dynamics_attendance where dynamics_id = 'e4')), 'not_member',
          'Not a member');
select is((select not_member from public.cpd_feed_links where email = 'guest.home@x.invalid'), true,
          'is remembered for the address the booking had');
reset role;
select is((select outcome from public.zoom_attendance where id = '4e4e4444-0000-0000-0000-000000000001'), 'awarded',
          'and nothing already awarded was disturbed');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 20. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 20 TESTS PASSED' as result;

rollback;
