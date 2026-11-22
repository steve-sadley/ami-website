-- =============================================================================
-- Bulletins, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it
--
-- 0030 is the first thing in this schema that can reach hundreds of people with
-- one press. Everything else sends one letter to one person about their own
-- record. So the tests here are weighted differently from the other six: rather
-- more of them are about who is stopped, and the largest single group is about
-- the guard that keeps a staging deployment away from the membership.
--
-- Six groups:
--
--   who may compose and send, and the editor who used to be able to
--   the segment, which the count and the send both read from one function
--   the four guards on sending
--   the staging guard, which is the one that would be missed until it mattered
--   the unsubscribe link, which has to be each member's own and never a test one
--   the record afterwards, which is what answers "what did we send them"
--
-- Same discipline as the other six. Person ids and account ids differ on
-- purpose. Every fixture value is prefixed or uses a .invalid address.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(42);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values
  ('test-bul-a', 'TEST Bulletin Grade A', 'TBA', true, true, true,  93),
  ('test-bul-b', 'TEST Bulletin Grade B', 'TBB', true, true, false, 94)
on conflict (code) do nothing;

insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select extract(year from current_date)::int, g.id, 5, 5
  from public.membership_grades g where g.code = 'test-bul-a'
on conflict (year, grade_id) do nothing;

insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-0000000000b1', 'olive.bul@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000b2', 'ada.bul@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000b3', 'eddie.bul@test.invalid'),
  ('aa000000-0000-0000-0000-0000000000b4', 'sue.bul@test.invalid');

insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('b0000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-0000000000b1',
   'Olive','Bulstaff','olive.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-0000000000b2',
   'Ada','Bulmember','ada.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000003','aa000000-0000-0000-0000-0000000000b3',
   'Eddie','Buleditor','eddie.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000004','aa000000-0000-0000-0000-0000000000b4',
   'Sue','Bulsuper','sue.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000005', null,
   'Nora','Bulnonews','nora.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000006', null,
   'Bob','Bulbounce','bob.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000007', null,
   'Ivan','Bulinactive','ivan.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000008', null,
   'Gwen','Bulgradeb','gwen.bul@test.invalid'),
  ('b0000000-0000-0000-0000-000000000009', null,
   'Hugh','Bulold','hugh.bul@test.invalid');

insert into public.role_grants (person_id, role_code) values
  ('b0000000-0000-0000-0000-000000000001', 'membership'),
  ('b0000000-0000-0000-0000-000000000003', 'editor'),
  ('b0000000-0000-0000-0000-000000000004', 'super_user');

insert into public.members
  (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, v.joined::date, v.active, 'current'
  from (values
    ('b1b00000-0000-0000-0000-000000000002','b0000000-0000-0000-0000-000000000002','TEST-B-0002','test-bul-a','2022-01-01', true),
    ('b1b00000-0000-0000-0000-000000000005','b0000000-0000-0000-0000-000000000005','TEST-B-0005','test-bul-a','2022-01-01', true),
    ('b1b00000-0000-0000-0000-000000000006','b0000000-0000-0000-0000-000000000006','TEST-B-0006','test-bul-a','2022-01-01', true),
    ('b1b00000-0000-0000-0000-000000000007','b0000000-0000-0000-0000-000000000007','TEST-B-0007','test-bul-a','2022-01-01', false),
    ('b1b00000-0000-0000-0000-000000000008','b0000000-0000-0000-0000-000000000008','TEST-B-0008','test-bul-b','2022-01-01', true),
    ('b1b00000-0000-0000-0000-000000000009','b0000000-0000-0000-0000-000000000009','TEST-B-0009','test-bul-a','2001-01-01', true)
  ) as v(mid, pid, num, grade, joined, active)
  join public.membership_grades g on g.code = v.grade;

-- Nora switched the newsletter off and left event announcements on, which is the
-- whole argument for having categories rather than one switch.
insert into public.member_preferences (member_id, email_newsletter, email_events) values
  ('b1b00000-0000-0000-0000-000000000002', true,  true),
  ('b1b00000-0000-0000-0000-000000000005', false, true),
  ('b1b00000-0000-0000-0000-000000000006', true,  true),
  ('b1b00000-0000-0000-0000-000000000007', true,  true),
  ('b1b00000-0000-0000-0000-000000000008', true,  true),
  ('b1b00000-0000-0000-0000-000000000009', true,  true);

insert into public.suppression_list (email, reason)
values ('bob.bul@test.invalid', 'TEST hard bounce')
on conflict (email) do nothing;

-- Gwen's grade requires no CPD, so cpd => 'short' must not reach her. Ada's does
-- and she has nothing accepted, so it must.
--
-- EVERY CAMPAIGN BELOW IS SCOPED TO THE TWO TEST GRADES, and that is not tidiness.
-- An audience of {} means "every active member who takes the newsletter", which
-- on an empty mirror is exactly the fixtures and on ami-staging is the fixtures
-- plus whoever is really there. The counts further down then pass here and fail
-- on the database that matters. They did, on 15 August, six of them at once.
insert into public.email_campaigns (id, name, subject, html, audience, status)
values
  ('bc000000-0000-0000-0000-000000000001', 'TEST bulletin one',
   'A note from AMI for {{given_name}}',
   '<p>Dear {{given_name}} {{family_name}},</p><p>Your number is {{membership_number}}.</p>'
   || '<p><a href="{{unsubscribe_url}}">Change what AMI sends you</a></p>',
   '{"grades":["test-bul-a","test-bul-b"]}'::jsonb, 'draft'),
  ('bc000000-0000-0000-0000-000000000002', 'TEST bulletin with no way out',
   'No unsubscribe here',
   '<p>Dear {{given_name}},</p><p>Nothing to click.</p>',
   '{"grades":["test-bul-a","test-bul-b"]}'::jsonb, 'draft'),
  ('bc000000-0000-0000-0000-000000000003', 'TEST bulletin, empty',
   null, null, '{"grades":["test-bul-a","test-bul-b"]}'::jsonb, 'draft');

-- The environment starts as whatever the row says. These tests set it
-- deliberately and put it back, because a test that leaves a setting changed is
-- a test that breaks the next one.
update public.system_settings set value = 'staging'  where key = 'environment';
update public.system_settings set value = ''         where key = 'bulletin_allow';
update public.system_settings set value = 'https://staging.ami.uk.com' where key = 'site_url';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function try_dml(p_sql text) returns void language plpgsql as $$
begin execute p_sql; end $$;


-- =============================================================================
-- 1. Who may compose and send
-- =============================================================================
-- 0010 gave EDITORS insert and update on email_campaigns, which was harmless
-- while nothing used the table. An editor is a role for news, guidance and page
-- copy and holds no membership privileges at all, so without 0030's change an
-- editor could have written a letter to every member on the register, under
-- AMI's name, and nothing about it would have looked wrong.
select sign_in_as('aa000000-0000-0000-0000-0000000000b3');

select throws_ok(
  $$insert into public.email_campaigns (name, subject, html)
    values ('TEST editor bulletin', 'Hello', '<p>{{unsubscribe_url}}</p>')$$,
  '42501',
  null,
  'An editor cannot create a bulletin');

select is((select count(*)::int from public.email_campaigns
            where id = 'bc000000-0000-0000-0000-000000000001'),
          0, 'and cannot even read one, because the audience is a membership matter');

select throws_ok(
  $$select public.send_campaign('bc000000-0000-0000-0000-000000000001')$$,
  '42501',
  'Only membership staff may send a bulletin.',
  'and certainly cannot send one');
reset role;

select sign_in_as('aa000000-0000-0000-0000-0000000000b2');
select throws_ok(
  $$select public.campaign_count('bc000000-0000-0000-0000-000000000001')$$,
  '42501',
  null,
  'An ordinary member cannot even count the audience');

select throws_ok(
  $$select public.send_campaign_test('bc000000-0000-0000-0000-000000000001',
      'somewhere@test.invalid')$$,
  '42501',
  null,
  'and cannot send themselves a test copy of one');

-- The environment flag decides whether a bulletin reaches four addresses or four
-- hundred, so it is the one setting a member of staff must not be able to move.
select lives_ok(
  $$update public.system_settings set value = 'live' where key = 'environment'$$,
  'A member updating a system setting does not raise, because row level security does not');

-- Dropped back to the owner before reading. Asked as the member, the SELECT
-- policy answers with no row at all and the comparison is against null, which
-- fails while looking exactly like a security hole. The first version of this
-- test did that and cost 10 minutes.
reset role;
select is((select value from public.system_settings where key = 'environment'),
          'staging',
          'it simply changes nothing, and the environment is still staging');

select sign_in_as('aa000000-0000-0000-0000-0000000000b1');
select lives_ok(
  $$insert into public.email_campaigns (id, name, subject, html)
    values ('bc000000-0000-0000-0000-00000000000f', 'TEST staff bulletin', 'Hello',
            '<p>{{unsubscribe_url}}</p>')$$,
  'Membership staff can create a bulletin');
reset role;


-- =============================================================================
-- 2. The segment
-- =============================================================================
-- Three conditions are not exposed as audience keys and cannot be turned off by
-- whoever is composing: there has to be an address, it must not be suppressed,
-- and the member must not have switched that channel off. A checkbox for any of
-- those is a checkbox somebody unticks.
select ok((select count(*) from app.campaign_recipients('{}'::jsonb)
            where email like '%.bul@test.invalid') = 3,
          'An empty audience reaches the three active members who take the newsletter');

select is((select count(*)::int from app.campaign_recipients('{}'::jsonb)
            where email = 'nora.bul@test.invalid'),
          0, 'Nora, who switched the newsletter off, is not in it');

select is((select count(*)::int from app.campaign_recipients('{}'::jsonb)
            where email = 'bob.bul@test.invalid'),
          0, 'nor is Bob, whose address has bounced');

select is((select count(*)::int from app.campaign_recipients('{}'::jsonb)
            where email = 'ivan.bul@test.invalid'),
          0, 'nor is Ivan, whose membership is not active');

select is((select count(*)::int from app.campaign_recipients('{"channel":"events"}'::jsonb)
            where email = 'nora.bul@test.invalid'),
          1, 'but Nora IS in an events announcement, because she left that one on');

select ok((select count(*) from app.campaign_recipients('{"active":"any"}'::jsonb)
            where email like '%.bul@test.invalid') = 4,
          'active "any" reaches Ivan as well');

select is((select count(*)::int from app.campaign_recipients('{"grades":["test-bul-b"]}'::jsonb)
            where email like '%.bul@test.invalid'),
          1, 'A grade filter takes the grade CODE and reaches only that grade');

select is((select count(*)::int from app.campaign_recipients('{"cpd":"short"}'::jsonb)
            where email = 'gwen.bul@test.invalid'),
          0, 'cpd "short" leaves out a grade that requires no CPD, rather than calling it behind');

select ok((select count(*) from app.campaign_recipients('{"cpd":"short"}'::jsonb)
            where email like '%.bul@test.invalid') >= 1,
          'and does reach a member on a grade that does require it');

select is((select count(*)::int from app.campaign_recipients(
            '{"joined_after":"2010-01-01"}'::jsonb)
            where email = 'hugh.bul@test.invalid'),
          0, 'joined_after leaves out somebody who joined in 2001');

select is((select count(*)::int from app.campaign_recipients(
            '{"roles":["membership"]}'::jsonb)
            where email like '%.bul@test.invalid'),
          0, 'A role filter reaches only role holders, and none of these members holds one');


-- =============================================================================
-- 3. The four guards on sending
-- =============================================================================
select sign_in_as('aa000000-0000-0000-0000-0000000000b1');

-- Nobody mails 200 people something they have not read in an inbox.
select throws_ok(
  $$select public.send_campaign('bc000000-0000-0000-0000-000000000001')$$,
  'Send yourself a test copy and read it before this goes to the membership.',
  'A bulletin that has never been tested cannot be sent');

select lives_ok(
  $$select public.send_campaign_test('bc000000-0000-0000-0000-000000000001',
      'olive.bul@test.invalid')$$,
  'A test copy can be sent');

select isnt((select test_sent_at from public.email_campaigns
              where id = 'bc000000-0000-0000-0000-000000000001'),
            null, 'and it stamps the campaign, which is what unlocks the real send');

-- THE ONE WITH THE LEGAL WEIGHT. The rule is in the database rather than in the
-- composer, because the composer is a browser and a browser is not a rule.
select lives_ok(
  $$select public.send_campaign_test('bc000000-0000-0000-0000-000000000002',
      'olive.bul@test.invalid')$$,
  'A bulletin with no unsubscribe link can still be tested');

select throws_ok(
  $$select public.send_campaign('bc000000-0000-0000-0000-000000000002')$$,
  'Every bulletin has to carry an unsubscribe link. Put {{unsubscribe_url}} in the body.',
  'but it cannot be sent to anybody');

select throws_ok(
  $$select public.send_campaign_test('bc000000-0000-0000-0000-000000000003',
      'olive.bul@test.invalid')$$,
  'A bulletin needs a subject line and a body before it can be sent.',
  'An empty bulletin cannot even be tested');


-- =============================================================================
-- 4. The staging guard
-- =============================================================================
-- The one that would be missed until the day it mattered. A deployment that is
-- not live must not be able to reach the membership, and the only reliable place
-- to decide that is here, once, rather than in the head of whoever is testing.
select is((select (public.send_campaign('bc000000-0000-0000-0000-000000000001')
                     ->> 'queued')::int),
          0, 'On staging with an empty allow list, a send queues nothing at all');

select ok((select count(*) from public.email_sends
            where campaign_id = 'bc000000-0000-0000-0000-000000000001'
              and status = 'withheld') = 3,
          'and every recipient is recorded as withheld rather than quietly skipped');

select ok((select reason like '%staging%' from public.email_sends
            where campaign_id = 'bc000000-0000-0000-0000-000000000001'
              and status = 'withheld' limit 1),
          'with a reason saying why, so nobody reads it as a failure');

-- Sent means sent, whatever the environment did. A second press must not go
-- looking for the people it held back the first time.
select throws_ok(
  $$select public.send_campaign('bc000000-0000-0000-0000-000000000001')$$,
  null,
  null,
  'and the same bulletin cannot be sent a second time');
reset role;

-- Now with the allow list set, which is how the office tests before cutover.
update public.system_settings set value = 'ada.bul@test.invalid' where key = 'bulletin_allow';

insert into public.email_campaigns (id, name, subject, html, audience, status, test_sent_at)
values ('bc000000-0000-0000-0000-000000000004', 'TEST bulletin two',
        'Second note for {{given_name}}',
        '<p>Dear {{given_name}},</p><p>Number {{membership_number}}.</p>'
        || '<p><a href="{{unsubscribe_url}}">Unsubscribe</a></p>',
        '{"grades":["test-bul-a","test-bul-b"]}'::jsonb, 'draft', now());

select sign_in_as('aa000000-0000-0000-0000-0000000000b1');
select is((select (public.send_campaign('bc000000-0000-0000-0000-000000000004')
                     ->> 'queued')::int),
          1, 'With one address on the allow list, exactly that one is queued');

select is((select (select count(*)::int from public.email_sends
                    where campaign_id = 'bc000000-0000-0000-0000-000000000004'
                      and status = 'withheld')),
          2, 'and the other two are still recorded as withheld');
reset role;

update public.system_settings set value = 'live' where key = 'environment';

insert into public.email_campaigns (id, name, subject, html, audience, status, test_sent_at)
values ('bc000000-0000-0000-0000-000000000005', 'TEST bulletin three',
        'Third note',
        '<p>Dear {{given_name}},</p><p><a href="{{unsubscribe_url}}">Unsubscribe</a></p>',
        '{"grades":["test-bul-a","test-bul-b"]}'::jsonb, 'draft', now());

select sign_in_as('aa000000-0000-0000-0000-0000000000b1');
select is((select (public.send_campaign('bc000000-0000-0000-0000-000000000005')
                     ->> 'queued')::int),
          3, 'With the environment live, the whole segment is queued');

select is((select recipient_count from public.email_campaigns
            where id = 'bc000000-0000-0000-0000-000000000005'),
          3, 'and the campaign records how many, which is the number the office reports');

select is(public.campaign_count('bc000000-0000-0000-0000-000000000005'),
          3, 'The count and the send agree, because both read the same function');
reset role;


-- =============================================================================
-- 5. The unsubscribe link
-- =============================================================================
-- Each member's own token, never anybody else's, and never one at all in a test
-- copy. A member of staff clicking the link in a test they sent themselves must
-- not unsubscribe a real member.
select ok((select html like '%https://staging.ami.uk.com/preferences?t=%'
             from public.email_outbox
            where to_email = 'ada.bul@test.invalid' and template_code = 'bulletin'
              and context ->> 'campaign_id' = 'bc000000-0000-0000-0000-000000000005'),
          'A bulletin carries an unsubscribe link built from the site address in settings');

select ok((select o.html like '%' || pr.unsubscribe_token::text || '%'
             from public.email_outbox o
             cross join public.member_preferences pr
            where o.to_email = 'ada.bul@test.invalid' and o.template_code = 'bulletin'
              and o.context ->> 'campaign_id' = 'bc000000-0000-0000-0000-000000000005'
              and pr.member_id = 'b1b00000-0000-0000-0000-000000000002'),
          'and the token in it is that member''s own');

select is((select count(*)::int from public.email_outbox
            where template_code = 'bulletin_test' and html like '%?t=%'),
          0, 'A TEST copy carries no token at all, so nobody can unsubscribe somebody else');

select ok((select subject like '[TEST]%' from public.email_outbox
            where template_code = 'bulletin_test' limit 1),
          'and a test copy says so in the subject line');

select is((select reply_to from public.email_outbox
            where to_email = 'ada.bul@test.invalid' and template_code = 'bulletin'
              and context ->> 'campaign_id' = 'bc000000-0000-0000-0000-000000000005'),
          'bulletin@ami.uk.com',
          'A bulletin replies to a mailbox somebody reads, not to no-reply');

-- A member's own name goes into an HTML body, and a name is untrusted text
-- whoever typed it.
update public.people set given_name = '<script>alert(1)</script>'
 where id = 'b0000000-0000-0000-0000-000000000002';

insert into public.email_campaigns (id, name, subject, html, audience, status, test_sent_at)
values ('bc000000-0000-0000-0000-000000000006', 'TEST bulletin four', 'Fourth',
        '<p>Dear {{given_name}},</p><p><a href="{{unsubscribe_url}}">Unsubscribe</a></p>',
        '{"grades":["test-bul-a","test-bul-b"]}'::jsonb, 'draft', now());

select sign_in_as('aa000000-0000-0000-0000-0000000000b1');
select ok(public.send_campaign('bc000000-0000-0000-0000-000000000006') is not null,
          'A bulletin goes out to a member whose name contains markup');
reset role;

select ok((select html not like '%<script>%' and html like '%&lt;script&gt;%'
             from public.email_outbox
            where to_email = 'ada.bul@test.invalid'
              and context ->> 'campaign_id' = 'bc000000-0000-0000-0000-000000000006'),
          'and the markup survives as words rather than as an element');


-- =============================================================================
-- 6. The record afterwards
-- =============================================================================
-- The drain knows nothing about campaigns and should not have to. It settles the
-- outbox row and a trigger carries that through, so email_sends is an account of
-- what happened rather than a list of intentions frozen at the moment of sending.
select ok((select count(*) from public.email_sends
            where campaign_id = 'bc000000-0000-0000-0000-000000000005') = 3,
          'There is one email_sends row per recipient');

update public.email_outbox set status = 'sending'
 where context ->> 'campaign_id' = 'bc000000-0000-0000-0000-000000000005';
select public.mark_email_sent(
  (select id from public.email_outbox
    where to_email = 'ada.bul@test.invalid'
      and context ->> 'campaign_id' = 'bc000000-0000-0000-0000-000000000005'),
  'TEST-PROVIDER-REF');

select is((select status from public.email_sends s
            where s.campaign_id = 'bc000000-0000-0000-0000-000000000005'
              and s.email = 'ada.bul@test.invalid'),
          'sent', 'Settling the outbox row marks the campaign send as sent');

select is((select provider_ref from public.email_sends s
            where s.campaign_id = 'bc000000-0000-0000-0000-000000000005'
              and s.email = 'ada.bul@test.invalid'),
          'TEST-PROVIDER-REF',
          'and carries the provider reference through, which is what a delivery query needs');

select sign_in_as('aa000000-0000-0000-0000-0000000000b1');
select is((select delivered::int from public.admin_campaigns
            where id = 'bc000000-0000-0000-0000-000000000005'),
          1, 'and the office sees one delivered on the bulletin list');

select is((select status from public.admin_campaigns
            where id = 'bc000000-0000-0000-0000-000000000005'),
          'sent', 'with the bulletin itself marked as sent');
reset role;

-- A super user is the only one who may move the environment flag, because that
-- flag is the difference between four addresses and four hundred.
select sign_in_as('aa000000-0000-0000-0000-0000000000b4');
select lives_ok(
  $$update public.system_settings set value = 'staging' where key = 'environment'$$,
  'A super user can move the environment flag');

select is((select value from public.system_settings where key = 'environment'),
          'staging', 'and it actually moves');
reset role;


-- =============================================================================
-- 7. Which address it comes FROM
-- =============================================================================
-- Added by 0032, after the first real bulletin arrived from no-reply@ and asked
-- the reader to write back. Not broken, because the Reply-To was right, but
-- contradictory, and some clients never show a Reply-To at all.
select is(app.from_address_for('bulletin'), 'bulletin@ami.uk.com',
          'A bulletin comes from the bulletin address');

select is(app.from_address_for('bulletin_test'), 'bulletin@ami.uk.com',
          'and so does a test copy, so the test shows what a member would see');

-- The contrast is the point. Nobody replies to an approval, so no-reply is
-- honest there, and a null here means the Worker uses its own default.
select is(app.from_address_for('application_refused'), null,
          'A decision about somebody''s own membership has no sender of its own');

select is((select from_email from public.email_outbox
            where to_email = 'ada.bul@test.invalid' and template_code = 'bulletin'
              and context ->> 'campaign_id' = 'bc000000-0000-0000-0000-000000000005'),
          'bulletin@ami.uk.com',
          'and the queued row carries it, so the Worker never has to guess');



-- -----------------------------------------------------------------------------
-- The verdict
-- -----------------------------------------------------------------------------
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 42. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 42 TESTS PASSED' as result;

rollback;
