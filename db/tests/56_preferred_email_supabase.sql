-- =============================================================================
-- 0061, a work email, a private email and which one AMI writes to, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: everybody starts on their work email; the office can choose
-- private in Edit details, but not when there is no private email, and not a
-- made up value; leaving it out leaves it alone; a letter addressed to a
-- member's work email goes to their private one once that is chosen; a message
-- to some other address is left alone; the suppression list is checked on the
-- address it really goes to; on staging the bulk emails never leave the allow
-- list; on live they follow the choice; the members list shows it to staff
-- only; and the old Edit details function is gone, not left beside the new.
-- Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(18);

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function state_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
grant execute on function state_of(text) to authenticated;

-- where a message went, found by the name it was sent with. Every message in
-- one transaction has the same queued_at, so "the latest" would be a guess.
create or replace function went(p_name text) returns text language sql as $$
  select string_agg(to_email || ' ' || status, ', ') from public.email_outbox where to_name = p_name;
$$;

insert into auth.users (id, email) values
  ('5c5c0000-0000-0000-0000-000000000001', 'pref.office@test.invalid'),
  ('5c5c0000-0000-0000-0000-000000000002', 'pref.member@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email, alt_email) values
  ('5c5c1111-0000-0000-0000-000000000001', '5c5c0000-0000-0000-0000-000000000001', 'Pat', 'Office', 'pref.office@test.invalid', null),
  ('5c5c1111-0000-0000-0000-000000000002', '5c5c0000-0000-0000-0000-000000000002', 'Wren', 'Testpref', 'work@pref.invalid', 'home@pref.invalid'),
  ('5c5c1111-0000-0000-0000-000000000003', null, 'Solo', 'Testpref', 'solo.work@pref.invalid', null);
insert into public.role_grants (person_id, role_code) values
  ('5c5c1111-0000-0000-0000-000000000001', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5c5c2222-0000-0000-0000-000000000002', '5c5c1111-0000-0000-0000-000000000002', 'TEST-PREF-1',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '5c5c2222-0000-0000-0000-000000000003', '5c5c1111-0000-0000-0000-000000000003', 'TEST-PREF-2',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';
update public.system_settings set value = 'staging' where key = 'environment';
update public.system_settings set value = 'work@pref.invalid' where key = 'bulletin_allow';

-- 1. the default
select is((select preferred_email from public.people where id = '5c5c1111-0000-0000-0000-000000000002'),
          'work', 'everybody starts on their work email');
select is(app.contact_email('5c5c1111-0000-0000-0000-000000000002'), 'work@pref.invalid',
          'so that is the one AMI writes to');

-- 2. choosing it
select sign_in_as('5c5c0000-0000-0000-0000-000000000001');
select is(public.update_member_details('5c5c2222-0000-0000-0000-000000000002', 'TEST-PREF-1', date '2020-01-01',
            null, null, 'private') ->> 'contact_email',
          'home@pref.invalid', 'the office chooses private in Edit details');
select is(state_of($$select public.update_member_details('5c5c2222-0000-0000-0000-000000000003', 'TEST-PREF-2',
            date '2020-01-01', null, null, 'private')$$),
          '22023', 'private is refused for a member with no private email');
select is(state_of($$select public.update_member_details('5c5c2222-0000-0000-0000-000000000002', 'TEST-PREF-1',
            date '2020-01-01', null, null, 'carrier pigeon')$$),
          '22023', 'and a made up choice is refused');
select lives_ok($$select public.update_member_details('5c5c2222-0000-0000-0000-000000000002', 'TEST-PREF-1',
            date '2020-01-01', 'Surveyor', null)$$, 'saving without a choice');
reset role;
select is((select preferred_email from public.people where id = '5c5c1111-0000-0000-0000-000000000002'),
          'private', 'leaves the choice as it was');

-- 3. where letters go
select app.queue_system_email('cpd_awarded', 'work@pref.invalid', 'ZZPREF letter', '{}'::jsonb,
                              '5c5c1111-0000-0000-0000-000000000002');
select is(went('ZZPREF letter'), 'home@pref.invalid queued',
          'a letter addressed to their work email goes to the private one they chose');
select app.queue_message('zz_test_other', 's', '<p>h</p>', 'someone.else@pref.invalid', 'ZZPREF other',
                         '5c5c1111-0000-0000-0000-000000000002');
select is(went('ZZPREF other'), 'someone.else@pref.invalid queued',
          'a message to some other address, such as a test bulletin, is left alone');
select app.queue_system_email('cpd_awarded', 'solo.work@pref.invalid', 'ZZPREF solo', '{}'::jsonb,
                              '5c5c1111-0000-0000-0000-000000000003');
select is(went('ZZPREF solo'), 'solo.work@pref.invalid queued',
          'somebody on work stays on work');
insert into public.suppression_list (email, reason) values ('home@pref.invalid', 'test');
select app.queue_system_email('cpd_awarded', 'work@pref.invalid', 'ZZPREF suppressed', '{}'::jsonb,
                              '5c5c1111-0000-0000-0000-000000000002');
select is(went('ZZPREF suppressed'), 'home@pref.invalid suppressed',
          'the suppression list is checked on the address it really goes to');
delete from public.suppression_list where email = 'home@pref.invalid';

-- 4. staging and the allow list
select app.queue_message('bulletin', 's', '<p>h</p>', 'work@pref.invalid', 'ZZPREF bulletin',
                         '5c5c1111-0000-0000-0000-000000000002');
select is(went('ZZPREF bulletin'), 'work@pref.invalid queued',
          'on staging a bulletin stays on the allowed address when the chosen one is not allowed');
update public.system_settings set value = 'work@pref.invalid,home@pref.invalid' where key = 'bulletin_allow';
select app.queue_message('content_digest', 's', '<p>h</p>', 'work@pref.invalid', 'ZZPREF digest',
                         '5c5c1111-0000-0000-0000-000000000002');
select is(went('ZZPREF digest'), 'home@pref.invalid queued',
          'and moves to the chosen one when that is allowed too');
update public.system_settings set value = 'live' where key = 'environment';
update public.system_settings set value = '' where key = 'bulletin_allow';
select app.queue_message('cpd_monthly', 's', '<p>h</p>', 'work@pref.invalid', 'ZZPREF monthly',
                         '5c5c1111-0000-0000-0000-000000000002');
select is(went('ZZPREF monthly'), 'home@pref.invalid queued',
          'on live the monthly CPD email follows the choice');
update public.system_settings set value = 'staging' where key = 'environment';

-- 5. the members list and the old function
select sign_in_as('5c5c0000-0000-0000-0000-000000000001');
select is((select preferred_email || ' ' || contact_email || ' ' || alt_email from public.admin_member_list
            where id = '5c5c2222-0000-0000-0000-000000000002'),
          'private home@pref.invalid home@pref.invalid', 'staff see both emails and which is used');
reset role;
select sign_in_as('5c5c0000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.admin_member_list), 0, 'a member still sees nothing in the list');
reset role;
select ok(to_regprocedure('public.update_member_details(uuid, text, date, text, text)') is null,
          'the five argument Edit details is gone');
select ok(to_regprocedure('public.update_member_details(uuid, text, date, text, text, text)') is not null,
          'and the six argument one is there');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 18. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 18 TESTS PASSED' as result;

rollback;
