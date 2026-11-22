-- =============================================================================
-- 0058, members keep the numbers they have, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: a member on the current register keeps their number and
-- joining date, found through a short form of their first name; two Dynamics
-- records for one register entry are held back; anybody new gets the next
-- number for the month; a register entry Dynamics does not list is reported;
-- a linked member still on a TEST- number takes theirs; nobody else can read
-- the register. Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(16);

create temporary table m (mmyy text) on commit drop;
insert into m values (to_char(current_date, 'MMYY'));
grant select on m to authenticated;

insert into auth.users (id, email) values
  ('5f5f0000-0000-0000-0000-000000000001', 'num.super@test.invalid'),
  ('5f5f0000-0000-0000-0000-000000000002', 'num.office@test.invalid'),
  ('5f5f0000-0000-0000-0000-000000000003', 'num.member@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email, dynamics_contact_id) values
  ('5f5f1111-0000-0000-0000-000000000001', '5f5f0000-0000-0000-0000-000000000001', 'Sid', 'Super', 'num.super@test.invalid', null),
  ('5f5f1111-0000-0000-0000-000000000002', '5f5f0000-0000-0000-0000-000000000002', 'Olga', 'Office', 'num.office@test.invalid', null),
  ('5f5f1111-0000-0000-0000-000000000003', '5f5f0000-0000-0000-0000-000000000003', 'Mo', 'Member', 'num.member@test.invalid', null),
  ('5f5f1111-0000-0000-0000-000000000004', null, 'Stephen', 'Testlinked', 'linked@num.invalid', 'nm-linked');
insert into public.role_grants (person_id, role_code) values
  ('5f5f1111-0000-0000-0000-000000000001', 'super_user'),
  ('5f5f1111-0000-0000-0000-000000000002', 'membership');
insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status)
select '5f5f1111-0000-0000-0000-000000000004', 'TEST-NUM-1', id, date '2019-03-01', true, 'current'
  from public.membership_grades where code = 'member';
insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status)
select '5f5f1111-0000-0000-0000-000000000003', '01' || (select mmyy from m), id, current_date, true, 'current'
  from public.membership_grades where code = 'member';

delete from public.dynamics_members_seen;
delete from public.legacy_register;
insert into public.legacy_register (membership_number, given_name, family_name, grade, joined_on) values
  ('020615', 'Rick',    'Bobbin',     'Full Member', date '2015-06-12'),
  ('030716', 'Dan',     'Double',     'Fellow',      date '2016-07-01'),
  ('040817', 'Gone',    'Away',       'Associate',   date '2017-08-01'),
  ('050918', 'Steve',   'Testlinked', 'Fellow',      date '2018-09-05'),
  ('03' || to_char(current_date, 'MMYY'), 'Paula', 'Pending', 'Associate', current_date);
insert into public.dynamics_grade_map (category_key, category, grade_id)
select 'zznumfull', 'ZZ Num Full', id from public.membership_grades where code = 'member'
on conflict (category_key) do update set grade_id = excluded.grade_id;
insert into public.dynamics_members_seen (contact_id, given_name, family_name, email, category, person_id) values
  ('nm-1', 'Richard', 'Bobbin', 'richard@num.invalid', 'ZZ Num Full', null),
  ('nm-2', 'Daniel',  'Double', 'daniel@num.invalid',  'ZZ Num Full', null),
  ('nm-3', 'Danny',   'Double', 'danny@num.invalid',   'ZZ Num Full', null),
  ('nm-4', 'Nina',    'Newone', 'nina@num.invalid',    'ZZ Num Full', null),
  ('nm-linked', 'Stephen', 'Testlinked', 'linked@num.invalid', 'ZZ Num Full', '5f5f1111-0000-0000-0000-000000000004');
update public.system_settings set value = 'off' where key = 'dynamics_member_load';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- the numbering
select is(app.given_key('Rick') || '/' || app.given_key('Steve') || '/' || app.given_key('Antony'),
          'richard/stephen/anthony', 'short forms of a first name are brought to one');
select is(app.next_membership_number(current_date), '04' || (select mmyy from m),
          'the next number this month follows the highest used, on the website or the register');
select is(app.next_membership_number(date '2031-02-10'), '010231', 'and a month with none starts at 01');

-- who may ask
select sign_in_as('5f5f0000-0000-0000-0000-000000000002');
select is(public.next_membership_number(), '04' || (select mmyy from m), 'membership staff are offered the next number');
reset role;
select sign_in_as('5f5f0000-0000-0000-0000-000000000003');
select throws_ok($$ select public.next_membership_number() $$, '42501', null, 'a member is not');
select throws_ok($$ select count(*) from public.legacy_register $$, '42501', null, 'and cannot read the register');
reset role;

-- the preview
select sign_in_as('5f5f0000-0000-0000-0000-000000000001');
create temporary table pv (j jsonb) on commit drop;
insert into pv select public.dynamics_members_load(false);
reset role;
select is((select string_agg(x ->> 'number' || ' ' || (x ->> 'name') || ' ' || (x ->> 'how'), ', ' order by x ->> 'name')
             from pv, jsonb_array_elements(j -> 'first') x),
          '04' || (select mmyy from m) || ' Nina Newone new, 020615 Richard Bobbin kept',
          'Rick on the register is Richard in Dynamics and keeps 020615; Nina is new and takes the next number');
select ok((select j -> 'left_out' from pv)::text like '%Daniel Double%2 records in Dynamics match Dan Double (030716)%'
      and (select j -> 'left_out' from pv)::text like '%Danny Double%',
          'two Dynamics records for one register entry are both held back, with the reason');
select is((select string_agg(x ->> 'number', ',') from pv, jsonb_array_elements(j -> 'not_in_dynamics') x),
          '040817,03' || (select mmyy from m), 'register entries Dynamics does not list are reported');
select is((select (x ->> 'from') || ' to ' || (x ->> 'to') from pv, jsonb_array_elements(j -> 'renumbered') x),
          'TEST-NUM-1 to 050918', 'a linked member on a TEST- number is to take their register number');
select is((select count(*)::int from public.members where membership_number in ('020615', '050918')), 0,
          'a preview changes nothing');

-- the load
update public.system_settings set value = 'on' where key = 'dynamics_member_load';
select sign_in_as('5f5f0000-0000-0000-0000-000000000001');
select is((public.dynamics_members_load(true) ->> 'count')::int, 2, 'switched on, the two are created');
reset role;
select is((select m2.joined_on from public.members m2 where m2.membership_number = '020615'), date '2015-06-12',
          'the kept number comes with the joining date from the register');
select ok((select used_by is not null from public.legacy_register where membership_number = '020615')
      and (select used_by is not null from public.legacy_register where membership_number = '050918'),
          'and the register remembers who took each number');
select is((select membership_number || ' ' || joined_on from public.members
            where person_id = '5f5f1111-0000-0000-0000-000000000004'), '050918 2018-09-05',
          'the linked member now has their register number and date');
select sign_in_as('5f5f0000-0000-0000-0000-000000000001');
select is((public.dynamics_members_load(true) ->> 'count')::int, 0, 'running it again creates nobody twice');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 16. Do not load members until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 16 TESTS PASSED' as result;

rollback;
