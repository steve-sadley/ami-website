-- =============================================================================
-- 0052, a sync reports where every row it read stands.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(2);

insert into public.membership_grades (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('zz-count', 'ZZ TEST count grade', 'ZZC', true, false, true, 95) on conflict (code) do nothing;
insert into public.people (id, given_name, family_name, email)
values ('6e6e1111-0000-0000-0000-000000000001', 'Cara', 'Countrow', 'cara.countrow@test.invalid');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '6e6e2222-0000-0000-0000-000000000001', '6e6e1111-0000-0000-0000-000000000001', 'TEST-C-0001', id,
       date '2021-01-01', true, 'current' from public.membership_grades where code = 'zz-count';
update public.dynamics_runs set status = 'ok', finished_at = now() where status in ('running', 'requested');
update public.dynamics_feeds set email_field = 'e', email2_field = null, name_field = 'n', date_field = 'd', active = true where code = 'arca_agm';

create temporary table runs (id uuid) on commit drop;
grant all on runs to service_role;
set local role service_role;
insert into runs select (public.dynamics_run_begin() ->> 'run')::uuid;
-- First read: one with an address nobody holds, one with no address.
select public.dynamics_record((select id from runs), 'arca_agm', '{"fields":[]}',
  '[{"_ami_id":"c-1","e":"nobody.c1@test.invalid","n":"Cara Countrow","d":"2026-06-01"},{"_ami_id":"c-2","n":"C Countrow","d":"2026-06-01"}]');
-- Read again, unchanged: the no-email row is not decided again, but is still where it stands.
create temporary table got (j jsonb) on commit drop;
grant all on got to service_role;
insert into got select public.dynamics_record((select id from runs), 'arca_agm', '{"fields":[]}',
  '[{"_ami_id":"c-1","e":"nobody.c1@test.invalid","n":"Cara Countrow","d":"2026-06-01"},{"_ami_id":"c-2","n":"C Countrow","d":"2026-06-01"}]');
reset role;
select is((select (j -> 'decided' ->> 'no_email')::int from got), 1,
          'a row with no email read again is still counted, as no email');
select is((select (j -> 'decided' ->> 'unmatched')::int from got), 1,
          'and the unmatched one as unmatched: two rows read, two counted');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 2. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 2 TESTS PASSED' as result;

rollback;
