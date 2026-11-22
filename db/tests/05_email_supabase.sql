-- =============================================================================
-- The email outbox, proved rather than asserted.
--
--   Supabase SQL editor: paste the whole file and run it
--
-- 0027 put a queue between a decision and a message. That queue is the only
-- thing standing between "the office refused an application" and "the applicant
-- was told", and nobody watches an outbox, so every rule in it is asserted here
-- rather than discovered by somebody who never got their letter.
--
-- Four groups:
--
--   the decisions queue exactly one message, with the right words in it
--   untrusted text cannot break out of an email body or a subject line
--   only the right people may queue, read or drain
--   the drain cannot send the same message twice and cannot retry forever
--
-- Same discipline as the other four. Every fixture value is prefixed or uses a
-- .invalid address, so the file runs on staging where real rows already exist.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(46);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;

-- A PERSON IS NOT A LOGIN, and the ids here are deliberately different.
--
-- Since 0017 people.id and people.auth_user_id are two different values, and
-- several columns are foreign keys to one of them specifically. The other test
-- files give a person the same id for both, which is convenient and which hides
-- an entire class of bug: 0025 found the audit trigger writing auth.uid() into a
-- column referencing people(id), and this file found refuse_application doing
-- the same thing, because the fixture made the two indistinguishable.
--
-- So here they differ, and sign_in_as is called with the ACCOUNT id, which is
-- what a real session carries.
insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-0000000000a1', 'ada.email@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000a2', 'olive.email@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000a3', 'eddie.editor@test.invalid');

insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('e1000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-0000000000a1',
   'Ada','Email','ada.email@test.invalid'),
  ('e2000000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-0000000000a2',
   'Olive','Email','olive.email@test.invalid'),
  ('e3000000-0000-0000-0000-000000000003','aa000000-0000-0000-0000-0000000000a3',
   'Eddie','Editor','eddie.editor@test.invalid');

-- Olive is membership staff. Ada is an ordinary member and is the control in
-- every permission test below.
insert into public.role_grants (person_id, role_code) values
  ('e2000000-0000-0000-0000-000000000002', 'membership'),
  ('e3000000-0000-0000-0000-000000000003', 'editor');

insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'e1b00000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
       'TEST-E-0001', g.id, date '2020-01-01', true, 'current'
  from public.membership_grades g where g.code = 'member' limit 1;
insert into public.member_preferences (member_id)
values ('e1b00000-0000-0000-0000-000000000001');

-- Four applications: one to approve, one to refuse, one whose applicant has
-- bounced before, and one carrying a payload in the fields a person types.
insert into public.membership_applications
  (id, reference, given_name, family_name, email, status, submitted_at, grade_id)
select v.id::uuid, v.ref, v.given, v.family, v.email, 'submitted', now(), g.id
  from (values
    ('e1c00000-0000-0000-0000-000000000001','TEST-EAPP-1','Nadia','Nash','nadia.e@test.invalid'),
    ('e1c00000-0000-0000-0000-000000000002','TEST-EAPP-2','Owen','Oakes','owen.e@test.invalid'),
    ('e1c00000-0000-0000-0000-000000000003','TEST-EAPP-3','Bo','Bounce','bo.bounce@test.invalid'),
    ('e1c00000-0000-0000-0000-000000000004','TEST-EAPP-4','<script>alert(1)</script>','Xss','xss.e@test.invalid')
  ) as v(id, ref, given, family, email)
  cross join lateral (select id from public.membership_grades where code = 'member' limit 1) g;

insert into public.suppression_list (email, reason)
values ('bo.bounce@test.invalid', 'TEST hard bounce')
on conflict (email) do nothing;

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function try_dml(p_sql text) returns void language plpgsql as $$
begin execute p_sql; end $$;


-- =============================================================================
-- 1. Approving queues one message, and it says the right things
-- =============================================================================
select sign_in_as('aa000000-0000-0000-0000-0000000000a2');

select public.approve_application('e1c00000-0000-0000-0000-000000000001'::uuid,
       'TEST-E-9001', current_date, null);

select is((select count(*)::int from public.email_outbox
            where to_email = 'nadia.e@test.invalid'),
          1, 'Approving an application queues exactly one message');

select is((select template_code from public.email_outbox
            where to_email = 'nadia.e@test.invalid'),
          'application_approved', 'and it is the approval template');

select ok((select subject like '%TEST-EAPP-1%' from public.email_outbox
            where to_email = 'nadia.e@test.invalid'),
          'the subject carries the application reference, which is what the applicant quotes');

select ok((select html like '%TEST-E-9001%' from public.email_outbox
            where to_email = 'nadia.e@test.invalid'),
          'and the body carries the membership number they were just given');

select ok((select html like '%Nadia%' from public.email_outbox
            where to_email = 'nadia.e@test.invalid'),
          'and addresses them by name');

-- The member row is created inactive and switched on by hand once the fee is
-- paid, so an approval that says "you are now on the register" is a promise
-- nobody made and sends somebody looking for a record that is not there.
select ok((select html !~* '(you are now|welcome to the register|congratulations)'
             from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          'the approval does not claim the membership is already active');

select ok((select status = 'queued' from public.email_outbox
            where to_email = 'nadia.e@test.invalid'),
          'it is queued rather than sent, because the database does not send email');


-- =============================================================================
-- 2. Refusing queues one, and the reason IS the letter
-- =============================================================================
select public.refuse_application('e1c00000-0000-0000-0000-000000000002'::uuid,
       'The evidence of supervised experience did not cover the last two years.');

select is((select count(*)::int from public.email_outbox
            where to_email = 'owen.e@test.invalid'),
          1, 'Refusing an application queues exactly one message');

select ok((select html like '%supervised experience%' from public.email_outbox
            where to_email = 'owen.e@test.invalid'),
          'and the reason the office typed is the reason the applicant reads');

select ok((select html !~* '(unsuccessful applicants may not|never apply again)'
             and html ~* 'apply again'
             from public.email_outbox where to_email = 'owen.e@test.invalid'),
          'a refusal says it is not a permanent bar, because it is not');

-- The one rule the note has to obey. A refusal with no reason is refused before
-- anything is written, so there is no letter with a blank in the middle of it.
select throws_ok(
  $$select public.refuse_application('e1c00000-0000-0000-0000-000000000003'::uuid, '   ')$$,
  null, null, 'A refusal with no reason is refused outright');

-- And the assertion that actually matters. throws_ok alone would pass if the
-- function did not exist, or if it fell over for some entirely different reason,
-- which is how a test comes to pass for the wrong reason.
select is((select count(*)::int from public.email_outbox
            where to_email = 'bo.bounce@test.invalid'),
          0, 'so nothing at all is queued for them');


-- =============================================================================
-- 3. Untrusted text cannot break out
-- =============================================================================
-- An applicant types their own name and a member of staff types the note. Both
-- end up inside an HTML body that an inbox renders, and neither has been through
-- anything that makes it safe to drop into markup.
select public.refuse_application('e1c00000-0000-0000-0000-000000000004'::uuid,
       'Not enough <b>evidence</b> & the dates did not match.');

select ok((select html not like '%<script>%' from public.email_outbox
            where to_email = 'xss.e@test.invalid'),
          'a script tag in an applicant''s own name never becomes an element');

select ok((select html like '%&lt;script&gt;%' from public.email_outbox
            where to_email = 'xss.e@test.invalid'),
          'it survives as words, so the office can see what was submitted');

select ok((select html like '%&lt;b&gt;evidence&lt;/b&gt;%' from public.email_outbox
            where to_email = 'xss.e@test.invalid'),
          'markup typed into a decision note is escaped too, not honoured');

select ok((select html like '%&amp;%' from public.email_outbox
            where to_email = 'xss.e@test.invalid'),
          'and an ampersand is escaped rather than left to start an entity');

-- The next three call app.render_email directly, so they step out of the signed
-- in role first. Not a workaround: the wording of an email is content, and 0010
-- made email_templates readable by editors rather than by membership staff, so
-- Olive genuinely cannot read one. She never needs to. queue_email is SECURITY
-- DEFINER and reads the template as the owner, which is the only path that
-- exists in the running site. These three are about string handling.
reset role;

-- A subject goes into a header. A template is editable in the admin app, so the
-- line break has to be taken out at render time and not trusted to the author.
select ok((select (app.render_email('application_approved',
             jsonb_build_object('reference', E'AAA\r\nBcc: someone@evil.invalid'))).subject
             !~ '[\r\n]'),
          'a line break substituted into a subject line is taken out');

select ok((select (app.render_email('application_approved', '{}'::jsonb)).html
             not like '%{{%'),
          'a placeholder nobody supplied becomes nothing, not the literal {{name}}');

select ok((select (app.render_email('application_approved', '{}'::jsonb)).is_service),
          'both decision emails are service email, so they cannot be opted out of');


-- =============================================================================
-- 4. Who may queue, read and drain
-- =============================================================================
select sign_in_as('aa000000-0000-0000-0000-0000000000a1');

select throws_ok(
  $$select app.queue_email('application_approved', 'anyone@test.invalid', 'Anyone')$$,
  '42501', null,
  'An ordinary member cannot send mail from AMI''s own domain to an address of their choosing');

select is((select count(*)::int from public.email_outbox), 0,
          'and cannot read the queue at all, because it carries other people''s refusals');

select throws_ok(
  $$select try_dml('update public.email_outbox set to_email = ''me@test.invalid''')$$,
  null, null, 'nor rewrite a message that AMI will send under its own name');

select throws_ok($$select public.claim_email_batch(10)$$, '42501', null,
                 'and cannot drain the queue, which is the service role''s job alone');
reset role;

select sign_in_as('aa000000-0000-0000-0000-0000000000a2');
select ok((select count(*) from public.email_outbox) >= 3,
          'Membership staff CAN read the queue, because chasing a letter that did not arrive is their job');

select ok((select count(*) from public.admin_email_queue) >= 3,
          'and the admin view shows it without the body, which is what they need');
reset role;

set local role anon;
select throws_ok('select * from public.email_outbox', '42501', null,
                 'anon holds no grant on the outbox at all');
reset role;


-- =============================================================================
-- 5. A suppressed address, and the drain
-- =============================================================================
-- 0010 says the suppression list is honoured on every send without exception,
-- including service email. An address that bounces does not stop bouncing
-- because the message was important.
select sign_in_as('aa000000-0000-0000-0000-0000000000a2');
select app.queue_email('application_refused', 'bo.bounce@test.invalid', 'Bo Bounce',
                       jsonb_build_object('given_name','Bo','note','test'));
reset role;

select is((select status from public.email_outbox where to_email = 'bo.bounce@test.invalid'),
          'suppressed',
          'A message to a bounced address is recorded as suppressed, not dropped in silence');

set local role service_role;

select is((select count(*)::int from public.claim_email_batch(50)
            where to_email = 'bo.bounce@test.invalid'),
          0, 'and the drain never picks it up');

-- Claiming moves the row out of reach of a second drain before it hands it over.
-- Two Workers running at once sending one applicant two refusals is worse than
-- one applicant getting theirs a minute late.
select is((select count(*)::int from public.claim_email_batch(50)
            where to_email = 'nadia.e@test.invalid'),
          0, 'A claimed message is not handed out again by the next drain');

select is((select status from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          'sending', 'because claiming moves it to sending before it returns it');

select is((select attempts from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          1, 'and counts the attempt on the way out, not on the way back');

-- A message that kills the sender must not be retried forever, and a provider
-- having a bad minute must not lose a letter. Three tries, then it stops and
-- says why.
--
-- Driven by three REAL claims rather than by setting attempts to 3 by hand. The
-- interesting part is the join between attempts < 3 in the claim and
-- attempts >= 3 in the failure, which is exactly one off-by-one away from either
-- stranding every message at the second attempt or sending a fourth. Setting the
-- counter directly tests neither side of it.
--
-- The only thing simulated is time passing: a claim will not pick a row up again
-- within five minutes, and now() inside one transaction never moves, so
-- claimed_at is wound back between attempts. That is the clock, not the counter.
select public.mark_email_failed(
  (select id from public.email_outbox where to_email = 'nadia.e@test.invalid'),
  'SMTP2GO refused');

select is((select status from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          'queued', 'A first failure goes back in the queue rather than being given up on');

select is((select attempts from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          1, 'with one attempt against it');

update public.email_outbox set claimed_at = now() - interval '10 minutes'
 where to_email = 'nadia.e@test.invalid';

select is((select count(*)::int from public.claim_email_batch(50)
            where to_email = 'nadia.e@test.invalid'),
          1, 'Five minutes later it is offered again, because a bad minute is not a lost letter');

select public.mark_email_failed(
  (select id from public.email_outbox where to_email = 'nadia.e@test.invalid'),
  'SMTP2GO refused again');

select is((select status from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          'queued', 'and a second failure still does not give up');

update public.email_outbox set claimed_at = now() - interval '10 minutes'
 where to_email = 'nadia.e@test.invalid';
select public.claim_email_batch(50);

select public.mark_email_failed(
  (select id from public.email_outbox where to_email = 'nadia.e@test.invalid'),
  'SMTP2GO refused a third time');

select is((select status from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          'failed', 'but the third gives up');

select ok((select last_error like '%third time%' from public.email_outbox
            where to_email = 'nadia.e@test.invalid'),
          'and the row carries the reason it was given, not one string for every cause');

-- Settling a row that was never handed out is refused. Without this a bug in
-- the sender can mark a message sent that never went, or put a sent one back in
-- the queue, and either way the outbox stops being a record of what happened.
select public.mark_email_sent(
  (select id from public.email_outbox where to_email = 'nadia.e@test.invalid'), 'ref-x');

select is((select status from public.email_outbox where to_email = 'nadia.e@test.invalid'),
          'failed', 'A row that was not claimed cannot be marked sent');

select is((select count(*)::int from public.claim_email_batch(50)
            where to_email = 'nadia.e@test.invalid'),
          0, 'and a failed message is never claimed again');

select public.mark_email_sent(
  (select id from public.email_outbox where to_email = 'owen.e@test.invalid'), 'ref-1');

select ok((select status = 'sent' and sent_at is not null
             from public.email_outbox where to_email = 'owen.e@test.invalid'),
          'A sent message is stamped, so the office can say when it went');

-- An address can be suppressed AFTER a message was queued for it, which is the
-- case the check inside the claim exists for and the one the first version of
-- this file never exercised. Merely skipping the row leaves a letter sitting at
-- queued with no error forever, looking to the office exactly like one that is
-- about to go out.
reset role;
select sign_in_as('aa000000-0000-0000-0000-0000000000a2');
select app.queue_email('application_refused', 'late.bounce@test.invalid', 'Late Bounce',
                       jsonb_build_object('given_name','Late','note','test'));
reset role;

select is((select status from public.email_outbox where to_email = 'late.bounce@test.invalid'),
          'queued', 'A message queued to a good address is queued normally');

insert into public.suppression_list (email, reason)
values ('late.bounce@test.invalid', 'TEST bounced after queueing')
on conflict (email) do nothing;

set local role service_role;
select is((select count(*)::int from public.claim_email_batch(50)
            where to_email = 'late.bounce@test.invalid'),
          0, 'and once that address bounces, the drain does not send it');

select is((select status from public.email_outbox where to_email = 'late.bounce@test.invalid'),
          'suppressed',
          'and says so, rather than leaving it queued forever with nothing to explain it');
reset role;


-- =============================================================================
-- 6. A refusal letter is not content
-- =============================================================================
-- 0010 gave editors write access to every email template, which was harmless
-- while nothing used the table. Now the table holds the letters AMI sends about
-- somebody's membership, and an editor is a role for news and guidance that
-- carries no membership privileges at all.
--
-- Without this an editor could add a link of their own to the refusal template,
-- and the next refusal a membership officer issued would carry it, under AMI's
-- name, to somebody with every reason to trust it.
select sign_in_as('aa000000-0000-0000-0000-0000000000a3');

select ok((select count(*) from public.email_templates) >= 2,
          'An editor can READ the templates, because wording is their job');

-- Asserted on the ROW and not on an exception, deliberately. Row level security
-- does not raise when a USING clause excludes a row: the statement succeeds and
-- updates nothing. A throws_ok here would be asserting a behaviour Postgres does
-- not have, and it would pass for the wrong reason the day the policy was
-- dropped, which is the only day it matters.
select lives_ok(
  $$update public.email_templates set html = '<p>Pay here</p>'
     where code = 'application_refused'$$,
  'An editor''s attempt to rewrite a refusal letter does not raise');

select ok((select html not like '%Pay here%' from public.email_templates
            where code = 'application_refused'),
          'it simply changes nothing, which is what row level security does');
reset role;


-- -----------------------------------------------------------------------------
-- The verdict
-- -----------------------------------------------------------------------------
-- The Supabase SQL editor shows only the last result, and pgTAP reports a failed
-- test as a row rather than as an error, so a quiet run would look like a pass.
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 46. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 46 TESTS PASSED' as result;

rollback;
