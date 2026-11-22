-- =============================================================================
-- 0047, the monthly CPD email, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it, Run without RLS
--
-- What must hold: it goes on the first working day only, once a month, to
-- current members of grades that require CPD and nobody else; staging reaches
-- only the allow list; it lists what the member missed last month (never the
-- ARCA AGM, never before the scheme, never what they attended), with the
-- recording where there is one, and what they can still earn on the site; a
-- name cannot write into it.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(28);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('zz-cpd', 'ZZ TEST CPD grade', 'ZZT', true, false, true, 90),
       ('zz-nocpd', 'ZZ TEST no CPD grade', 'ZZN', false, false, false, 91)
on conflict (code) do nothing;
insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select 2027, id, 5, 5 from public.membership_grades where code in ('zz-cpd', 'zz-nocpd')
on conflict (year, grade_id) do nothing;

insert into auth.users (id, email) values
  ('7f7f0000-0000-0000-0000-000000000001', 'monthly.a@test.invalid'),
  ('7f7f0000-0000-0000-0000-000000000009', 'monthly.office@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('7f7f1111-0000-0000-0000-000000000001','7f7f0000-0000-0000-0000-000000000001','Ann<!--missed--><script>x</script>','Allowed','monthly.a@test.invalid'),
  ('7f7f1111-0000-0000-0000-000000000002', null,'Ben','Heldback','monthly.b@test.invalid'),
  ('7f7f1111-0000-0000-0000-000000000003', null,'Cai','Nocpd','monthly.c@test.invalid'),
  ('7f7f1111-0000-0000-0000-000000000004', null,'Dee','Lapsed','monthly.d@test.invalid'),
  ('7f7f1111-0000-0000-0000-000000000009','7f7f0000-0000-0000-0000-000000000009','Owen','Office','monthly.office@test.invalid');
insert into public.role_grants (person_id, role_code) values ('7f7f1111-0000-0000-0000-000000000009', 'membership');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2021-01-01', v.act, v.st::public.member_status
  from (values
    ('7f7f2222-0000-0000-0000-000000000001','7f7f1111-0000-0000-0000-000000000001','TEST-M-0001','zz-cpd',   true,  'current'),
    ('7f7f2222-0000-0000-0000-000000000002','7f7f1111-0000-0000-0000-000000000002','TEST-M-0002','zz-cpd',   true,  'current'),
    ('7f7f2222-0000-0000-0000-000000000003','7f7f1111-0000-0000-0000-000000000003','TEST-M-0003','zz-nocpd', true,  'current'),
    ('7f7f2222-0000-0000-0000-000000000004','7f7f1111-0000-0000-0000-000000000004','TEST-M-0004','zz-cpd',   false, 'lapsed')
  ) v(mid, pid, num, gc, act, st)
  join public.membership_grades g on g.code = v.gc;

update public.system_settings set value = 'staging' where key = 'environment';
update public.system_settings set value = 'monthly.a@test.invalid' where key = 'bulletin_allow';
update public.system_settings set value = '2027-01-01' where key = 'cpd_feeds_from';

create or replace function type_id(c text) returns uuid language sql as $$
  select id from public.cpd_activity_types where code = c $$;
create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

-- Sessions: two seminars in February (one Ann attended), the ARCA AGM in
-- February, and a seminar in December, before the scheme.
insert into public.zoom_sessions (title, zoom_id, held_on, activity_type_id, event_key) values
  ('ZZ TEST February seminar',  '81234567001', date '2027-02-11', type_id('ami_seminar'), 'zz-test-feb-seminar'),
  ('ZZ TEST attended seminar',  '81234567002', date '2027-02-18', type_id('ami_seminar'), 'zz-test-feb-attended'),
  ('ZZ TEST ARCA AGM',          '81234567003', date '2027-02-25', type_id('arca_agm'),    'zz-test-arca-agm'),
  ('ZZ TEST December seminar',  '81234567004', date '2026-12-10', type_id('ami_seminar'), 'zz-test-dec-seminar');
insert into public.cpd_entries (member_id, year, occurred_on, activity_type_id, title, points, is_core, status, how_recorded, event_key)
values ('7f7f2222-0000-0000-0000-000000000001', 2027, date '2027-02-18', type_id('ami_seminar'),
        'ZZ TEST attended seminar', 3, true, 'pending', 'self_declared', 'zz-test-feb-attended');

-- The February seminar's recording, and a Technical Review Ann has already passed.
insert into public.cpd_learning_items (id, slug, title, kind, activity_type_id, points, vimeo_id, questions, status, event_key, body)
values ('7f7f3333-0000-0000-0000-000000000001', 'zz-test-feb-recording', 'ZZ TEST February seminar recording', 'watch',
        type_id('ami_seminar'), 3, '123456789', '[{"q":"One?","options":["a","b"],"answer":0}]', 'published', 'zz-test-feb-seminar', null),
       ('7f7f3333-0000-0000-0000-000000000002', 'zz-test-review-open', 'ZZ TEST open review', 'read',
        type_id('technical_review'), 1.5, null, '[{"q":"One?","options":["a","b"],"answer":0}]', 'published', null, 'A long enough piece of text to read for the test.'),
       ('7f7f3333-0000-0000-0000-000000000003', 'zz-test-review-done', 'ZZ TEST passed review', 'read',
        type_id('technical_review'), 1, null, '[{"q":"One?","options":["a","b"],"answer":0}]', 'published', null,
        'A long enough piece of text to read for the test.');
insert into public.cpd_learning_attempts (item_id, member_id, answers, correct, total, score, passed)
values ('7f7f3333-0000-0000-0000-000000000003', '7f7f2222-0000-0000-0000-000000000001', '[0]', 1, 1, 100, true);

-- -----------------------------------------------------------------------------
-- 1. When
-- -----------------------------------------------------------------------------
select is(app.first_working_day(date '2027-01-15'), date '2027-01-04',
          'January 2027: the 1st is a bank holiday and the 2nd and 3rd a weekend, so Monday the 4th');
select is(app.first_working_day(date '2027-05-20'), date '2027-05-04',
          'May 2027: Saturday, Sunday, then the early May bank holiday, so Tuesday the 4th');
select is(app.first_working_day(date '2027-03-09'), date '2027-03-01', 'March 2027: Monday the 1st');
select is((app.queue_cpd_monthly(date '2027-03-02') ->> 'sent'), 'false', 'on any other day it sends nothing');
select is((select count(*)::int from public.email_outbox where template_code = 'cpd_monthly'), 0, 'and queues nothing');

-- -----------------------------------------------------------------------------
-- 2. Who
-- -----------------------------------------------------------------------------
create temporary table got (j jsonb) on commit drop;
insert into got select app.queue_cpd_monthly(date '2027-03-01');
select ok((select (j ->> 'queued')::int >= 1 and (j ->> 'withheld')::int >= 1 from got),
          'on the first working day it sends: ' || (select j::text from got));
select is((select count(*)::int from public.email_outbox where template_code = 'cpd_monthly' and to_email = 'monthly.a@test.invalid'), 1,
          'a current member of a grade requiring CPD, on the allow list, gets one');
select is((select count(*)::int from public.email_outbox where to_email = 'monthly.b@test.invalid'), 0,
          'staging holds back one who is not on the allow list');
select is((select outcome from public.cpd_monthly_log where member_id = '7f7f2222-0000-0000-0000-000000000002'), 'withheld',
          'and records that it did');
select is((select count(*)::int from public.email_outbox where to_email = 'monthly.c@test.invalid'), 0,
          'a grade that does not require CPD gets none');
select is((select count(*)::int from public.email_outbox where to_email = 'monthly.d@test.invalid'), 0,
          'nor does a lapsed member');
select is((app.queue_cpd_monthly(date '2027-03-01') ->> 'queued')::int, 0, 'running again the same day sends nobody a second');
select is((app.queue_cpd_monthly(date '2027-03-05', true) ->> 'queued')::int, 0, 'nor does forcing it later in the month');

-- -----------------------------------------------------------------------------
-- 3. What it says
-- -----------------------------------------------------------------------------
create temporary table mail as
  select subject, html from public.email_outbox where template_code = 'cpd_monthly' and to_email = 'monthly.a@test.invalid';
select ok((select subject from mail) like 'Your CPD for 2027%March', 'the subject names the year and the month');
-- 0, not 3: the attended seminar's entry is still pending, and a pending
-- entry does not count until it is accepted. It still counts as attended for
-- the missed list, as it does for "not twice" (0041).
select ok((select html from mail) like '%Core</td><td><b>0 of 5</b> points%', 'it says where they stand, core and non core');
select ok((select html from mail) like '%Last month you missed%ZZ TEST February seminar%',
          'it lists the seminar they missed last month');
select ok((select html from mail) like '%Watch the recording and answer its questions</a> to earn the 3 points%',
          'with the way to earn it from the recording');
select ok((select html from mail) not like '%ZZ TEST attended seminar</b>%', 'but not the one they attended');
select ok((select html from mail) not like '%ZZ TEST ARCA AGM%', 'nor the ARCA AGM, which is never listed as missed');
select ok((select html from mail) like '%Attending the ARCA AGM also earns CPD points%', 'though it says the AGM earns points');
select ok((select html from mail) not like '%December seminar%', 'nor anything before the scheme began');
select ok((select html from mail) like '%ZZ TEST open review, 1.5 points core%', 'it lists what they can still earn on the site');
select ok((select html from mail) not like '%ZZ TEST passed review%', 'but not what they have already passed');
select ok((select html from mail) not like '%<script>%' and (select html from mail) like '%Ann&lt;!--missed--&gt;&lt;script&gt;%',
          'a name cannot write into the email, or into where the lists go');

-- -----------------------------------------------------------------------------
-- 4. The office's preview
-- -----------------------------------------------------------------------------
select sign_in_as('7f7f0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.cpd_monthly_preview('7f7f2222-0000-0000-0000-000000000001') $$,
  '42501', null, 'a member cannot preview anybody''s');
select is((select count(*)::int from public.cpd_monthly_log), 0, 'or read who was sent what');
reset role;
select sign_in_as('7f7f0000-0000-0000-0000-000000000009');
select ok((public.cpd_monthly_preview('7f7f2222-0000-0000-0000-000000000001') ->> 'html') like '%Here is where your CPD stands%',
          'membership staff preview a member''s email as it would be today');
select ok((public.cpd_monthly_preview('7f7f2222-0000-0000-0000-000000000001') ->> 'next') ~ '^\d{4}-\d{2}-\d{2}$',
          'with the date the next one goes');
reset role;

do $$
declare v_failed int := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 28. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 28 TESTS PASSED' as result;

rollback;
