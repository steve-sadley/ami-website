-- =============================================================================
-- 0044, a reflection sent with its course certificate earns both.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: one submission makes two pending entries, each valued from
-- its own activity; both or neither; only an external course or a formal
-- qualification can be the certificate half; the pairing cannot be set by hand.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(14);

insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;
insert into auth.users (id, email) values
  ('4c4c0000-0000-0000-0000-000000000001', 'cert.member@test.invalid'),
  ('4c4c0000-0000-0000-0000-000000000009', 'cert.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('4c4c1111-0000-0000-0000-000000000001','4c4c0000-0000-0000-0000-000000000001','Cerys','Cert','cert.member@test.invalid'),
  ('4c4c1111-0000-0000-0000-000000000009','4c4c0000-0000-0000-0000-000000000009','Oscar','Office','cert.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('4c4c1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '4c4c2222-0000-0000-0000-000000000001', '4c4c1111-0000-0000-0000-000000000001', 'TEST-C-0001',
       g.id, date '2021-01-01', true, 'current' from public.membership_grades g where g.code = 'member';
insert into public.member_preferences (member_id) values ('4c4c2222-0000-0000-0000-000000000001');

create or replace function type_id(c text) returns uuid language sql as $$
  select id from public.cpd_activity_types where code = c $$;
create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function words(n int) returns text language sql as $$ select btrim(repeat('removal ', n)) $$;
create temporary table got (j jsonb) on commit drop;
grant all on got to public;

select sign_in_as('4c4c0000-0000-0000-0000-000000000001');
insert into got select public.log_reflection_with_certificate(current_date - 5, type_id('training_reflection'),
  type_id('external_training'), 'ZZ TEST face fit course', 'ZZ TEST trainer', words(510));
reset role;

select is((select count(*)::int from public.cpd_entries where title = 'ZZ TEST face fit course'), 2,
          'one submission logs two entries');
select is((select points from public.cpd_entries where id = (select (j ->> 'reflection_id')::uuid from got)),
          2.0::numeric, 'the reflection at its own value, 2 points');
select is((select points from public.cpd_entries where id = (select (j ->> 'certificate_id')::uuid from got)),
          1.0::numeric, 'the course at its own value, 1 point');
select ok((select bool_and(status = 'pending') from public.cpd_entries where title = 'ZZ TEST face fit course'),
          'both waiting for a person to decide');
select is((select reflection from public.cpd_entries where id = (select (j ->> 'certificate_id')::uuid from got)),
          null, 'the reflection is on the reflection, not on the course');
select ok((select r.paired_entry_id = c.id and c.paired_entry_id = r.id
             from public.cpd_entries r, public.cpd_entries c
            where r.id = (select (j ->> 'reflection_id')::uuid from got)
              and c.id = (select (j ->> 'certificate_id')::uuid from got)),
          'and each points at the other');

select sign_in_as('4c4c0000-0000-0000-0000-000000000009');
select is((select paired_activity from public.admin_cpd_queue where id = (select (j ->> 'reflection_id')::uuid from got)),
          'External training course or seminar', 'the office sees what it came with');
reset role;

select sign_in_as('4c4c0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.log_reflection_with_certificate(current_date - 4, type_id('training_reflection'),
  type_id('external_training'), 'ZZ TEST too short', null, 'Only a few words.') $$,
  '22023', null, 'a reflection that is too short is refused');
reset role;
select is((select count(*)::int from public.cpd_entries where title = 'ZZ TEST too short'), 0,
          'and the course half is not left behind on its own');

select sign_in_as('4c4c0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.log_reflection_with_certificate(current_date - 4, type_id('training_reflection'),
  type_id('self_directed'), 'ZZ TEST wrong half', null, words(510)) $$,
  '22023', null, 'the certificate half can only be an external course or a formal qualification');
select throws_ok($$ select public.log_reflection_with_certificate(current_date - 4, type_id('training_reflection'),
  type_id('arca_training'), 'ZZ TEST ARCA course', null, words(510)) $$,
  '22023', null, 'and not an ARCA course, which arrives from ARCA''s records');
select lives_ok($$ select public.log_reflection_with_certificate(current_date - 4, type_id('training_reflection'),
  type_id('qualification'), 'ZZ TEST NVQ', null, words(510)) $$,
  'a formal qualification is the other choice');
select throws_ok($$ update public.cpd_entries set paired_entry_id = null
                     where title = 'ZZ TEST NVQ' $$,
  '42501', null, 'a member cannot change which entries were logged together');
reset role;
select is((select points from public.cpd_entries where title = 'ZZ TEST NVQ' and reflection is null),
          2.0::numeric, 'and the qualification counts at its own 2 points');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 14. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 14 TESTS PASSED' as result;

rollback;
