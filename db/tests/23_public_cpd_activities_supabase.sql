-- =============================================================================
-- 0040, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- The CPD scheme page lists the activity types the office has switched on. The
-- public reads them through one view, and the view must show exactly the active
-- ones and nothing a visitor has no need of.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(8);

insert into public.cpd_activity_types (code, name, is_core, sort_order, points, active)
values ('zz-test-on',  'ZZ TEST switched on',  true,  999, 1.5, true),
       ('zz-test-off', 'ZZ TEST switched off', false, 999, 1,   false);

set local role anon;
select ok(exists(select 1 from public.public_cpd_activities where name = 'ZZ TEST switched on'),
          'an anonymous visitor sees an activity that is switched on');
select ok(not exists(select 1 from public.public_cpd_activities where name = 'ZZ TEST switched off'),
          'and not one that is switched off');
select is((select points from public.public_cpd_activities where name = 'ZZ TEST switched on'),
          1.5::numeric, 'with what it is worth');
select cmp_ok((select count(*)::int from public.public_cpd_activities), '>=', 14,
          'the 2027 scheme''s fourteen are all there');
select throws_ok($$ select min_words from public.public_cpd_activities $$, '42703', null,
          'the view carries nothing a visitor has no need of');
select throws_ok($$ select * from public.cpd_activity_types $$, '42501', null,
          'and the table itself is still closed to the public');
reset role;

update public.cpd_activity_types set active = false where code = 'zz-test-on';
set local role anon;
select ok(not exists(select 1 from public.public_cpd_activities where name = 'ZZ TEST switched on'),
          'switching an activity off in the admin app takes it off the page');
reset role;

select is((select count(*)::int from public.public_cpd_activities where is_core)
          + (select count(*)::int from public.public_cpd_activities where not is_core),
          (select count(*)::int from public.public_cpd_activities),
          'every activity is either core or non core, so each lands in one card');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 8. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 8 TESTS PASSED' as result;

rollback;
