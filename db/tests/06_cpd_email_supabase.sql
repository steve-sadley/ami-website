-- =============================================================================
-- The CPD emails, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it
--
-- 0029 does something the schema has never done before: it queues a message when
-- nobody pressed a button. A trigger fired by a member and a cron job fired by a
-- clock both reach the outbox, and both arrive with an auth.uid() that 0027's
-- queue_email would refuse. The function that lets them through,
-- app.queue_system_email, has no check inside it at all and is restrained only by
-- its GRANT.
--
-- So the first group below is not about CPD. It is about that grant, and it is
-- the reason this file exists. If a signed in member can reach
-- app.queue_system_email then any member can send mail from AMI's own domain to
-- any address they like, and nothing anywhere would look wrong.
--
-- Six groups:
--
--   the grants, which are the only lock on the system queue
--   rendering, which 0027 paid for and 0029 pulled apart
--   review_cpd, which must send ONE letter per member and not one per entry
--   the logging receipt, which is off unless asked for
--   the reminders, which must not send twice and must stop when the year is met
--   the preference page, which works without a sign in and cannot switch off a
--     decision about somebody's own record
--
-- Same discipline as the other five. A person and an account are given DIFFERENT
-- ids on purpose, which is what test 05 introduced and what found the foreign key
-- bug in refuse_application. Every fixture value is prefixed or uses a .invalid
-- address, so the file runs on staging where real rows already exist.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(50);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
-- Two grades. One requires CPD and has a real target; one requires CPD and has a
-- target of zero, which is how 0007 modelled Associate on purpose, so that a
-- report can say an Associate met the requirement rather than having nothing to
-- say. The reminder must exclude the second by arithmetic and not by name.
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values
  ('test-cpd-grade',   'TEST CPD Grade',    'TCPD', true, true, true, 91),
  ('test-nocpd-grade', 'TEST No CPD Grade', 'TNCP', true, true, true, 92)
on conflict (code) do nothing;

insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select extract(year from current_date)::int, g.id,
       case when g.code = 'test-cpd-grade' then 5 else 0 end,
       case when g.code = 'test-cpd-grade' then 5 else 0 end
  from public.membership_grades g
 where g.code in ('test-cpd-grade', 'test-nocpd-grade')
on conflict (year, grade_id) do nothing;

insert into public.cpd_activity_types (code, name, is_core, sort_order, active, points, member_can_log) values
  ('test-core-type',     'TEST core activity',     true,  91, true, 2, true),
  ('test-non-core-type', 'TEST non core activity', false, 92, true, 2, true)
on conflict (code) do nothing;

-- A PERSON IS NOT A LOGIN. The person ids and the account ids below are
-- deliberately different, and sign_in_as is called with the ACCOUNT id, which is
-- what a real session carries. Test 05 introduced this and it is the only reason
-- 0027's foreign key bug was found. Copying it here is not decoration.
insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-0000000000f1', 'olive.cpd@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000f2', 'ada.cpd@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000f3', 'cara.cpd@test.invalid');

insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('f0000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-0000000000f1',
   'Olive','Cpdstaff','olive.cpd@test.invalid'),
  ('f0000000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-0000000000f2',
   'Ada','Cpdshort','ada.cpd@test.invalid'),
  ('f0000000-0000-0000-0000-000000000003','aa000000-0000-0000-0000-0000000000f3',
   'Cara','Cpdreceipt','cara.cpd@test.invalid'),
  ('f0000000-0000-0000-0000-000000000004', null,
   'Bea','Cpdmet','bea.cpd@test.invalid'),
  ('f0000000-0000-0000-0000-000000000005', null,
   'Dee','Cpdquiet','dee.cpd@test.invalid'),
  ('f0000000-0000-0000-0000-000000000006', null,
   'Frank','Cpdnone','frank.cpd@test.invalid'),
  ('f0000000-0000-0000-0000-000000000007', null,
   'Gus','Cpdlapsed','gus.cpd@test.invalid'),
  ('f0000000-0000-0000-0000-000000000008', null,
   'Hana','Cpdbounce','hana.cpd@test.invalid');

insert into public.role_grants (person_id, role_code)
values ('f0000000-0000-0000-0000-000000000001', 'membership');

insert into public.members
  (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2020-01-01', v.active, 'current'
  from (values
    ('f1b00000-0000-0000-0000-000000000002','f0000000-0000-0000-0000-000000000002','TEST-F-0002','test-cpd-grade',   true),
    ('f1b00000-0000-0000-0000-000000000003','f0000000-0000-0000-0000-000000000003','TEST-F-0003','test-cpd-grade',   true),
    ('f1b00000-0000-0000-0000-000000000004','f0000000-0000-0000-0000-000000000004','TEST-F-0004','test-cpd-grade',   true),
    ('f1b00000-0000-0000-0000-000000000005','f0000000-0000-0000-0000-000000000005','TEST-F-0005','test-cpd-grade',   true),
    ('f1b00000-0000-0000-0000-000000000006','f0000000-0000-0000-0000-000000000006','TEST-F-0006','test-nocpd-grade', true),
    ('f1b00000-0000-0000-0000-000000000007','f0000000-0000-0000-0000-000000000007','TEST-F-0007','test-cpd-grade',   false),
    ('f1b00000-0000-0000-0000-000000000008','f0000000-0000-0000-0000-000000000008','TEST-F-0008','test-cpd-grade',   true)
  ) as v(mid, pid, num, grade, active)
  join public.membership_grades g on g.code = v.grade;

insert into public.suppression_list (email, reason)
values ('hana.cpd@test.invalid', 'TEST hard bounce')
on conflict (email) do nothing;

-- Bea meets the requirement. The entries are dated old on purpose: recorded_at
-- defaults to now(), and the reminder's 30 day softener reads that column, so
-- fixtures written today would silently exclude everybody from every reminder
-- test and every one of them would pass for the wrong reason.
insert into public.cpd_entries
  (member_id, year, occurred_on, activity_type_id, title, points, is_core,
   how_recorded, status, reviewed_by, reviewed_at, recorded_at)
select 'f1b00000-0000-0000-0000-000000000004',
       extract(year from current_date)::int,
       date_trunc('year', current_date)::date + 10,
       t.id, 'TEST Bea ' || t.code, 5, t.is_core,
       'awarded_by_ami', 'accepted',
       'f0000000-0000-0000-0000-000000000001', now(), now() - interval '200 days'
  from public.cpd_activity_types t
 where t.code in ('test-core-type', 'test-non-core-type');

-- Three pending entries for Ada and one for Cara, so a single call to review_cpd
-- can span two members and prove it sends two letters and not four.
insert into public.cpd_entries
  (id, member_id, year, occurred_on, activity_type_id, title, points, is_core,
   how_recorded, status, recorded_at)
select v.id::uuid, v.mid::uuid,
       extract(year from current_date)::int,
       date_trunc('year', current_date)::date + 20,
       t.id, v.title, 1, t.is_core, 'self_declared', 'pending',
       now() - interval '200 days'
  from (values
    ('f2000000-0000-0000-0000-000000000001','f1b00000-0000-0000-0000-000000000002','TEST Ada alpha','test-core-type'),
    ('f2000000-0000-0000-0000-000000000002','f1b00000-0000-0000-0000-000000000002','TEST Ada bravo','test-core-type'),
    ('f2000000-0000-0000-0000-000000000003','f1b00000-0000-0000-0000-000000000002','TEST Ada charlie','test-non-core-type'),
    ('f2000000-0000-0000-0000-000000000004','f1b00000-0000-0000-0000-000000000003','TEST Cara delta','test-core-type'),
    ('f2000000-0000-0000-0000-000000000005','f1b00000-0000-0000-0000-000000000002','TEST Ada echo','test-non-core-type')
  ) as v(id, mid, title, code)
  join public.cpd_activity_types t on t.code = v.code;

-- THE PREFERENCES GO IN LAST, AND THAT IS NOT TIDINESS. The receipt trigger
-- looks for a member_preferences row and returns early when there is not one, so
-- fixtures written before this block queue nothing. Written the other way round,
-- Cara's pending fixture entry queues her a receipt during setup, every count
-- below is one too high, and the failure looks like a bug in the trigger.
insert into public.member_preferences (member_id, cpd_reminders, cpd_receipts)
values
  ('f1b00000-0000-0000-0000-000000000002', true,  false),  -- Ada, the default
  ('f1b00000-0000-0000-0000-000000000003', true,  true),   -- Cara asked for receipts
  ('f1b00000-0000-0000-0000-000000000004', true,  false),  -- Bea will meet the target
  -- Dee TRIES to switch reminders off. 0034 holds the column true with a
  -- trigger, so this row lands as true and Dee is reminded like everybody
  -- else. Left as false on purpose: it is what the page used to allow and
  -- what a member could still attempt from a browser console.
  ('f1b00000-0000-0000-0000-000000000005', false, false),  -- Dee, refused by 0034
  ('f1b00000-0000-0000-0000-000000000006', true,  false),  -- Frank, zero requirement
  ('f1b00000-0000-0000-0000-000000000007', true,  false),  -- Gus, not active
  ('f1b00000-0000-0000-0000-000000000008', true,  false);  -- Hana, bounced address


create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function try_dml(p_sql text) returns void language plpgsql as $$
begin execute p_sql; end $$;

-- anon holds nothing on member_preferences, and correctly so, but the tests below
-- have to hand it a token the way a link in an email would. SECURITY DEFINER, and
-- it exists only inside this transaction.
create or replace function tok(p_member uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select pr.unsubscribe_token from public.member_preferences pr where pr.member_id = p_member;
$$;


-- =============================================================================
-- 1. The grants, which are the only lock on the system queue
-- =============================================================================
-- app.queue_system_email asks nothing about who is calling. It cannot: the two
-- things that need it are a trigger fired by a member and a job fired by a clock.
-- So the grant is the entire defence, and these four are the test that matters
-- most in this file. If any of them starts passing for a different reason, or
-- gets deleted as noise, a member can send mail from AMI's domain to anybody.
select sign_in_as('aa000000-0000-0000-0000-0000000000f2');

select throws_ok(
  $$select app.queue_system_email('cpd_reminder', 'attacker@test.invalid', 'A',
      '{}'::jsonb)$$,
  '42501',
  null,
  'An ordinary member cannot execute app.queue_system_email');

select throws_ok(
  $$select app.queue_message('x', 's', '<p>h</p>', 'attacker@test.invalid', 'A')$$,
  '42501',
  null,
  'and cannot reach app.queue_message underneath it either');

-- 0027's rule, re-asserted because 0029 retyped the body of queue_email. A
-- function whose insides changed is a function whose permissions are worth
-- proving again, and this is the third time in this project that a rewrite has
-- quietly moved a check.
select throws_ok(
  $$select app.queue_email('cpd_reminder', 'attacker@test.invalid', 'A', '{}'::jsonb)$$,
  '42501',
  'Only membership staff may queue an email from AMI.',
  'app.queue_email still refuses a member, with the same words as before');

select throws_ok(
  $$select app.queue_cpd_reminders(current_date)$$,
  '42501',
  null,
  'and a member cannot run the reminder job');
reset role;

select throws_ok(
  $$set local role anon; select app.queue_system_email('cpd_reminder',
      'attacker@test.invalid', 'A', '{}'::jsonb)$$,
  '42501',
  null,
  'anon cannot execute app.queue_system_email');
reset role;


-- =============================================================================
-- 2. Rendering, pulled apart and still obeying every rule it obeyed before
-- =============================================================================
select is((select html from app.render_parts('s', '<p>{{v}}</p>',
            '{"v":"<script>alert(1)</script>"}'::jsonb)),
          '<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>',
          'A value is escaped on its way into the body and cannot become an element');

select is((select subject from app.render_parts('Hello {{v}}', 'h',
            '{"v":"O''Brien & Sons"}'::jsonb)),
          'Hello O''Brien & Sons',
          'A subject line takes the value as typed, because a subject is not HTML');

select is((select subject from app.render_parts(E'A {{v}} B', 'h',
            '{"v":"one\ntwo"}'::jsonb)),
          'A one two B',
          'and a line break in a value never reaches a header');

select is((select html from app.render_parts('s', '<p>{{a}}</p>',
            '{"a":"see {{b}}","b":"SECRET"}'::jsonb)),
          '<p>see b</p>',
          'A value carrying braces cannot interpolate another placeholder');

select is((select html from app.render_parts('s', '<p>{{missing}}</p>', '{}'::jsonb)),
          '<p></p>',
          'A placeholder nobody supplied becomes nothing, not the literal braces');

select ok((select is_service from app.render_email('cpd_reminder', '{}'::jsonb)),
          'app.render_email still reports is_service, which 0027 callers rely on');


-- =============================================================================
-- 3. review_cpd sends ONE letter per member, not one per entry
-- =============================================================================
-- The whole reason this is worth a group of its own: 0020 built review_cpd to
-- clear a queue of forty in one transaction, and forty entries can belong to a
-- dozen people. One message per entry would send somebody four emails in a
-- second.
select sign_in_as('aa000000-0000-0000-0000-0000000000f1');

select is(public.review_cpd(array[
            'f2000000-0000-0000-0000-000000000001',
            'f2000000-0000-0000-0000-000000000002',
            'f2000000-0000-0000-0000-000000000003',
            'f2000000-0000-0000-0000-000000000004']::uuid[], 'accepted'),
          4,
          'Accepting four entries returns four, which is the count the admin app reads');

select is((select count(*)::int from public.email_outbox
            where to_email = 'ada.cpd@test.invalid'),
          1, 'and Ada gets ONE letter for her three entries, not three');

select is((select count(*)::int from public.email_outbox
            where to_email = 'cara.cpd@test.invalid'
              and template_code = 'cpd_accepted'),
          1, 'and Cara, in the same press, gets one of her own');

select ok((select html like '%TEST Ada alpha%'
             and html like '%TEST Ada bravo%'
             and html like '%TEST Ada charlie%'
             from public.email_outbox where to_email = 'ada.cpd@test.invalid'),
          'and that one letter names all three of her entries');

-- The summary trigger from 0007 fires per row DURING the update statement, so by
-- the time the letter is built the totals already include this decision. Reading
-- them first would have sent everybody yesterday's position, which is the kind of
-- wrong that looks right.
select ok((select html like '%2 of 5%' from public.email_outbox
            where to_email = 'ada.cpd@test.invalid'),
          'the letter reports the position AFTER the decision, not before it');

select ok((select html !~ '\{\{' from public.email_outbox
            where to_email = 'ada.cpd@test.invalid'),
          'and no placeholder is left unfilled anywhere in it');

select is((select template_code from public.email_outbox
            where to_email = 'ada.cpd@test.invalid'),
          'cpd_accepted', 'it is the acceptance template');

-- Rejection. The reason a member of staff typed is the reason the member reads.
select is(public.review_cpd(array['f2000000-0000-0000-0000-000000000005']::uuid[],
            'rejected', 'TEST no evidence was attached to this one.'),
          1, 'Rejecting one entry returns one');

select is((select count(*)::int from public.email_outbox
            where to_email = 'ada.cpd@test.invalid'
              and template_code = 'cpd_rejected'),
          1, 'and queues exactly one refusal letter');

select ok((select html like '%TEST no evidence was attached to this one.%'
             from public.email_outbox
            where to_email = 'ada.cpd@test.invalid' and template_code = 'cpd_rejected'),
          'carrying the reason that was typed, word for word');

-- 0020's rule, preserved through the rewrite. Without it a member could be told
-- their entry was refused and given no reason at all.
select throws_ok(
  $$select public.review_cpd(array['f2000000-0000-0000-0000-000000000001']::uuid[],
      'rejected', '   ')$$,
  'A rejection needs a reason. The member is told what it says.',
  'A rejection with no reason still raises');

select is(public.review_cpd(array['f2000000-0000-0000-0000-000000000001']::uuid[],
            'accepted'),
          0, 'An entry that is no longer pending is skipped rather than re-decided');

select is((select count(*)::int from public.email_outbox
            where to_email = 'ada.cpd@test.invalid'),
          2, 'and skipping it queues nothing, so nobody is told twice');
reset role;

select sign_in_as('aa000000-0000-0000-0000-0000000000f2');
select throws_ok(
  $$select public.review_cpd(array['f2000000-0000-0000-0000-000000000001']::uuid[],
      'accepted')$$,
  '42501',
  'Only membership staff may review CPD.',
  'An ordinary member cannot review CPD, and so cannot make AMI send a letter');
reset role;


-- =============================================================================
-- 4. The logging receipt, off unless asked for
-- =============================================================================
-- Ada has receipts off, which is the default, and Cara asked for them.
-- Ada's entry is inserted directly, with an old recorded_at, rather than through
-- log_cpd. log_cpd stamps recorded_at with now(), and the reminder's 30 day
-- softener reads that column, so logging as Ada here would quietly take her out
-- of every reminder test below and all of them would pass for the wrong reason.
-- The receipt is a TRIGGER, so a direct insert exercises it either way.
insert into public.cpd_entries
  (member_id, year, occurred_on, activity_type_id, title, points, is_core,
   how_recorded, status, recorded_at)
select 'f1b00000-0000-0000-0000-000000000002',
       extract(year from current_date)::int, current_date - 1,
       t.id, 'TEST Ada logged something', 1, t.is_core, 'self_declared', 'pending',
       now() - interval '200 days'
  from public.cpd_activity_types t where t.code = 'test-core-type';

-- INVERTED AT 0039, 30 October 2026. This asserted that a member with receipts
-- off got nothing. Receipts can no longer be switched off: Ada's row was written
-- with them off and the trigger turned them on, so she gets one like everybody.
select is((select count(*)::int from public.email_outbox
            where to_email = 'ada.cpd@test.invalid' and template_code = 'cpd_logged'),
          1, 'A member gets a receipt whatever their row said, because it cannot be switched off');

select sign_in_as('aa000000-0000-0000-0000-0000000000f3');
select public.log_cpd(current_date - 1,
       (select id from public.cpd_activity_types where code = 'test-core-type'),
       'TEST Cara <script>alert(1)</script> logged');
reset role;

select is((select count(*)::int from public.email_outbox
            where to_email = 'cara.cpd@test.invalid' and template_code = 'cpd_logged'),
          1, 'A member who asked for a receipt gets exactly one');

select ok((select html like '%waiting to be reviewed%' from public.email_outbox
            where to_email = 'cara.cpd@test.invalid' and template_code = 'cpd_logged'),
          'and it says the entry is waiting, because nothing counts until it is accepted');

-- The member typed this themselves and it goes into an HTML body. A receipt is
-- the shortest path from a member's keyboard to their own inbox.
select ok((select html not like '%<script>%'
             and html like '%&lt;script&gt;%'
             from public.email_outbox
            where to_email = 'cara.cpd@test.invalid' and template_code = 'cpd_logged'),
          'and a script tag in the title survives as words rather than as an element');

-- An entry awarded by AMI is accepted already, so a receipt saying it is waiting
-- to be reviewed would be plainly untrue.
insert into public.cpd_entries
  (member_id, year, occurred_on, activity_type_id, title, points, is_core,
   how_recorded, status, reviewed_by, reviewed_at)
select 'f1b00000-0000-0000-0000-000000000003',
       extract(year from current_date)::int, current_date - 2,
       t.id, 'TEST Cara awarded', 1, t.is_core, 'awarded_by_ami', 'accepted',
       'f0000000-0000-0000-0000-000000000001', now()
  from public.cpd_activity_types t where t.code = 'test-core-type';

select is((select count(*)::int from public.email_outbox
            where to_email = 'cara.cpd@test.invalid' and template_code = 'cpd_logged'),
          1, 'An entry AWARDED by AMI queues no receipt, because it is not waiting');


-- =============================================================================
-- 5. The reminders
-- =============================================================================
-- Every call below passes an explicit date, because the answer depends on the
-- month and a test that only runs correctly in November is a test nobody runs.
select is(app.queue_cpd_reminders(
            make_date(extract(year from current_date)::int, 6, 15)),
          0, 'Nothing goes out before July');

select is((select count(*)::int from public.cpd_reminder_log
            where month = 6 and year = extract(year from current_date)::int
              and member_id::text like 'f1b00000%'),
          0, 'and nothing is written down either, so July is not blocked by June');

select ok(app.queue_cpd_reminders(
            make_date(extract(year from current_date)::int, 7, 15)) >= 1,
          'In July, at least one reminder is queued');

select is((select count(*)::int from public.email_outbox
            where to_email = 'ada.cpd@test.invalid' and template_code = 'cpd_reminder'),
          1, 'Ada, who is short of the target, gets one');

select is((select count(*)::int from public.email_outbox
            where to_email = 'bea.cpd@test.invalid'),
          0, 'Bea, who has met the requirement, gets none and nobody switched anything off');

select is((select count(*)::int from public.email_outbox
            where to_email = 'dee.cpd@test.invalid'),
          -- INVERTED AT 0034, 23 August 2026. This asserted 0, because a CPD
          -- reminder was a preference and Dee had turned it off. Steve decided
          -- it is a notice about the member's own standing rather than a
          -- mailing, so it cannot be turned off and Dee gets one. The test is
          -- inverted in place rather than deleted, so the file records that a
          -- decision moved rather than that a rule quietly stopped existing.
          1, 'Dee, who tried to switch reminders off, is reminded anyway');

select is((select count(*)::int from public.email_outbox
            where to_email = 'gus.cpd@test.invalid'),
          0, 'Gus, whose membership is not active, gets none');

-- Frank's grade requires CPD and its requirement is zero, which is exactly how
-- 0007 modelled Associate. He must be excluded by the arithmetic rather than by
-- anything naming a grade, or a grade added next year is handled by accident.
select is((select count(*)::int from public.email_outbox
            where to_email = 'frank.cpd@test.invalid'),
          0, 'Frank, whose grade has a requirement of zero, gets none');

-- 0027's rule: recorded rather than skipped. A bounced address that is quietly
-- filtered out disappears; one that is queued and marked says so every month,
-- with the reason beside it, in the queue the office reads.
select is((select status from public.email_outbox
            where to_email = 'hana.cpd@test.invalid' and template_code = 'cpd_reminder'),
          'suppressed',
          'Hana''s bounced address is queued and MARKED suppressed, not skipped');

-- WHAT THIS PROVES AND WHAT IT DOES NOT. It proves the job is repeatable: run it
-- again in the same month and nobody gets a second letter. It does NOT prove the
-- race is closed, because a single session cannot run two drains at once. The
-- race is closed by writing the log row FIRST and queueing only if the insert
-- inserted, so the primary key decides rather than a WHERE clause that two
-- concurrent runs both read as false. A version with the two statements the
-- other way round passes this test and would still double up under pg_cron.
-- That is worth knowing before anybody reorders them for readability.
select is(app.queue_cpd_reminders(
            make_date(extract(year from current_date)::int, 7, 20)),
          0, 'Running the job again in the same month queues nothing');

select is((select count(*)::int from public.email_outbox
            where to_email = 'ada.cpd@test.invalid' and template_code = 'cpd_reminder'),
          1, 'and Ada still has exactly one, not two');

select ok(app.queue_cpd_reminders(
            make_date(extract(year from current_date)::int, 8, 15)) >= 1,
          'The next month starts a new one');

-- NOT "order by queued_at desc limit 1". queued_at defaults to now(), which is
-- the TRANSACTION timestamp, so every row queued inside this test carries the
-- same value and the ordering picks an arbitrary one. The context column records
-- which month queued it, so the test asks that instead. This is the same trap
-- that put an identity column on forum_posts.
select ok((select html like '%month%' from public.email_outbox
            where to_email = 'ada.cpd@test.invalid' and template_code = 'cpd_reminder'
              and context ->> 'month' = '8'),
          'and the August letter says how much of the year is left');

-- The softener. Somebody who logged something last week is using the scheme and
-- does not need chasing, and chasing them is how a reminder becomes junk.
select is((select count(*)::int from public.email_outbox
            where to_email = 'cara.cpd@test.invalid' and template_code = 'cpd_reminder'),
          0, 'Cara logged an entry today, so the 30 day softener leaves her alone');

select ok(app.queue_cpd_reminders(
            make_date(extract(year from current_date)::int, 9, 15), 0) >= 1,
          'Passing zero quiet days switches the softener off');

select is((select count(*)::int from public.email_outbox
            where to_email = 'cara.cpd@test.invalid' and template_code = 'cpd_reminder'),
          1, 'and then Cara is included after all');

select ok(app.queue_cpd_reminders(
            make_date(extract(year from current_date)::int, 12, 1), 0) >= 1,
          'December queues a reminder like any other month from July');

select ok((select html like '%last month of the CPD year%'
             from public.email_outbox
            where to_email = 'ada.cpd@test.invalid' and template_code = 'cpd_reminder'
              and context ->> 'month' = '12'),
          'and says it is the last month rather than counting down to zero months left');

select sign_in_as('aa000000-0000-0000-0000-0000000000f2');
select is((select count(*)::int from public.cpd_reminder_log
            where member_id = 'f1b00000-0000-0000-0000-000000000002'),
          0, 'A member cannot read the reminder log, which says who is behind');
reset role;

select sign_in_as('aa000000-0000-0000-0000-0000000000f1');
select ok((select count(*) from public.cpd_reminder_log
            where member_id = 'f1b00000-0000-0000-0000-000000000002') >= 1,
          'and membership staff can, because chasing it is their job');
reset role;


-- =============================================================================
-- 6. The preference page, which has to work with no session at all
-- =============================================================================
-- The link in a bulletin has to work for somebody who has never signed in and
-- does not want to. That means anon reaches these two functions, so what they
-- give away is the question.
set local role anon;

select is((select count(*)::int from public.preferences_by_token(
            tok('f1b00000-0000-0000-0000-000000000002'))),
          1, 'A real token returns the switches, with no sign in');

select is((select count(*)::int from public.preferences_by_token(
            '00000000-0000-0000-0000-0000000000ff'::uuid)),
          0, 'and a token nobody holds returns nothing at all');

select ok(public.set_preferences_by_token(
            tok('f1b00000-0000-0000-0000-000000000002'),
            p_bulletins => false),
          'Anon can switch bulletins off with the token');

reset role;
select ok(not (select email_newsletter from public.member_preferences
                where member_id = 'f1b00000-0000-0000-0000-000000000002'),
          'and it is actually off on the row afterwards');
set local role anon;

select ok(not public.set_preferences_by_token(
            '00000000-0000-0000-0000-0000000000ff'::uuid, p_bulletins => false),
          'An unknown token changes nothing and says so, rather than raising');

select throws_ok(
  $$select public.set_preferences_by_token(
      tok('f1b00000-0000-0000-0000-000000000002'),
      p_forum => 'whenever')$$,
  '22023',
  null,
  'A forum setting that is not one of the four is refused');

select ok(public.unsubscribe_all_by_token(
            tok('f1b00000-0000-0000-0000-000000000003')),
          'One click switches off everything a member is allowed to refuse');

reset role;
-- INVERTED AT 0034, 23 August 2026. This asserted all FIVE were off. The CPD
-- reminder is no longer one of the things a member is allowed to refuse, so
-- four go off and it stays on. The label in the test above already said
-- "everything a member is allowed to refuse", which turned out to be the more
-- durable way to have written it.
-- AND AGAIN AT 0039, 30 October 2026: the receipt joined the reminder, so three
-- go off and the receipt stays on.
select ok((select not email_newsletter and not email_events
             and cpd_receipts
             and forum_notifications = 'off'
             from public.member_preferences
            where member_id = 'f1b00000-0000-0000-0000-000000000003'),
          'and the three a member may refuse are off afterwards, the receipt still on');

select ok((select cpd_reminders from public.member_preferences
            where member_id = 'f1b00000-0000-0000-0000-000000000003'),
          'while the CPD reminder, which is a notice rather than a mailing, stays on');

-- 0010 called the consents table append only in practice: a change of mind is a
-- new row, so what somebody agreed to and when survives. That record is the
-- answer if anybody ever asks why they were still being emailed.
select ok((select count(*) from public.consents
            where person_id = 'f0000000-0000-0000-0000-000000000002'
              and kind = 'bulletins' and given = false) >= 1,
          'Switching a preference writes a consents row saying what changed');

-- THE RULE FROM 0002, WHICH THIS WHOLE FILE IS BUILT AROUND. Cara has just
-- switched off everything she is allowed to switch off. A decision about her own
-- CPD is not one of those things and must still reach her.
insert into public.cpd_entries
  (id, member_id, year, occurred_on, activity_type_id, title, points, is_core,
   how_recorded, status, recorded_at)
select 'f2000000-0000-0000-0000-00000000000a', 'f1b00000-0000-0000-0000-000000000003',
       extract(year from current_date)::int, current_date - 3,
       t.id, 'TEST Cara after unsubscribing', 1, t.is_core, 'self_declared', 'pending',
       now() - interval '200 days'
  from public.cpd_activity_types t where t.code = 'test-core-type';

select sign_in_as('aa000000-0000-0000-0000-0000000000f1');
select is(public.review_cpd(array['f2000000-0000-0000-0000-00000000000a']::uuid[],
            'accepted'),
          1, 'A decision is taken on an entry belonging to somebody who unsubscribed');
reset role;

select ok((select count(*) from public.email_outbox
            where to_email = 'cara.cpd@test.invalid'
              and template_code = 'cpd_accepted') >= 2,
          'and the decision letter still reaches her, because a notice is not a preference');

select is((select count(*)::int from public.email_outbox
            where to_email = 'cara.cpd@test.invalid' and template_code = 'cpd_logged'
              and html like '%after unsubscribing%'),
          1, 'and so does the receipt (INVERTED AT 0039: stop everything no longer stops it)');


-- -----------------------------------------------------------------------------
-- The verdict
-- -----------------------------------------------------------------------------
-- The Supabase SQL editor shows only the last result, and pgTAP reports a failed
-- test as a row rather than as an error, so a quiet run would look like a pass.
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 50. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 50 TESTS PASSED' as result;

rollback;
