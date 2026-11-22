-- =============================================================================
-- 0051, a feed's last result is the whole run, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(4);

update public.dynamics_runs set status = 'ok', finished_at = now() where status in ('running', 'requested');
update public.dynamics_feeds set email_field = 'e', date_field = 'd', active = true where code = 'arca_agm';

create temporary table runs (n int, id uuid) on commit drop;
grant all on runs to service_role;
set local role service_role;
insert into runs select 1, (public.dynamics_run_begin() ->> 'run')::uuid;
select public.dynamics_record((select id from runs where n = 1), 'arca_agm', '{"fields":[]}',
  '[{"_ami_id":"t-1","e":"nobody1@test.invalid","d":"2026-06-01"},{"_ami_id":"t-2","e":"nobody2@test.invalid","d":"2026-06-01"}]');
select public.dynamics_record((select id from runs where n = 1), 'arca_agm', '{"fields":[]}',
  '[{"_ami_id":"t-3","e":"nobody3@test.invalid","d":"2026-06-01"},{"_ami_id":"t-4","d":"not a date"}]');
reset role;
select is((select (last_result ->> 'read')::int from public.dynamics_feeds where code = 'arca_agm'), 4,
          'two batches of one run add up: 4 rows, not the last batch''s 2');
select is((select (last_result ->> 'unreadable')::int from public.dynamics_feeds where code = 'arca_agm'), 1,
          'and so do the rows that could not be read');
select is((select (last_result -> 'decided' ->> 'not_kept')::int from public.dynamics_feeds where code = 'arca_agm'), 3,
          'and what was decided, here three not kept (0053)');

set local role service_role;
select public.dynamics_run_finish((select id from runs where n = 1), '{}');
insert into runs select 2, (public.dynamics_run_begin() ->> 'run')::uuid;
select public.dynamics_record((select id from runs where n = 2), 'arca_agm', '{"fields":[]}',
  '[{"_ami_id":"t-1","e":"nobody1@test.invalid","d":"2026-06-01"}]');
reset role;
select is((select (last_result ->> 'read')::int from public.dynamics_feeds where code = 'arca_agm'), 1,
          'a new run starts its count afresh');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 4. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 4 TESTS PASSED' as result;

rollback;
