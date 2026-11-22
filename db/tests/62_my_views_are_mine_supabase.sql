-- =============================================================================
-- 0063, every "my" view shows the signed in person's own rows, even to staff,
-- proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- A member of staff who is also a member, and another member with CPD of their
-- own. Signed in as the first, EVERY view whose name starts my_ must show only
-- their own rows: profile and card one row each, CPD only their entries, and
-- nothing with somebody else's member id. A view added later under the my_
-- name without a filter fails the last check. Nothing is kept: it rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(7);

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- How many rows in any my_ view belong to somebody else, by member_id where the
-- view has one. Views without the column are checked by name below.
create or replace function pg_temp.others(p_mine uuid) returns text language plpgsql as $$
declare v record; n int; seen text := '';
begin
  for v in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'public' and c.relkind = 'v' and c.relname like 'my\_%'
              and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'member_id') loop
    execute format('select count(*) from public.%I where member_id is distinct from $1', v.relname) into n using p_mine;
    if n > 0 then seen := seen || v.relname || ' (' || n || ') '; end if;
  end loop;
  return seen;
end $$;
grant execute on function pg_temp.others(uuid) to authenticated;

insert into auth.users (id, email) values
  ('5e5e0000-0000-0000-0000-000000000001', 'mine.staff@test.invalid'),
  ('5e5e0000-0000-0000-0000-000000000002', 'mine.other@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('5e5e1111-0000-0000-0000-000000000001', '5e5e0000-0000-0000-0000-000000000001', 'Sam', 'Staffmember', 'mine.staff@test.invalid'),
  ('5e5e1111-0000-0000-0000-000000000002', '5e5e0000-0000-0000-0000-000000000002', 'Oda', 'Other', 'mine.other@test.invalid');
insert into public.role_grants (person_id, role_code) values
  ('5e5e1111-0000-0000-0000-000000000001', 'super_user'),
  ('5e5e1111-0000-0000-0000-000000000001', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5e5e2222-0000-0000-0000-000000000001', '5e5e1111-0000-0000-0000-000000000001', 'TEST-MINE-1',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5e5e2222-0000-0000-0000-000000000002', '5e5e1111-0000-0000-0000-000000000002', 'TEST-MINE-2',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
insert into public.member_preferences (member_id) values
  ('5e5e2222-0000-0000-0000-000000000001'), ('5e5e2222-0000-0000-0000-000000000002')
on conflict (member_id) do nothing;
insert into public.cpd_entries (member_id, year, occurred_on, title, points, is_core, how_recorded, status, activity_type_id)
select '5e5e2222-0000-0000-0000-000000000002', extract(year from current_date)::int, current_date,
       'ZZ MINE other''s entry', 1, false, 'self_declared', 'pending', id
  from public.cpd_activity_types where member_can_log order by sort_order limit 1;

select sign_in_as('5e5e0000-0000-0000-0000-000000000001');
select ok((select count(*) from public.members) > 1,
          'the setting: this person is staff, so the members table shows them more than their own row');
select is((select count(*)::int from public.my_profile), 1, 'my_profile is their one row, not the membership');
select is((select membership_number from public.my_profile), 'TEST-MINE-1', 'and it is theirs');
select is((select count(*)::int from public.my_card), 1, 'my_card is their one card');
select is((select count(*)::int from public.my_cpd where title like 'ZZ MINE%'), 0,
          'my_cpd does not list somebody else''s entry as theirs');
select is(pg_temp.others('5e5e2222-0000-0000-0000-000000000001'), '',
          'no my_ view holds a row with somebody else''s member id');
reset role;
select sign_in_as('5e5e0000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.my_cpd where title like 'ZZ MINE%'), 1,
          'and the other member still sees their own entry');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 7. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 7 TESTS PASSED' as result;

rollback;
