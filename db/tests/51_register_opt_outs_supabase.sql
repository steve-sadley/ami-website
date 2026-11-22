-- =============================================================================
-- Before the members are loaded: a member's own switches decide what the
-- public sees of them, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- Asked by the security check on 31 October: does a member who opts out of
-- the register stay off it, and is a photograph only public when switched on.
-- Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(9);

insert into public.membership_grades (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('zz-optout', 'ZZ TEST opt out grade', 'ZZO', true, true, false, 95) on conflict (code) do nothing;

insert into public.people (id, given_name, family_name, email, photo_path) values
  ('5e5e0000-0000-0000-0000-000000000001', 'Lisa',  'Listed',    'listed@test.invalid',   'p/listed.jpg'),
  ('5e5e0000-0000-0000-0000-000000000002', 'Ollie', 'Optedout',  'optedout@test.invalid', 'p/optedout.jpg'),
  ('5e5e0000-0000-0000-0000-000000000003', 'Nina',  'Noprofile', 'noprofile@test.invalid', null),
  ('5e5e0000-0000-0000-0000-000000000004', 'Ian',   'Inactive',  'inactive@test.invalid', null);
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select ('5e5e1111-0000-0000-0000-00000000000' || n)::uuid, ('5e5e0000-0000-0000-0000-00000000000' || n)::uuid,
       'TEST-OPT-' || n, g.id, date '2022-03-04', n <> 4, (case when n = 4 then 'lapsed' else 'current' end)::public.member_status
  from public.membership_grades g, generate_series(1, 4) n where g.code = 'zz-optout';
insert into public.member_preferences (member_id, list_on_register, public_profile, photo_on_public_page) values
  ('5e5e1111-0000-0000-0000-000000000001', true,  true,  true),
  ('5e5e1111-0000-0000-0000-000000000002', false, true,  false),
  ('5e5e1111-0000-0000-0000-000000000003', true,  false, false),
  ('5e5e1111-0000-0000-0000-000000000004', true,  true,  true);
insert into public.register_slugs (slug, member_id) values
  ('test-opt-listed',    '5e5e1111-0000-0000-0000-000000000001'),
  ('test-opt-optedout',  '5e5e1111-0000-0000-0000-000000000002'),
  ('test-opt-noprofile', '5e5e1111-0000-0000-0000-000000000003'),
  ('test-opt-inactive',  '5e5e1111-0000-0000-0000-000000000004');

set local role anon;

select is((select count(*)::int from public.public_register where membership_number = 'TEST-OPT-1'), 1,
          'a member on the register is listed');
select is((select count(*)::int from public.public_register where membership_number = 'TEST-OPT-2'), 0,
          'a member who opted out of the register is not listed');
select is((select count(*)::int from public.public_register where membership_number = 'TEST-OPT-4'), 0,
          'a lapsed member is not listed');
select is((select count(*)::int from public.public_profile where slug = 'test-opt-noprofile'), 0,
          'a member who switched their public profile off has none');
select is((select photo_path from public.public_profile where slug = 'test-opt-listed'), 'p/listed.jpg',
          'a photograph switched on is shown');
select is((select photo_path from public.public_profile where slug = 'test-opt-optedout'), null,
          'a photograph not switched on is not, even though there is one');
select is((select photo_path from public.public_profile where slug = 'test-opt-inactive'), null,
          'a lapsed member''s photograph is not shown, whatever their switch says');
select is((select joined_on from public.public_profile where slug = 'test-opt-inactive'), null,
          'nor is a lapsed member''s joining date');
select is((select string_agg(membership_number, ', ' order by membership_number) from public.public_register
            where membership_number like 'TEST-OPT-%'), 'TEST-OPT-1, TEST-OPT-3',
          'of the four, the register lists the two who are current and opted in (a profile switched off is a separate choice)');

reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 9. Do not load members until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 9 TESTS PASSED' as result;

rollback;
