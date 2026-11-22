-- =============================================================================
-- 0054, AMI's members come from Dynamics, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: a contact is linked to a website person by email once and
-- by the contact ever after; the name, emails and grade follow Dynamics; a
-- membership is switched on while the contact is an AMI member and off when
-- it leaves the view, unless the view came back far too small; the office
-- cannot change what Dynamics owns for a linked person, and can for anybody
-- else; an unknown category is never guessed; attendance matches by contact.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(24);

insert into auth.users (id, email) values ('7e7e0000-0000-0000-0000-000000000009', 'dm.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('7e7e1111-0000-0000-0000-000000000009', '7e7e0000-0000-0000-0000-000000000009', 'Oona', 'Office', 'dm.office@test.invalid'),
  ('7e7e1111-0000-0000-0000-000000000001', null, 'Fred', 'Oldname', 'fred@company.invalid'),
  ('7e7e1111-0000-0000-0000-000000000002', null, 'Gina', 'Gone', 'gina@company.invalid'),
  ('7e7e1111-0000-0000-0000-000000000003', null, 'Hal', 'Here', 'hal@company.invalid'),
  ('7e7e1111-0000-0000-0000-000000000004', null, 'Ida', 'Unlinked', 'ida@company.invalid');
insert into public.role_grants (person_id, role_code) values ('7e7e1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', v.act, v.st::public.member_status
  from (values
    ('7e7e2222-0000-0000-0000-000000000001','7e7e1111-0000-0000-0000-000000000001','TEST-DM-0001', false, 'lapsed'),
    ('7e7e2222-0000-0000-0000-000000000002','7e7e1111-0000-0000-0000-000000000002','TEST-DM-0002', true,  'current'),
    ('7e7e2222-0000-0000-0000-000000000003','7e7e1111-0000-0000-0000-000000000003','TEST-DM-0003', true,  'current'),
    ('7e7e2222-0000-0000-0000-000000000004','7e7e1111-0000-0000-0000-000000000004','TEST-DM-0004', true,  'current')
  ) v(mid, pid, num, act, st)
  join public.membership_grades g on g.code = 'affiliate';

update public.dynamics_runs set status = 'ok', finished_at = now() where status in ('running', 'requested');
update public.dynamics_feeds set given_field = 'firstname', family_field = 'lastname', email_field = 'emailaddress1',
       email2_field = 'emailaddress2', category_field = 'ami_category', active = true where code = 'ami_members';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create temporary table run (id uuid) on commit drop;
grant all on run to service_role;
set local role service_role;
insert into run select (public.dynamics_run_begin() ->> 'run')::uuid;
select public.dynamics_members_record((select id from run), '{"entity":"contact","fields":[]}', $j$[
  {"_ami_id":"AAAA-1","firstname":"Frederick","lastname":"Newname","emailaddress1":"Fred@Company.invalid",
   "emailaddress2":"fred@home.invalid","ami_category":"Fellow"},
  {"_ami_id":"aaaa-2","firstname":"Gina","lastname":"Gone","emailaddress1":"gina@company.invalid","ami_category":"Affiliate"},
  {"_ami_id":"aaaa-3","firstname":"Hal","lastname":"Here","emailaddress1":"hal@company.invalid","ami_category":"Mystery Grade"},
  {"_ami_id":"aaaa-9","firstname":"Nora","lastname":"Nowhere","emailaddress1":"nora@nowhere.invalid","ami_category":"Fellow"}
]$j$::jsonb);
reset role;

-- -----------------------------------------------------------------------------
-- 1. Linking and copying
-- -----------------------------------------------------------------------------
select is((select dynamics_contact_id from public.people where id = '7e7e1111-0000-0000-0000-000000000001'), 'aaaa-1',
          'a contact is linked to the website person holding its email');
select is((select given_name || ' ' || family_name from public.people where id = '7e7e1111-0000-0000-0000-000000000001'),
          'Frederick Newname', 'the name follows Dynamics');
select is((select alt_email from public.people where id = '7e7e1111-0000-0000-0000-000000000001'), 'fred@home.invalid',
          'and Email Address 2 becomes the second email');
select is((select g.code from public.members m join public.membership_grades g on g.id = m.grade_id
            where m.id = '7e7e2222-0000-0000-0000-000000000001'), 'fellow', 'AMI Category Fellow becomes the Fellow grade');
select is((select is_active from public.members where id = '7e7e2222-0000-0000-0000-000000000001'), true,
          'a lapsed membership whose contact is an AMI member is switched on');
select is((select g.code from public.members m join public.membership_grades g on g.id = m.grade_id
            where m.id = '7e7e2222-0000-0000-0000-000000000003'), 'affiliate', 'an unknown category leaves the grade alone');
select is((select grade_id from public.dynamics_grade_map where category_key = 'mysterygrade'), null,
          'and is never guessed');
select sign_in_as('7e7e0000-0000-0000-0000-000000000009');
select ok(exists (select 1 from public.admin_dynamics_member_check where kind = 'dynamics_only' and email = 'nora@nowhere.invalid'),
          'an AMI member in Dynamics with nobody on the website is on the office''s check list');
select ok(exists (select 1 from public.admin_dynamics_member_check where kind = 'website_only' and membership_number = 'TEST-DM-0004'),
          'and so is an active website member who is not in Dynamics');
reset role;

-- -----------------------------------------------------------------------------
-- 2. What Dynamics owns
-- -----------------------------------------------------------------------------
select sign_in_as('7e7e0000-0000-0000-0000-000000000009');
select throws_ok($$ update public.people set family_name = 'Typed' where id = '7e7e1111-0000-0000-0000-000000000001' $$,
  '42501', null, 'staff cannot change a linked person''s name here');
select throws_ok($$ update public.people set email = 'other@x.invalid' where id = '7e7e1111-0000-0000-0000-000000000001' $$,
  '42501', null, 'or their email');
select throws_ok($$ update public.members set grade_id = (select id from public.membership_grades where code = 'member')
                     where id = '7e7e2222-0000-0000-0000-000000000001' $$,
  '42501', null, 'or their grade');
select throws_ok($$ select public.set_member_active('7e7e2222-0000-0000-0000-000000000001', false, 'test') $$,
  '42501', null, 'or switch them off');
select lives_ok($$ update public.people set mobile = '07700 900000' where id = '7e7e1111-0000-0000-0000-000000000001' $$,
  'but what the website owns is still theirs to change');
select lives_ok($$ update public.people set family_name = 'Unlinked-Typed' where id = '7e7e1111-0000-0000-0000-000000000004' $$,
  'and a person not linked to Dynamics is edited as before');
select throws_ok($$ update public.people set dynamics_contact_id = 'zzzz' where id = '7e7e1111-0000-0000-0000-000000000004' $$,
  '42501', null, 'the link itself is the sync''s to make');
select lives_ok($$ select public.dynamics_grade_map_set('mysterygrade', 'member') $$, 'the office maps a category');
reset role;

-- -----------------------------------------------------------------------------
-- 3. Leaving the view
-- -----------------------------------------------------------------------------
set local role service_role;
create temporary table closed (j jsonb) on commit drop;
grant all on closed to service_role;
insert into closed select public.dynamics_members_close((select id from run), array['AAAA-1', 'aaaa-3', 'aaaa-9']);
reset role;
select is((select is_active from public.members where id = '7e7e2222-0000-0000-0000-000000000002'), false,
          'a member whose contact has left the view is switched off');
select is((select status::text from public.members where id = '7e7e2222-0000-0000-0000-000000000002'), 'lapsed',
          'as lapsed, with Dynamics given as the reason');
select is((select is_active from public.members where id = '7e7e2222-0000-0000-0000-000000000001'), true,
          'and the others stay on');

-- A run where the view comes back almost empty switches nobody off.
insert into public.people (id, given_name, family_name, email, dynamics_contact_id)
select ('7e7e3333-0000-0000-0000-00000000000' || i)::uuid, 'Bulk', 'Member' || i, 'bulk' || i || '@x.invalid', 'bulk-' || i
  from generate_series(1, 6) i;
insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status)
select ('7e7e3333-0000-0000-0000-00000000000' || i)::uuid, 'TEST-BULK-' || i, (select id from public.membership_grades where code = 'member'),
       date '2021-01-01', true, 'current' from generate_series(1, 6) i;
set local role service_role;
delete from closed;
insert into closed select public.dynamics_members_close((select id from run), array['aaaa-1']);
reset role;
select ok((select j ? 'refused' and (j ->> 'switched_off')::int = 0 from closed),
          'a view far smaller than the members it accounts for switches nobody off, and says so: ' || (select j ->> 'refused' from closed));
select is((select count(*)::int from public.members where membership_number like 'TEST-BULK-%' and is_active), 6,
          'everybody stays on');

-- -----------------------------------------------------------------------------
-- 4. Attendance by contact
-- -----------------------------------------------------------------------------
update public.dynamics_feeds set email_field = 'e', email2_field = null, name_field = 'n', event_field = null,
       date_field = 'd', contact_field = '_core_delegatenameid_value', active = true where code = 'arca_agm';
set local role service_role;
select public.dynamics_record((select id from run), 'arca_agm', '{"fields":[]}', $j$[
  {"_ami_id":"dm-1","e":"somewhere@else.invalid","n":"F Newname","_core_delegatenameid_value":"AAAA-1","d":"2026-06-01"},
  {"_ami_id":"dm-2","e":"nora.other@else.invalid","n":"Nora N","_core_delegatenameid_value":"aaaa-9","d":"2026-06-01"}
]$j$::jsonb);
reset role;
select is((select matched_by || '/' || outcome from public.dynamics_attendance where dynamics_id = 'dm-1'), 'contact/before_scheme',
          'a booking is matched by its contact, whatever email it carries');
select sign_in_as('7e7e0000-0000-0000-0000-000000000009');
select ok((select possible from public.admin_cpd_feed_queue where id = (select id from public.dynamics_attendance where dynamics_id = 'dm-2'))
            like 'An AMI member in Dynamics with no website record yet%', 'a member in Dynamics not yet on the website is kept and said so');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 24. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 24 TESTS PASSED' as result;

rollback;
