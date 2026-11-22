-- =============================================================================
-- 0050, a Dynamics column name matches whatever its case.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(7);

create temporary table r (j jsonb) on commit drop;
insert into r values ('{"a_60ecf_x002e_emailaddress1":"Ann@Test.Invalid",
  "a_a65_x002e_core_eventend":"2027-06-17T08:00:00Z",
  "_core_eventnameid_value":"g-1","_core_eventnameid_value@OData.Community.Display.V1.FormattedValue":"ARCA AGM 2027"}');

select is(app.dyn_text((select j from r), 'a_60ecf_x002e_emailaddress1'), 'Ann@Test.Invalid', 'the exact name is found');
select is(app.dyn_text((select j from r), 'A_60ECF_X002E_EMAILADDRESS1'), 'Ann@Test.Invalid', 'and the same name in capitals');
select is(app.dyn_date((select j from r), 'A_A65_X002E_CORE_EVENTEND'), date '2027-06-17', 'a date column in capitals');
select is(app.dyn_text((select j from r), '_CORE_EVENTNAMEID_VALUE'), 'ARCA AGM 2027', 'a lookup in capitals still gives its words');
select is(app.dyn_text('{"_x_value@OData.Community.Display.V1.FormattedValue":"Words only"}'::jsonb, '_X_VALUE'), 'Words only',
          'words carried without the id are still found');
select is(app.dyn_text((select j from r), 'nothing_like_it'), null, 'a name that is not there gives nothing');
select is(app.dyn_text((select j from r), null), null, 'and no name gives nothing');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 7. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 7 TESTS PASSED' as result;

rollback;
