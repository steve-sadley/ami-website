-- =============================================================================
-- 0064, booking the professional interview, proved.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: only membership staff invite; the link is stored only as a
-- hash and a second invitation kills the first; nothing an applicant can do
-- runs from a browser, only through the Worker as the service role; the page
-- offers only open slots outside the notice period; two applicants cannot hold
-- one slot; a hold that is never confirmed lapses; confirming emails both
-- sides and only a Teams address becomes a link; changing a time retires the
-- old booking and hands back its Outlook event; cancelling works outside the
-- notice period and not inside it; the office cancels only with a reason;
-- slots cannot overlap and a booked slot cannot be moved or deleted; and the
-- office's views show staff everything and members nothing.
-- Nothing is kept: it all rolls back.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(44);

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
grant execute on function state_of(text) to authenticated, anon, service_role;

-- What a call returns, as the service role, in one step.
create or replace function svc(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute 'set local role service_role';
  execute p_sql into v;
  execute 'reset role';
  return v;
end $$;

-- The token out of a link.
create or replace function tok(p_link text) returns text language sql as $$
  select substring(p_link from '#t=(.*)$') $$;

-- Person ids and login ids differ on purpose: a person is not a login.
insert into auth.users (id, email) values
  ('64640000-0000-0000-0000-000000000001', 'iv.office@test.invalid'),
  ('64640000-0000-0000-0000-000000000002', 'iv.member@test.invalid'),
  ('64640000-0000-0000-0000-000000000003', 'iv.editor@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('64641111-0000-0000-0000-000000000001', '64640000-0000-0000-0000-000000000001', 'Ora', 'Office', 'iv.office@test.invalid'),
  ('64641111-0000-0000-0000-000000000002', '64640000-0000-0000-0000-000000000002', 'Mel', 'Member', 'iv.member@test.invalid'),
  ('64641111-0000-0000-0000-000000000003', '64640000-0000-0000-0000-000000000003', 'Ed', 'Editor', 'iv.editor@test.invalid');
insert into public.role_grants (person_id, role_code) values
  ('64641111-0000-0000-0000-000000000001', 'membership'),
  ('64641111-0000-0000-0000-000000000003', 'editor');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '64642222-0000-0000-0000-000000000002', '64641111-0000-0000-0000-000000000002', 'TEST-IV-1',
       id, date '2020-01-01', true, 'current' from public.membership_grades where code = 'member';

insert into public.membership_applications (id, reference, given_name, family_name, email, status, submitted_at, grade_id)
select ('64643333-0000-0000-0000-00000000000' || n)::uuid, 'TEST-IV-' || n, 'App' || n, 'Applicant',
       'iv.app' || n || '@test.invalid', s::public.application_status, now(), g.id
  from (values (1, 'submitted'), (2, 'under_review'), (3, 'refused')) v(n, s),
       (select id from public.membership_grades where code = 'member') g;

update public.system_settings set value = 'iv.notify@test.invalid' where key = 'interview_notify';

-- Slots: two open, one too soon, one withdrawn.
insert into public.interview_slots (id, starts_at, note) values
  ('64644444-0000-0000-0000-000000000001', date_trunc('hour', now()) + interval '3 days', 'TEST-IV'),
  ('64644444-0000-0000-0000-000000000002', date_trunc('hour', now()) + interval '4 days', 'TEST-IV'),
  ('64644444-0000-0000-0000-000000000003', date_trunc('hour', now()) + interval '6 hours', 'TEST-IV'),
  ('64644444-0000-0000-0000-000000000004', date_trunc('hour', now()) + interval '5 days', 'TEST-IV');
update public.interview_slots set withdrawn = true where id = '64644444-0000-0000-0000-000000000004';

-- 1. who may invite
select sign_in_as('64640000-0000-0000-0000-000000000002');
select is(state_of($$select public.interview_invite('64643333-0000-0000-0000-000000000001')$$),
          '42501', 'a member cannot invite an applicant to interview');
reset role;
select sign_in_as('64640000-0000-0000-0000-000000000003');
select is(state_of($$select public.interview_invite('64643333-0000-0000-0000-000000000001')$$),
          '42501', 'nor can an editor');
reset role;

-- 2. the office invites
create temp table links (n int, link text);
grant all on links to anon, authenticated, service_role;
select sign_in_as('64640000-0000-0000-0000-000000000001');
insert into links select 1, public.interview_invite('64643333-0000-0000-0000-000000000001') ->> 'link';
insert into links select 2, public.interview_invite('64643333-0000-0000-0000-000000000002') ->> 'link';
select is(state_of($$select public.interview_invite('64643333-0000-0000-0000-000000000003')$$),
          '22023', 'a decided application cannot be invited');
reset role;

select ok((select tok(link) ~ '^[A-Za-z0-9_-]{43}$' from links where n = 1),
          'the link carries a 32 byte token written so it travels in an address');
select ok((select link like '%/interview#t=%' from links where n = 1),
          'the token is after the #, so a browser never sends it to a server');
select is((select token_hash from public.interview_invitations
            where application_id = '64643333-0000-0000-0000-000000000001'),
          (select encode(extensions.digest(tok(link), 'sha256'), 'hex') from links where n = 1),
          'only the SHA-256 of the token is held');
select ok(exists (select 1 from public.email_outbox
                   where template_code = 'interview_invite' and to_email = 'iv.app1@test.invalid'
                     and html like '%' || (select tok(link) from links where n = 1) || '%'),
          'the applicant is emailed the link');
select ok((select html like '%1 hour 15 minutes%' from public.email_outbox
            where template_code = 'interview_invite' and to_email = 'iv.app1@test.invalid'),
          'and told the interview lasts 75 minutes, the default');

-- A second invitation kills the first link.
insert into links values (0, (select link from links where n = 1));
select sign_in_as('64640000-0000-0000-0000-000000000001');
update links set link = public.interview_invite('64643333-0000-0000-0000-000000000001') ->> 'link' where n = 1;
reset role;
select is(state_of(format('select public.interview_page(%L)', (select tok(link) from links where n = 0))),
          'P0002', 'inviting again means the old link is no longer recognised');

-- 3. nothing applicant facing runs from a browser
set local role anon;
select is(state_of(format('select public.interview_page(%L)', (select tok(link) from links where n = 1))),
          '42501', 'a visitor cannot read the booking page directly');
select is(state_of(format('select public.interview_hold(%L, %L)', (select tok(link) from links where n = 1),
                          '64644444-0000-0000-0000-000000000001')),
          '42501', 'nor hold a slot');
select is(state_of($$select * from public.interview_slots$$), '42501', 'nor read the slots');
reset role;
select sign_in_as('64640000-0000-0000-0000-000000000002');
select is(state_of($$select public.interview_confirm('64644444-0000-0000-0000-000000000001', 'x', null)$$),
          '42501', 'a signed in member cannot confirm a booking');
select is(state_of($$select public.interview_release('64644444-0000-0000-0000-000000000001', 'x')$$),
          '42501', 'nor release one');
reset role;

-- 4. the page
select is(state_of($$select svc('select public.interview_page(''short'')')$$),
          '22023', 'a link that is not the right shape is refused in words');
select is((select jsonb_array_length(svc(format('select public.interview_page(%L)', tok(link))) -> 'slots')
             from links where n = 1),
          2, 'the page offers the two open slots, not the one too soon or the withdrawn one');
select is((select svc(format('select public.interview_page(%L)', tok(link))) ->> 'given_name' from links where n = 1),
          'App1', 'and greets the applicant by name');

-- 5. holding
create temp table holds (who int, j jsonb);
grant all on holds to authenticated, service_role;
insert into holds select 1, svc(format('select public.interview_hold(%L, %L)', tok(link), '64644444-0000-0000-0000-000000000001'))
  from links where n = 1;
select is((select j ->> 'email' from holds where who = 1), 'iv.app1@test.invalid',
          'a hold hands the Worker what Outlook needs');
select is((select state_of(format('select svc(%L)', format('select public.interview_hold(%L, %L)', tok(link),
                             '64644444-0000-0000-0000-000000000001'))) from links where n = 2),
          '23505', 'a second applicant cannot hold the same slot');
select is((select state_of(format('select svc(%L)', format('select public.interview_hold(%L, %L)', tok(link),
                             '64644444-0000-0000-0000-000000000003'))) from links where n = 2),
          '22023', 'nor book one inside the notice period');

-- A hold that is never confirmed lapses after five minutes.
update public.interview_bookings set held_at = now() - interval '6 minutes'
 where id = (select (j ->> 'booking')::uuid from holds where who = 1);
select is((select jsonb_array_length(svc(format('select public.interview_page(%L)', tok(link))) -> 'slots')
             from links where n = 2),
          2, 'a hold never confirmed lapses and the slot is offered again');
select is((select status from public.interview_bookings where id = (select (j ->> 'booking')::uuid from holds where who = 1)),
          'expired', 'and is recorded as expired');

-- 6. confirming
delete from holds;
insert into holds select 1, svc(format('select public.interview_hold(%L, %L)', tok(link), '64644444-0000-0000-0000-000000000001'))
  from links where n = 1;
select svc(format('select public.interview_confirm(%L, %L, %L)', (j ->> 'booking'), 'EVT-1',
                  'https://evil.example/join')) from holds where who = 1;
select is((select status || ' ' || coalesce(join_url, 'none') from public.interview_bookings
            where id = (select (j ->> 'booking')::uuid from holds where who = 1)),
          'booked none', 'confirmed, and an address that is not Teams is not kept as the joining link');
select is((select count(*)::int from public.email_outbox where template_code = 'interview_booked'
             and to_email = 'iv.app1@test.invalid'), 1, 'the applicant is emailed');
select is((select count(*)::int from public.email_outbox where template_code = 'interview_booked_office'
             and to_email = 'iv.notify@test.invalid' and reply_to = 'iv.app1@test.invalid'), 1,
          'and so is the office, with Reply-To set to the applicant');
select is((select svc(format('select public.interview_page(%L)', tok(link))) -> 'booking' ->> 'can_change'
             from links where n = 1),
          'true', 'the page shows the booking and that it can still be changed');
select is(state_of(format('select svc(%L)', format('select public.interview_confirm(%L, %L, null)',
                          (select j ->> 'booking' from holds where who = 1), 'EVT-again'))),
          'P0002', 'a booking cannot be confirmed twice');

-- 7. changing the time
insert into holds select 2, svc(format('select public.interview_hold(%L, %L)', tok(link), '64644444-0000-0000-0000-000000000002'))
  from links where n = 1;
select is((select j -> 'previous' ->> 'event_id' from holds where who = 2), 'EVT-1',
          'holding a new time names the Outlook event it will replace');
create temp table conf (j jsonb);
grant all on conf to service_role;
insert into conf select svc(format('select public.interview_confirm(%L, %L, %L)', (j ->> 'booking'), 'EVT-2',
                  'https://teams.microsoft.com/l/meetup-join/test')) from holds where who = 2;
select is((select j ->> 'previous_event_id' from conf), 'EVT-1',
          'confirming it hands back the old event so the Worker can cancel it');
select is((select string_agg(status, ',' order by held_at) from public.interview_bookings
            where application_id = '64643333-0000-0000-0000-000000000001' and status in ('changed', 'booked')),
          'changed,booked', 'the old booking is retired as changed, the new one stands');
select ok(exists (select 1 from public.email_outbox where template_code = 'interview_booked'
              and to_email = 'iv.app1@test.invalid'
              and html like '%This replaces the earlier time%' and html like '%teams.microsoft.com%'),
          'the new email says what it replaces and carries the Teams link');

-- 8. the office's rules on slots
select sign_in_as('64640000-0000-0000-0000-000000000001');
select is(state_of($$insert into public.interview_slots (starts_at) values (date_trunc('hour', now()) + interval '4 days 30 minutes')$$),
          '23P01', 'a slot that overlaps another is refused');
select is(state_of($$update public.interview_slots set starts_at = starts_at + interval '2 hours' where id = '64644444-0000-0000-0000-000000000002'$$),
          '23514', 'a booked slot cannot be moved');
select is(state_of($$delete from public.interview_slots where id = '64644444-0000-0000-0000-000000000001'$$),
          '23514', 'a slot with a booking on its record cannot be deleted');
select is((select ends_at - starts_at from public.interview_slots where id = '64644444-0000-0000-0000-000000000001'),
          interval '75 minutes', 'a slot is 75 minutes unless it says otherwise');
select is((select applicant || ' ' || state from public.admin_interview_slots where id = '64644444-0000-0000-0000-000000000002'),
          'App1 Applicant booked', 'the office sees who is booked into each slot');
select ok((select interview_at is not null and interview_join_url like 'https://teams%' from public.admin_application_queue
            where id = '64643333-0000-0000-0000-000000000001'),
          'and the interview on the application');
select is(state_of($$select public.interview_office_cancel((select id from public.interview_bookings where status = 'booked' and application_id = '64643333-0000-0000-0000-000000000001'), '  ')$$),
          '22023', 'the office cannot cancel without a reason');
reset role;
select sign_in_as('64640000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.admin_interview_slots), 0, 'a member sees no slots at all');
reset role;

-- 9. cancelling
select is((select state_of(format('select svc(%L)', format('select public.interview_cancel(%L)', tok(link)))) from links where n = 1),
          'ok', 'the applicant can cancel outside the notice period');
select is((select count(*)::int from public.email_outbox where template_code in ('interview_cancelled', 'interview_cancelled_office')
             and (to_email = 'iv.app1@test.invalid' or to_email = 'iv.notify@test.invalid')), 2,
          'and both sides are emailed');
select is((select jsonb_array_length(svc(format('select public.interview_page(%L)', tok(link))) -> 'slots')
             from links where n = 2),
          2, 'the cancelled slot is offered again');

-- The second applicant books it, then the time is brought inside the notice
-- period (the trigger is set aside for that one statement, as only a test may).
delete from holds;
insert into holds select 3, svc(format('select public.interview_hold(%L, %L)', tok(link), '64644444-0000-0000-0000-000000000002'))
  from links where n = 2;
select svc(format('select public.interview_confirm(%L, %L, null)', (j ->> 'booking'), 'EVT-3')) from holds where who = 3;
alter table public.interview_slots disable trigger interview_slot_rules;
update public.interview_slots set starts_at = now() + interval '2 hours', ends_at = now() + interval '3 hours 15 minutes' where id = '64644444-0000-0000-0000-000000000002';
alter table public.interview_slots enable trigger interview_slot_rules;
select is((select state_of(format('select svc(%L)', format('select public.interview_cancel(%L)', tok(link)))) from links where n = 2),
          '22023', 'inside the notice period the applicant cannot cancel online');
select sign_in_as('64640000-0000-0000-0000-000000000001');
select is((select public.interview_office_cancel((j ->> 'booking')::uuid, 'Interviewer unwell') ->> 'event_id' from holds where who = 3),
          'EVT-3', 'the office can, with a reason, and is handed the event to cancel in Outlook');
reset role;
select ok(exists (select 1 from public.email_outbox where template_code = 'interview_cancelled'
                   and to_email = 'iv.app2@test.invalid' and html like '%Interviewer unwell%'),
          'and the applicant is told the reason');

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 44. Do not go on until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 44 TESTS PASSED' as result;

rollback;
