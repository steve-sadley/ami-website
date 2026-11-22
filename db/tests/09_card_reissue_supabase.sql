-- =============================================================================
-- Reissuing a membership card, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- This file exists because of a bug that every other suite was blind to.
--
-- 0009 put a unique index on wallet_passes allowing one live pass per member per
-- platform, and an AFTER INSERT trigger to revoke the old one. A unique index is
-- enforced as the row goes in and an AFTER trigger runs once it is already
-- there, so the second card a member ever issued was refused by the index and
-- the trigger never got the chance to make room for it. The first card worked.
-- Every one after it failed with 23505.
--
-- Every fixture in the other suites issued exactly one card, which is the only
-- case that passes. So the whole of this file is about the SECOND time and the
-- THIRD, and about the things that must NOT be revoked when it happens.
--
-- Same discipline as the other eight. Person ids and account ids differ. Every
-- fixture value is prefixed or uses a .invalid address.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(19);

-- -----------------------------------------------------------------------------
-- Fixtures
--
-- Three members. One reissues, one is the bystander whose card must survive it,
-- and one is switched off. A grade requiring no CPD, so nothing here depends on
-- the CPD tables.
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('test-card-grade', 'TEST Card Grade', 'TCG', true, true, false, 96)
on conflict (code) do nothing;

insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-0000000000c1', 'cara.card@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000c2', 'bill.bystander@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000c3', 'olly.off@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000c4', 'nora.nomember@test.invalid');

-- The person id and the account id are deliberately different values. A function
-- that writes auth.uid() where app.person_id() belongs raises 23503, and the
-- suites whose fixtures give a person the same id for both cannot see it.
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('c0000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-0000000000c1',
   'Cara','Cardholder','cara.card@test.invalid'),
  ('c0000000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-0000000000c2',
   'Bill','Bystander','bill.bystander@test.invalid'),
  ('c0000000-0000-0000-0000-000000000003','aa000000-0000-0000-0000-0000000000c3',
   'Olly','Offswitch','olly.off@test.invalid'),
  ('c0000000-0000-0000-0000-000000000004','aa000000-0000-0000-0000-0000000000c4',
   'Nora','Nomember','nora.nomember@test.invalid');

insert into public.members
  (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-06-01',
       v.active, (case when v.active then 'current' else 'lapsed' end)::public.member_status
  from (values
    ('c1b00000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001',
     'TEST-C-0001', true),
    ('c1b00000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-000000000002',
     'TEST-C-0002', true),
    ('c1b00000-0000-0000-0000-000000000003','c0000000-0000-0000-0000-000000000003',
     'TEST-C-0003', false)
  ) as v(mid, pid, num, active)
  cross join lateral (select id from public.membership_grades
                       where code = 'test-card-grade' limit 1) g;

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- Held between calls so a serial can be compared with the one before it.
create temporary table card_run (
  label  text primary key,
  serial text,
  token  text
);
-- The tests switch role as they go, so the holding table has to be reachable
-- from whichever role is signed in. Without this the first switch fails with
-- permission denied and reads like a policy fault.
grant select, insert, update, delete on card_run to public;


-- =============================================================================
-- 1. The first card
-- =============================================================================
select sign_in_as('aa000000-0000-0000-0000-0000000000c1');

insert into card_run (label, serial, token)
select 'first', serial_number, auth_token
  from public.issue_my_card('apple');

select isnt((select serial from card_run where label = 'first'), null,
            'A member with no card can issue one');

select matches((select serial from card_run where label = 'first'), '^AMI-[0-9A-F]{16}$',
               'The serial is generated by the database and has the shape it should');

select is((select count(*)::int from public.wallet_passes
            where member_id = 'c1b00000-0000-0000-0000-000000000001'
              and revoked_at is null),
          1, 'One live pass');

-- Read as the MEMBER. card_issues is FORCE row level security and every policy
-- on it is `to authenticated`, so the owner sees nothing and the assertion would
-- fail while looking exactly like a missing row.
select is((select reason::text from public.card_issues
            where member_id = 'c1b00000-0000-0000-0000-000000000001'),
          'first_issue', 'It is recorded as a first issue');


-- =============================================================================
-- 2. The second card. This is the whole point of the file.
-- =============================================================================
reset role;
select sign_in_as('aa000000-0000-0000-0000-0000000000c1');

insert into card_run (label, serial, token)
select 'second', serial_number, auth_token
  from public.issue_my_card('apple');

select isnt((select serial from card_run where label = 'second'), null,
            'A member who already holds a card can issue another');

select isnt((select serial from card_run where label = 'second'),
            (select serial from card_run where label = 'first'),
            'The new card carries a different serial');

select isnt((select token from card_run where label = 'second'),
            (select token from card_run where label = 'first'),
            'And a different token');

select is((select count(*)::int from public.wallet_passes
            where member_id = 'c1b00000-0000-0000-0000-000000000001'
              and revoked_at is null),
          1, 'There is still exactly one live pass, not two and not none');

select is((select serial_number from public.wallet_passes
            where member_id = 'c1b00000-0000-0000-0000-000000000001'
              and revoked_at is null),
          (select serial from card_run where label = 'second'),
          'And the live one is the new one');

select isnt((select revoked_at from public.wallet_passes
              where serial_number = (select serial from card_run where label = 'first')),
            null, 'The old pass is revoked rather than deleted');

select is((select revoked_reason from public.wallet_passes
            where serial_number = (select serial from card_run where label = 'first')),
          'Superseded by a newer pass',
          'And it says why, so a member asking why their old card stopped can be told');

select is((select count(*)::int from public.card_issues
            where member_id = 'c1b00000-0000-0000-0000-000000000001'
              and reason = 'replacement'),
          1, 'The second is recorded as a replacement, not another first issue');


-- =============================================================================
-- 3. The third, because a fix that works once is not a fix
-- =============================================================================
reset role;
select sign_in_as('aa000000-0000-0000-0000-0000000000c1');

insert into card_run (label, serial, token)
select 'third', serial_number, auth_token
  from public.issue_my_card('apple');

select is((select count(*)::int from public.wallet_passes
            where member_id = 'c1b00000-0000-0000-0000-000000000001'
              and revoked_at is null),
          1, 'A third issue leaves one live pass');

select is((select count(*)::int from public.wallet_passes
            where member_id = 'c1b00000-0000-0000-0000-000000000001'),
          3, 'And three rows in total, because the history is kept');


-- =============================================================================
-- 4. The two platforms are separate
--
-- A member may hold an Apple pass and a Google pass at once. Revoking by member
-- alone rather than by member AND platform would take the other one down, and
-- nothing would raise.
-- =============================================================================
insert into card_run (label, serial, token)
select 'google', serial_number, auth_token
  from public.issue_my_card('google');

select is((select count(*)::int from public.wallet_passes
            where member_id = 'c1b00000-0000-0000-0000-000000000001'
              and revoked_at is null),
          2, 'Issuing a Google pass leaves the Apple one alone');

select throws_ok($$select public.issue_my_card('windows')$$, '22023', null,
                 'A platform AMI does not issue for is refused');


-- =============================================================================
-- 5. What a reissue must NOT touch
-- =============================================================================
reset role;
select sign_in_as('aa000000-0000-0000-0000-0000000000c2');
insert into card_run (label, serial, token)
select 'bystander', serial_number, auth_token
  from public.issue_my_card('apple');

reset role;
select sign_in_as('aa000000-0000-0000-0000-0000000000c1');
select count(*) from public.issue_my_card('apple');

-- Read as the OWNER, not as Cara. wallet_passes is enabled but NOT forced, so
-- the owner sees every row, while Cara is held to passes_select_own and would
-- report nought for Bill's card whether it survived or not. A test that asks as
-- the wrong identity fails while looking exactly like the bug it was written to
-- catch, which is the third time that has happened in this project.
reset role;
select is((select count(*)::int from public.wallet_passes
            where member_id = 'c1b00000-0000-0000-0000-000000000002'
              and revoked_at is null),
          1, 'Another member reissuing does not revoke your card');


-- =============================================================================
-- 6. Who may not issue at all
-- =============================================================================
reset role;
select sign_in_as('aa000000-0000-0000-0000-0000000000c3');
select throws_ok($$select public.issue_my_card('apple')$$, '42501', null,
                 'A membership that has been switched off cannot mint a card');

reset role;
select sign_in_as('aa000000-0000-0000-0000-0000000000c4');
select throws_ok($$select public.issue_my_card('apple')$$, '42501', null,
                 'An account with no membership cannot issue one');

reset role;


-- -----------------------------------------------------------------------------
-- The verdict
-- -----------------------------------------------------------------------------
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 19. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 19 TESTS PASSED' as result;

rollback;
