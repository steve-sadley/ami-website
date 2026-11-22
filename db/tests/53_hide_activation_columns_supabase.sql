-- =============================================================================
-- 0059, a member's own row no longer shows who switched it or why, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: a signed in member still reads their own row, the columns
-- the site uses included; the same member cannot read activated_by,
-- deactivated_by or deactivation_reason, either by naming them or with
-- select *; no table level select grant has crept back; staff read the three
-- through member_activation(), with names; a member calling it is refused; and
-- staff can still switch a membership off with a reason.
-- Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(12);

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- Does a statement raise "permission denied" (42501) as the current role?
create or replace function denied(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when insufficient_privilege then
  return true;
end $$;
grant execute on function denied(text) to authenticated;

insert into auth.users (id, email) values
  ('5a5a0000-0000-0000-0000-000000000001', 'hide.office@test.invalid'),
  ('5a5a0000-0000-0000-0000-000000000002', 'hide.member@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('5a5a1111-0000-0000-0000-000000000001', '5a5a0000-0000-0000-0000-000000000001', 'Olive', 'Office', 'hide.office@test.invalid'),
  ('5a5a1111-0000-0000-0000-000000000002', '5a5a0000-0000-0000-0000-000000000002', 'Max', 'Member', 'hide.member@test.invalid');
insert into public.role_grants (person_id, role_code) values
  ('5a5a1111-0000-0000-0000-000000000001', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status,
                            activated_by, deactivated_by, deactivation_reason)
select '5a5a2222-0000-0000-0000-000000000002', '5a5a1111-0000-0000-0000-000000000002', 'TEST-HIDE-1',
       id, date '2020-01-01', true, 'current',
       '5a5a1111-0000-0000-0000-000000000001', '5a5a1111-0000-0000-0000-000000000001',
       'Office note: TEST-HIDE reason'
  from public.membership_grades where code = 'member';

-- 1. the grants, read from the catalogue
select ok(not has_table_privilege('authenticated', 'public.members', 'select'),
          'signed in users hold no table level select on members');
select ok(not has_column_privilege('authenticated', 'public.members', 'activated_by', 'select')
      and not has_column_privilege('authenticated', 'public.members', 'deactivated_by', 'select')
      and not has_column_privilege('authenticated', 'public.members', 'deactivation_reason', 'select'),
          'nor on the three office columns');
select ok(has_column_privilege('authenticated', 'public.members', 'membership_number', 'select')
      and has_column_privilege('authenticated', 'public.members', 'is_active', 'select')
      and has_column_privilege('authenticated', 'public.members', 'activated_at', 'select'),
          'but they keep the columns the site and admin_member_list read');

-- 2. as the member
select sign_in_as('5a5a0000-0000-0000-0000-000000000002');
select is((select membership_number || ' ' || is_active || ' ' || status
             from public.members),
          'TEST-HIDE-1 true current',
          'a member still reads their own row, as the sign in page does');
select ok(denied($$select activated_by from public.members$$),
          'a member cannot read activated_by');
select ok(denied($$select deactivated_by from public.members$$),
          'nor deactivated_by');
select ok(denied($$select deactivation_reason from public.members$$),
          'nor deactivation_reason');
select ok(denied($$select * from public.members$$),
          'and select star is refused rather than handing them over');
select ok(denied($$select public.member_activation('5a5a2222-0000-0000-0000-000000000002')$$),
          'a member cannot use the office''s function either');
reset role;

-- 3. as membership staff
select sign_in_as('5a5a0000-0000-0000-0000-000000000001');
select is(public.member_activation('5a5a2222-0000-0000-0000-000000000002') ->> 'deactivation_reason',
          'Office note: TEST-HIDE reason',
          'staff read the reason through member_activation');
select is(public.member_activation('5a5a2222-0000-0000-0000-000000000002') ->> 'activated_by',
          'Olive Office',
          'and see who switched it by name, not by id');
select lives_ok(
  $$select public.set_member_active('5a5a2222-0000-0000-0000-000000000002', false, 'TEST-HIDE lapsed')$$,
  'staff can still switch a membership off with a reason');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 12. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 12 TESTS PASSED' as result;

rollback;
