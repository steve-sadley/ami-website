-- =============================================================================
-- A CPD reminder cannot be switched off, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- 0034 took the switch off both pages and holds the column true with a trigger.
-- Taking a control off a page is not the same as removing the setting, and the
-- whole risk in this change is a member who had already turned the reminder off
-- staying off for ever with nothing on any screen to say why. So the file is
-- mostly about the ROUTES: the profile page writes to the table directly, the
-- unsubscribe page goes through a token function, and "stop everything" goes
-- through another one that calls the first positionally.
--
-- It also proves the trigger does not over-reach. A trigger that quietly held
-- the wrong column true would look exactly like this one working.
--
-- Same discipline as the other nine. Person ids and account ids differ. Every
-- fixture value is prefixed or uses a .invalid address.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(16);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('test-rem-grade', 'TEST Reminder Grade', 'TRG', true, true, true, 94)
on conflict (code) do nothing;

insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-0000000000b1', 'rita.rem@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000b2', 'raj.rem@test.invalid');

insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('e0000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-0000000000b1',
   'Rita','Reminder','rita.rem@test.invalid'),
  ('e0000000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-0000000000b2',
   'Raj','Reminder','raj.rem@test.invalid');

insert into public.members
  (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', true,
       'current'::public.member_status
  from (values
    ('e1b00000-0000-0000-0000-000000000001','e0000000-0000-0000-0000-000000000001','TEST-R-0001'),
    ('e1b00000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000002','TEST-R-0002')
  ) as v(mid, pid, num)
  cross join lateral (select id from public.membership_grades
                       where code = 'test-rem-grade' limit 1) g;

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- anon holds nothing on member_preferences, correctly, but these tests have to
-- hand the token functions a token the way a link in an email would.
create or replace function tok(p_member uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select pr.unsubscribe_token from public.member_preferences pr where pr.member_id = p_member;
$$;


-- =============================================================================
-- 1. A row cannot be CREATED switched off
-- =============================================================================
-- Written as false on purpose. This is the value the old page would have sent.
insert into public.member_preferences (member_id, cpd_reminders, cpd_receipts)
values ('e1b00000-0000-0000-0000-000000000001', false, false),
       ('e1b00000-0000-0000-0000-000000000002', false, true);

select is((select cpd_reminders from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000001'),
          true, 'A row inserted with the reminder off lands with it on');

select is((select cpd_receipts from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000001'),
          true, 'and the receipt lands on too (INVERTED AT 0039: receipts are compulsory as well)');

select is((select cpd_receipts from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000002'),
          true, 'both ways round, so the trigger is not simply forcing everything true');

select is((select cpd_reminders from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000002' ),
          true, 'and the reminder is on for the second member too');


-- =============================================================================
-- 2. A MEMBER cannot switch it off, and the profile page is why this matters
-- =============================================================================
-- The profile page does not call a function. It writes to member_preferences
-- straight, under prefs_update_own, so this is the exact statement a member
-- could type into a browser console. Row level security decides rows and not
-- columns, which is the same lesson 0028 learned about post_nominals.
select sign_in_as('aa000000-0000-0000-0000-0000000000b1');

update public.member_preferences
   set cpd_reminders = false
 where member_id = 'e1b00000-0000-0000-0000-000000000001';

select is((select cpd_reminders from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000001'),
          true, 'A member updating their own row cannot turn the reminder off');

-- And the statement does not RAISE, deliberately, because a member pressing a
-- switch that no longer exists should not be shown an error about it.
select lives_ok($$update public.member_preferences set cpd_reminders = false
                   where member_id = 'e1b00000-0000-0000-0000-000000000001'$$,
                'and is refused silently rather than with an error');

-- The member may still change what IS a preference, or the trigger has taken
-- the whole row hostage rather than one column.
-- CHANGED AT 0039: this used the receipt, which is now held as well. The point
-- it makes is that only the held columns are held, so it uses one that is not.
update public.member_preferences
   set email_events = false
 where member_id = 'e1b00000-0000-0000-0000-000000000001';

select is((select email_events from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000001'),
          false, 'while a real preference still changes, so only the held columns are held');

reset role;


-- =============================================================================
-- 3. The token routes, which are how an email link reaches this
-- =============================================================================
select is(public.set_preferences_by_token(
            tok('e1b00000-0000-0000-0000-000000000001'),
            false, false, false, false, 'off'),
          true, 'The token function accepts the call');

select is((select cpd_reminders from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000001'),
          true, 'and cannot switch the reminder off either');

select is((select email_newsletter from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000001'),
          false, 'while everything it IS allowed to change is changed');

-- Stop everything is the important one. It passes false for every switch, and a
-- member pressing it must get a page saying everything is off rather than an
-- error, which is why the trigger is silent rather than raising.
select is(public.unsubscribe_all_by_token(tok('e1b00000-0000-0000-0000-000000000002')),
          true, 'Stop everything succeeds');

select is((select cpd_reminders from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000002'),
          true, 'and still leaves the reminder on, because it is a notice');

select is((select cpd_receipts from public.member_preferences
            where member_id = 'e1b00000-0000-0000-0000-000000000002'),
          true, 'and the receipt stays on too (INVERTED AT 0039)');


-- =============================================================================
-- 4. Nobody anywhere is left switched off
-- =============================================================================
-- The backfill in 0034 is the half of that migration that would have been
-- forgotten, and it can only be proved by asking the whole table.
select is((select count(*)::int from public.member_preferences
            where cpd_reminders is distinct from true),
          0, 'No row in the table has the reminder off, fixtures and real rows alike');


-- =============================================================================
-- 5. And it reaches the job that actually sends them
-- =============================================================================
-- A column held true that the reminder query no longer consults would look
-- identical to this from the table alone.
select isnt((select count(*)::int from public.member_preferences pr
              join public.members m on m.id = pr.member_id
             where pr.cpd_reminders
               and m.membership_number like 'TEST-R-%'),
            0, 'Both fixtures are visible to a query filtering on the column');

select ok((select count(*)::int from pg_trigger
            where tgrelid = 'public.member_preferences'::regclass
              and tgname  = 'member_preferences_cpd_reminders'
              and not tgisinternal) = 1,
          'The trigger exists by name, so removing it is a deliberate act');


-- -----------------------------------------------------------------------------
-- The verdict
-- -----------------------------------------------------------------------------
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 16. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 16 TESTS PASSED' as result;

rollback;
