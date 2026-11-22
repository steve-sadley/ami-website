-- =============================================================================
-- 0057, every admin_ view answers staff only, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- Checks EVERY view whose name starts admin_, as it is in the database now, so
-- a view added later without the staff gate fails here.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(3);

insert into public.membership_grades (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('zz-gate', 'ZZ TEST gate grade', 'ZZG', true, false, true, 96) on conflict (code) do nothing;
insert into auth.users (id, email) values
  ('9e9e0000-0000-0000-0000-000000000001', 'gate.member@test.invalid'),
  ('9e9e0000-0000-0000-0000-000000000009', 'gate.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('9e9e1111-0000-0000-0000-000000000001', '9e9e0000-0000-0000-0000-000000000001', 'Gail', 'Gate', 'gate.member@test.invalid'),
  ('9e9e1111-0000-0000-0000-000000000009', '9e9e0000-0000-0000-0000-000000000009', 'Ola', 'Gate', 'gate.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('9e9e1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status)
select '9e9e1111-0000-0000-0000-000000000001', 'TEST-GATE-1', id, date '2021-01-01', true, 'current'
  from public.membership_grades where code = 'zz-gate';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- Every admin_ view, counted as the member. A view the member cannot read at
-- all (permission denied) counts as nothing too.
create or replace function pg_temp.member_sees() returns text language plpgsql as $$
declare v record; n int; seen text := '';
begin
  for v in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'public' and c.relkind = 'v' and c.relname like 'admin\_%' loop
    begin
      execute format('select count(*) from public.%I', v.relname) into n;
    exception when insufficient_privilege then n := 0;
    end;
    if n > 0 then seen := seen || v.relname || ' (' || n || ') '; end if;
  end loop;
  return seen;
end $$;

select sign_in_as('9e9e0000-0000-0000-0000-000000000001');
select is(pg_temp.member_sees(), '', 'a signed in member sees nothing in any admin view, not even their own row');
reset role;
select sign_in_as('9e9e0000-0000-0000-0000-000000000009');
select ok((select count(*) from public.admin_member_list where membership_number = 'TEST-GATE-1') = 1,
          'membership staff still see the member in admin_member_list');
reset role;
select ok((select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'public' and c.relkind = 'v' and c.relname like 'admin\_%') >= 15,
          'and there are admin views to check: the test is not checking nothing');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 3. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 3 TESTS PASSED' as result;

rollback;
