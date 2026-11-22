-- =============================================================================
-- 0062, members ask to change their emails, choose which AMI uses, and the
-- office sees every change a member makes to their own record, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(27);

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function state_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
grant execute on function state_of(text) to authenticated;

insert into auth.users (id, email) values
  ('5d5d0000-0000-0000-0000-000000000001', 'chg.office@test.invalid'),
  ('5d5d0000-0000-0000-0000-000000000002', 'chg.member@test.invalid'),
  ('5d5d0000-0000-0000-0000-000000000003', 'chg.other@test.invalid'),
  ('5d5d0000-0000-0000-0000-000000000004', 'chg.nobody@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email, alt_email, dynamics_contact_id) values
  ('5d5d1111-0000-0000-0000-000000000001', '5d5d0000-0000-0000-0000-000000000001', 'Ona', 'Office', 'chg.office@test.invalid', null, null),
  ('5d5d1111-0000-0000-0000-000000000002', '5d5d0000-0000-0000-0000-000000000002', 'Mia', 'Testchange', 'mia.work@chg.invalid', null, 'chg-linked'),
  ('5d5d1111-0000-0000-0000-000000000003', '5d5d0000-0000-0000-0000-000000000003', 'Uly', 'Unlinked', 'uly.work@chg.invalid', null, null),
  ('5d5d1111-0000-0000-0000-000000000004', '5d5d0000-0000-0000-0000-000000000004', 'Nob', 'Nobody', 'chg.nobody@test.invalid', 'taken@chg.invalid', null);
insert into public.role_grants (person_id, role_code) values ('5d5d1111-0000-0000-0000-000000000001', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5d5d2222-0000-0000-0000-000000000002', '5d5d1111-0000-0000-0000-000000000002', 'TEST-CHG-1',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5d5d2222-0000-0000-0000-000000000003', '5d5d1111-0000-0000-0000-000000000003', 'TEST-CHG-2',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
insert into public.member_preferences (member_id) values
  ('5d5d2222-0000-0000-0000-000000000002'), ('5d5d2222-0000-0000-0000-000000000003')
on conflict (member_id) do nothing;

-- 1. asking
select sign_in_as('5d5d0000-0000-0000-0000-000000000004');
select is(state_of($$select public.request_my_email_change('a@chg.invalid', null)$$), '42501',
          'somebody with no membership cannot ask');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000002');
select is(state_of($$select public.request_my_email_change('not an address', null)$$), '22023',
          'something that is not an address is refused');
select is(state_of($$select public.request_my_email_change('MIA.WORK@chg.invalid', null)$$), '22023',
          'asking for what is already held is refused');
select is(state_of($$insert into public.email_change_requests (person_id, work_email) values
            ('5d5d1111-0000-0000-0000-000000000002', 'x@chg.invalid')$$), '42501',
          'a member cannot write a request straight into the table');
select is(public.request_my_email_change('mia.first@chg.invalid', 'mia.home@chg.invalid') ->> 'status', 'pending',
          'a member asks for a new work and private email');
select is(public.request_my_email_change(' Mia.New@chg.invalid ', 'mia.home@chg.invalid') ->> 'work_email', 'mia.new@chg.invalid',
          'asking again replaces the first, tidied');
select is((select count(*)::int from public.email_change_requests where status = 'pending'), 1,
          'and only one is waiting; the member reads only their own');
select is((select email_request_status || ' ' || email_request_work || ' ' || email_request_private from public.my_profile),
          'pending mia.new@chg.invalid mia.home@chg.invalid', 'their profile shows what is waiting');
select is(state_of($$select public.request_my_email_change('a1@chg.invalid', null);
                    select public.request_my_email_change('a2@chg.invalid', null);
                    select public.request_my_email_change('a3@chg.invalid', null);
                    select public.request_my_email_change('a4@chg.invalid', null);$$), '54000',
          'no more than five requests a day: the sixth is refused');
reset role;

-- 2. arriving from Dynamics, as the sync does it: no signed in person at all
select set_config('request.jwt.claim.sub', '', true);
delete from public.email_change_requests where person_id = '5d5d1111-0000-0000-0000-000000000002' and work_email like 'a_@chg.invalid';
update public.email_change_requests set status = 'pending', decided_at = null
 where person_id = '5d5d1111-0000-0000-0000-000000000002' and work_email = 'mia.new@chg.invalid';
update public.people set email = 'mia.new@chg.invalid' where id = '5d5d1111-0000-0000-0000-000000000002';
select is((select status from public.email_change_requests where work_email = 'mia.new@chg.invalid'), 'pending',
          'half of it arriving does not close the request');
update public.people set alt_email = 'Mia.Home@chg.invalid' where id = '5d5d1111-0000-0000-0000-000000000002';
select is((select status from public.email_change_requests where work_email = 'mia.new@chg.invalid'), 'done',
          'all of it arriving from the sync closes it on its own');

-- 3. choosing
select sign_in_as('5d5d0000-0000-0000-0000-000000000002');
select is(public.set_my_preferred_email('private'), 'mia.home@chg.invalid', 'the member chooses their private email');
select is((select preferred_email || ' ' || contact_email || ' ' || alt_email from public.my_profile),
          'private mia.home@chg.invalid mia.home@chg.invalid', 'and their profile says so');
select is(state_of($$select public.set_my_preferred_email('pigeon')$$), '22023', 'a made up choice is refused');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000003');
select is(state_of($$select public.set_my_preferred_email('private')$$), '22023', 'private is refused when none is held');

-- 4. the office
select is(state_of($$select public.email_change_decide((select id from public.email_change_requests limit 1), 'decline', 'x')$$),
          '42501', 'a member cannot decide requests');
select public.request_my_email_change('uly.new@chg.invalid', 'taken@chg.invalid');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000002');
select public.request_my_email_change('mia.again@chg.invalid', 'mia.home@chg.invalid');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select is(state_of($$select public.email_change_decide((select id from public.admin_email_change_requests
            where status = 'pending' and work_email = 'mia.again@chg.invalid'), 'apply')$$),
          '22023', 'a linked member''s request cannot be applied here: it is done in Dynamics');
select ok((select address_on_another_record from public.admin_email_change_requests where work_email = 'uly.new@chg.invalid'),
          'the queue warns when an address asked for is on somebody else''s record');
select is(state_of($$select public.email_change_decide((select id from public.admin_email_change_requests
            where status = 'pending' and work_email = 'uly.new@chg.invalid'), 'apply')$$), '23505',
          'and applying it is refused in words rather than failing on the database''s own rule');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000003');
select public.request_my_email_change('uly.new@chg.invalid', 'uly.home@chg.invalid');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select is(public.email_change_decide((select id from public.admin_email_change_requests
            where status = 'pending' and work_email = 'uly.new@chg.invalid'), 'apply'), 'done',
          'an unlinked member''s request is applied here');
reset role;
select is((select email || ' ' || alt_email from public.people where id = '5d5d1111-0000-0000-0000-000000000003'),
          'uly.new@chg.invalid uly.home@chg.invalid', 'and their record changes');
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select is(state_of($$select public.email_change_decide((select id from public.admin_email_change_requests
            where status = 'pending' and work_email = 'mia.again@chg.invalid'), 'decline')$$),
          '22023', 'declining needs a reason');
select lives_ok($$select public.email_change_decide((select id from public.admin_email_change_requests
            where status = 'pending' and work_email = 'mia.again@chg.invalid'), 'decline', 'Please ring the office first.')$$,
          'with a reason it is declined');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000002');
select is((select email_request_status || ': ' || email_request_note from public.my_profile),
          'declined: Please ring the office first.', 'the member sees it was declined, and why');

-- 5. the record of what members changed
select public.update_my_profile(p_mobile => '07700 900123');
update public.member_preferences set list_on_register = false where member_id = '5d5d2222-0000-0000-0000-000000000002';
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000001');
select ok(exists (select 1 from public.admin_member_changes
                   where person_id = '5d5d1111-0000-0000-0000-000000000002' and area = 'Details'
                     and changes -> 'mobile' ->> 'after' = '07700 900123')
      and exists (select 1 from public.admin_member_changes
                   where person_id = '5d5d1111-0000-0000-0000-000000000002' and area = 'Switches'
                     and changes -> 'list_on_register' ->> 'after' = 'false')
      and exists (select 1 from public.admin_member_changes
                   where person_id = '5d5d1111-0000-0000-0000-000000000002' and area = 'Email request'),
          'the office sees the member''s telephone, switch and email request changes, before and after');
select ok(not exists (select 1 from public.admin_member_changes
                       where person_id = '5d5d1111-0000-0000-0000-000000000001'
                          or (area = 'Details' and changes ? 'alt_email'
                              and person_id = '5d5d1111-0000-0000-0000-000000000003')),
          'changes made by the office or the sync are not listed as the member''s');
reset role;
select sign_in_as('5d5d0000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.admin_member_changes) + (select count(*)::int from public.admin_email_change_requests),
          0, 'a member sees nothing in either office list');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 27. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 27 TESTS PASSED' as result;

rollback;
