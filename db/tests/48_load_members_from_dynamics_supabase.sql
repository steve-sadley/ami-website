-- =============================================================================
-- 0056, loading the AMI members from Dynamics, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: the load is locked until the setting is switched on; a
-- preview works regardless and changes nothing; only a super user may do
-- either; it creates each unlinked AMI member once, with a new number in
-- surname order, the mapped grade, active, linked to the contact, and sends
-- nothing; it leaves out, and says why, anybody without an email, a mapped
-- category or a name, or whose email is already on the website.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(14);

insert into auth.users (id, email) values
  ('8e8e0000-0000-0000-0000-000000000001', 'load.super@test.invalid'),
  ('8e8e0000-0000-0000-0000-000000000002', 'load.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('8e8e1111-0000-0000-0000-000000000001', '8e8e0000-0000-0000-0000-000000000001', 'Sue', 'Super', 'load.super@test.invalid'),
  ('8e8e1111-0000-0000-0000-000000000002', '8e8e0000-0000-0000-0000-000000000002', 'Olly', 'Office', 'load.office@test.invalid'),
  ('8e8e1111-0000-0000-0000-000000000003', null, 'Already', 'Here', 'already@test.invalid');
insert into public.role_grants (person_id, role_code) values
  ('8e8e1111-0000-0000-0000-000000000001', 'super_user'),
  ('8e8e1111-0000-0000-0000-000000000002', 'membership');

delete from public.dynamics_members_seen;
insert into public.dynamics_grade_map (category_key, category, grade_id)
select 'zzloadfellow', 'ZZ Load Fellow', id from public.membership_grades where code = 'fellow'
on conflict (category_key) do update set grade_id = excluded.grade_id;
insert into public.dynamics_grade_map (category_key, category, grade_id)
values ('zzloadmystery', 'ZZ Load Mystery', null) on conflict (category_key) do update set grade_id = null;
insert into public.dynamics_members_seen (contact_id, given_name, family_name, email, email2, category) values
  ('ld-1', 'Zoe',   'Zebra',   'zoe@load.invalid',  'zoe@home.invalid', 'ZZ Load Fellow'),
  ('ld-2', 'Adam',  'Aardvark','adam@load.invalid', null,               'ZZ Load Fellow'),
  ('ld-3', 'Myra',  'Mystery', 'myra@load.invalid', null,               'ZZ Load Mystery'),
  ('ld-4', 'Nemo',  'Noemail', null,                null,               'ZZ Load Fellow'),
  ('ld-5', 'Al',    'Ready',   'already@test.invalid', null,            'ZZ Load Fellow');
insert into public.members (person_id, membership_number, grade_id, joined_on, is_active, status)
select '8e8e1111-0000-0000-0000-000000000003', 'ZZL-0001', id, date '2020-01-01', true, 'current'
  from public.membership_grades where code = 'member';
update public.system_settings set value = 'off' where key = 'dynamics_member_load';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

select sign_in_as('8e8e0000-0000-0000-0000-000000000002');
select throws_ok($$ select public.dynamics_members_load(false) $$, '42501', null,
  'membership staff cannot load members, or even preview it');
reset role;

select sign_in_as('8e8e0000-0000-0000-0000-000000000001');
create temporary table pv (j jsonb) on commit drop;
insert into pv select public.dynamics_members_load(false);
select is((select (j ->> 'count')::int from pv), 2, 'a super user previews: two would be created');
select is((select j -> 'first' -> 0 ->> 'number' || ' ' || (j -> 'first' -> 0 ->> 'name') from pv),
          app.next_membership_number(current_date) || ' Adam Aardvark',
          'in surname order, numbered as the next admission this month (0058)');
select is((select jsonb_array_length(j -> 'left_out') from pv), 3, 'and three are left out');
select ok((select j -> 'left_out' from pv)::text like '%not mapped to a grade%'
      and (select j -> 'left_out' from pv)::text like '%No email in Dynamics%'
      and (select j -> 'left_out' from pv)::text like '%the sync will link them%', 'each with the reason');
select is((select count(*)::int from public.members m join public.people p on p.id = m.person_id
            where p.email like '%@load.invalid'), 0, 'a preview creates nobody');
select throws_ok($$ select public.dynamics_members_load(true) $$, '42501', null,
  'and the load itself is locked while the setting is off');
reset role;

update public.system_settings set value = 'on' where key = 'dynamics_member_load';
create temporary table q (n int) on commit drop;
create temporary table nx (adam text, zoe text) on commit drop;
insert into nx select app.next_membership_number(current_date),
  lpad((left(app.next_membership_number(current_date), 2)::int + 1)::text, 2, '0') || to_char(current_date, 'MMYY');
insert into q select count(*) from public.email_outbox;
select sign_in_as('8e8e0000-0000-0000-0000-000000000001');
select is((public.dynamics_members_load(true) ->> 'count')::int, 2, 'switched on, the two are created');
reset role;
select is((select m.membership_number from public.members m join public.people p on p.id = m.person_id where p.email = 'zoe@load.invalid'),
          (select zoe from nx), 'Zebra after Aardvark, with the next number');
select is((select g.code || '/' || m.is_active || '/' || m.status from public.members m join public.people p on p.id = m.person_id
             join public.membership_grades g on g.id = m.grade_id where p.email = 'adam@load.invalid'),
          'fellow/true/current', 'with the mapped grade, active and current');
select is((select dynamics_contact_id || '/' || alt_email from public.people where email = 'zoe@load.invalid'), 'ld-1/zoe@home.invalid',
          'linked to the contact, with the second email');
select is((select count(*)::int from public.member_preferences mp join public.members m on m.id = mp.member_id
            join public.people p on p.id = m.person_id where p.email like '%@load.invalid'), 2,
          'each with their preferences, as any member has');
select is((select count(*)::int from public.email_outbox), (select n from q), 'and nobody is sent anything');
select sign_in_as('8e8e0000-0000-0000-0000-000000000001');
select is((public.dynamics_members_load(true) ->> 'count')::int, 0, 'running it again creates nobody twice');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 14. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 14 TESTS PASSED' as result;

rollback;
