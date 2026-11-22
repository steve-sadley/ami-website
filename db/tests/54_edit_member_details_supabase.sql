-- =============================================================================
-- 0060, the office edits a member's number, joining date, job title and
-- employer, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: only membership staff may do it (not a member, not an
-- editor); the number is tidied, must be unique in any case, letters digits
-- and hyphens only, never empty; a number kept on the previous register for
-- somebody else is refused, one kept for this member is taken and remembered,
-- and the one given up is released; the joining date cannot be in the future;
-- an employer is found by name in any case or made, and empty clears it; a
-- member linked to Dynamics can be edited; the change is in the audit log as
-- the staff member; and the members list shows the employer to staff only.
-- Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(22);

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- the SQLSTATE a statement raises as the current role, or 'ok'
create or replace function state_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
grant execute on function state_of(text) to authenticated;

insert into auth.users (id, email) values
  ('5b5b0000-0000-0000-0000-000000000001', 'edit.office@test.invalid'),
  ('5b5b0000-0000-0000-0000-000000000002', 'edit.member@test.invalid'),
  ('5b5b0000-0000-0000-0000-000000000003', 'edit.editor@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email, dynamics_contact_id) values
  ('5b5b1111-0000-0000-0000-000000000001', '5b5b0000-0000-0000-0000-000000000001', 'Ora', 'Office', 'edit.office@test.invalid', null),
  ('5b5b1111-0000-0000-0000-000000000002', '5b5b0000-0000-0000-0000-000000000002', 'Mel', 'Testedit', 'edit.member@test.invalid', 'ed-linked'),
  ('5b5b1111-0000-0000-0000-000000000003', '5b5b0000-0000-0000-0000-000000000003', 'Ed', 'Editor', 'edit.editor@test.invalid', null),
  ('5b5b1111-0000-0000-0000-000000000004', null, 'Oth', 'Other', 'edit.other@test.invalid', null);
insert into public.role_grants (person_id, role_code) values
  ('5b5b1111-0000-0000-0000-000000000001', 'membership'),
  ('5b5b1111-0000-0000-0000-000000000003', 'editor');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5b5b2222-0000-0000-0000-000000000002', '5b5b1111-0000-0000-0000-000000000002', 'TEST-ED-1',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5b5b2222-0000-0000-0000-000000000004', '5b5b1111-0000-0000-0000-000000000004', 'TEST-ED-2',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
insert into public.organisations (name) values ('Testedit Removals Ltd')
on conflict do nothing;
insert into public.legacy_register (membership_number, given_name, family_name, grade, joined_on) values
  ('TEST-ED-RES', 'Rita', 'Reserved', 'Fellow', date '2015-01-01'),
  ('TEST-ED-OWN', 'Melanie', 'Testedit', 'Fellow', date '2016-01-01');

-- 1. who may
select sign_in_as('5b5b0000-0000-0000-0000-000000000002');
select is(state_of($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-9', date '2020-01-01')$$),
          '42501', 'a member cannot change their own number');
reset role;
select sign_in_as('5b5b0000-0000-0000-0000-000000000003');
select is(state_of($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-9', date '2020-01-01')$$),
          '42501', 'nor can an editor, who is staff but not membership staff');
reset role;

-- 2. the number
select sign_in_as('5b5b0000-0000-0000-0000-000000000001');
select is(state_of($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'test-ed-2', date '2020-01-01')$$),
          '23505', 'a number another member holds is refused, whatever its case');
select is(state_of($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', '', date '2020-01-01')$$),
          '22023', 'an empty number is refused');
select is(state_of($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST ED/1', date '2020-01-01')$$),
          '22023', 'and so is one with spaces or slashes in it');
select is(state_of($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-RES', date '2020-01-01')$$),
          '23505', 'a number the previous register keeps for somebody else is refused');
select is(public.update_member_details('5b5b2222-0000-0000-0000-000000000002', '  test-ed-own ', date '2016-01-01') ->> 'membership_number',
          'TEST-ED-OWN', 'their own register number is taken, trimmed and upper cased');
reset role;
select is((select used_by from public.legacy_register where membership_number = 'TEST-ED-OWN'),
          '5b5b2222-0000-0000-0000-000000000002'::uuid, 'and the register remembers who took it');
select sign_in_as('5b5b0000-0000-0000-0000-000000000001');
select is(public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-3', date '2016-01-01') ->> 'number_changed',
          'true', 'a member who already has a register number can move to another');
reset role;
select ok((select used_by is null from public.legacy_register where membership_number = 'TEST-ED-OWN'),
          'and the number given up is released on the register');

-- 3. the date
select sign_in_as('5b5b0000-0000-0000-0000-000000000001');
select is(state_of($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-3', current_date + 1)$$),
          '22023', 'a joining date in the future is refused');

-- 4. job title and employer
select lives_ok($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-3',
                    date '2016-03-04', '  Contracts Manager ', 'testedit removals ltd')$$,
                'staff can set the job title and employer');
reset role;
select is((select current_job_title || ' | ' || joined_on from public.members where id = '5b5b2222-0000-0000-0000-000000000002'),
          'Contracts Manager | 2016-03-04', 'the title is trimmed and the date is kept');
select is((select count(*)::int from public.organisations where lower(name) = 'testedit removals ltd'), 1,
          'the existing organisation is used, ignoring case, not a second one made');
select sign_in_as('5b5b0000-0000-0000-0000-000000000001');
select lives_ok($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-3',
                    date '2016-03-04', 'Contracts Manager', 'Testedit New   Employer Ltd')$$,
                'a new employer name');
reset role;
select is((select o.name from public.members m join public.organisations o on o.id = m.employer_id
            where m.id = '5b5b2222-0000-0000-0000-000000000002'),
          'Testedit New Employer Ltd', 'makes an organisation, with its spaces tidied');
select sign_in_as('5b5b0000-0000-0000-0000-000000000001');
select lives_ok($$select public.update_member_details('5b5b2222-0000-0000-0000-000000000002', 'TEST-ED-3',
                    date '2016-03-04', '', '')$$, 'empty title and employer');
reset role;
select ok((select current_job_title is null and employer_id is null from public.members
            where id = '5b5b2222-0000-0000-0000-000000000002'),
          'clear both');

-- 5. Dynamics and the audit log
select is((select given_name || ' ' || family_name || ' ' || is_active::text
             from public.people p join public.members m on m.person_id = p.id
            where m.id = '5b5b2222-0000-0000-0000-000000000002'),
          'Mel Testedit true', 'a member linked to Dynamics was edited, and what Dynamics owns is untouched');
select ok(exists (select 1 from public.audit_log
                   where table_name = 'members' and row_id = '5b5b2222-0000-0000-0000-000000000002'
                     and actor_id = '5b5b1111-0000-0000-0000-000000000001'
                     and after ->> 'membership_number' = 'TEST-ED-3'),
          'the change is in the audit log, as the member of staff who made it');

-- 6. the members list
select sign_in_as('5b5b0000-0000-0000-0000-000000000001');
select is((select employer is null and in_dynamics from public.admin_member_list
            where id = '5b5b2222-0000-0000-0000-000000000002'),
          true, 'staff see the employer and the Dynamics link on the members list');
reset role;
select sign_in_as('5b5b0000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.admin_member_list), 0,
          'a member still sees nothing in it, own row included');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 22. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 22 TESTS PASSED' as result;

rollback;
