-- =============================================================================
-- The daily digest, proved rather than assumed.
--
--   Supabase SQL editor: paste the whole file and run it
--
-- 0031 is the first thing in the schema that emails the membership with nobody
-- pressing anything. That makes three questions worth more than the rest:
--
--   does an item get announced exactly once, however often it is edited
--   does an item with a publication date in the future stay quiet until then
--   does a member get only the half they asked for
--
-- The first is the one that would be noticed by members rather than by us.
-- Correcting a typo in a published article and having it announced a second time
-- is the kind of fault that makes people stop reading.
--
-- Same discipline as the other seven. Person ids and account ids differ. Every
-- fixture value is prefixed or uses a .invalid address.
-- =============================================================================
create extension if not exists pgtap with schema extensions;

begin;
set local search_path = public, extensions, pg_temp;
select plan(28);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('test-dig-grade', 'TEST Digest Grade', 'TDG', true, true, false, 95)
on conflict (code) do nothing;

insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-0000000000d1', 'sue.dig@test.invalid');

insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('d0000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-0000000000d1',
   'Sue','Digsuper','sue.dig@test.invalid'),
  ('d0000000-0000-0000-0000-000000000002', null, 'Ann','Digboth','ann.dig@test.invalid'),
  ('d0000000-0000-0000-0000-000000000003', null, 'Ned','Dignews','ned.dig@test.invalid'),
  ('d0000000-0000-0000-0000-000000000004', null, 'Eve','Digevents','eve.dig@test.invalid'),
  ('d0000000-0000-0000-0000-000000000005', null, 'Ola','Dignone','ola.dig@test.invalid');

insert into public.role_grants (person_id, role_code)
values ('d0000000-0000-0000-0000-000000000001', 'super_user');

insert into public.members
  (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select v.mid::uuid, v.pid::uuid, v.num, g.id, date '2022-01-01', true, 'current'
  from (values
    ('d1b00000-0000-0000-0000-000000000002','d0000000-0000-0000-0000-000000000002','TEST-D-0002'),
    ('d1b00000-0000-0000-0000-000000000003','d0000000-0000-0000-0000-000000000003','TEST-D-0003'),
    ('d1b00000-0000-0000-0000-000000000004','d0000000-0000-0000-0000-000000000004','TEST-D-0004'),
    ('d1b00000-0000-0000-0000-000000000005','d0000000-0000-0000-0000-000000000005','TEST-D-0005')
  ) as v(mid, pid, num)
  cross join lateral (select id from public.membership_grades where code = 'test-dig-grade' limit 1) g;

-- Four members, four combinations of the two switches. This is the whole reason
-- the digest is built in two halves rather than one.
insert into public.member_preferences (member_id, email_newsletter, email_events) values
  ('d1b00000-0000-0000-0000-000000000002', true,  true),
  ('d1b00000-0000-0000-0000-000000000003', true,  false),
  ('d1b00000-0000-0000-0000-000000000004', false, true),
  ('d1b00000-0000-0000-0000-000000000005', false, false);

-- Everything that existed before 0031 was marked as already announced by the
-- migration, so the fixtures below are the only things pending.
insert into public.news_articles (slug, title, category, summary, image_path, status, published_at)
values
  ('zz-test-dig-live', 'TEST digest live article', 'Technical',
   'A summary that should reach the members who take the newsletter.',
   'test/dig.jpg', 'published', now() - interval '1 hour'),
  ('zz-test-dig-future', 'TEST digest future article', 'Technical',
   'Written on Saturday and let out on Monday.', null,
   'published', now() + interval '3 days'),
  ('zz-test-dig-draft', 'TEST digest draft article', 'Technical',
   'Not finished.', null, 'draft', null);

insert into public.events (slug, title, starts_at, location, description, status, published_at)
values
  ('zz-test-dig-event', 'TEST digest event', now() + interval '30 days',
   'Manchester', 'An event that has not happened yet.', 'published', now() - interval '1 hour'),
  ('zz-test-dig-past', 'TEST digest past event', now() - interval '30 days',
   'Leeds', 'An event that has already happened.', 'published', now() - interval '1 hour');

insert into public.guidance_documents (slug, title, category, summary, members_only, status, published_at)
values ('zz-test-dig-guide', 'TEST digest guidance', 'Surveying',
        'Guidance for members only.', true, 'published', now() - interval '1 hour');

update public.system_settings set value = 'staging' where key = 'environment';
update public.system_settings set value = '' where key = 'bulletin_allow';
update public.system_settings set value = 'https://staging.ami.uk.com' where key = 'site_url';

create or replace function sign_in_as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p::text, true);
  execute 'set local role authenticated';
end $$;


-- =============================================================================
-- 1. What is pending, and what is deliberately not
-- =============================================================================
select is((select count(*)::int from app.pending_digest_items()
            where title like 'TEST digest%'),
          3, 'Three items are pending: the live article, the future event and the guidance');

select is((select count(*)::int from app.pending_digest_items()
            where title = 'TEST digest future article'),
          0, 'An article dated three days out is NOT pending, because it is not public yet');

select is((select count(*)::int from app.pending_digest_items()
            where title = 'TEST digest draft article'),
          0, 'and a draft is not pending either');

-- An email inviting somebody to last Thursday is worse than no email at all.
select is((select count(*)::int from app.pending_digest_items()
            where title = 'TEST digest past event'),
          0, 'An event whose date has already gone is not announced late');

select is((select kind from app.pending_digest_items()
            where title = 'TEST digest event'),
          'Event', 'An event is filed as an Event, which is what puts it in the other half');


-- =============================================================================
-- 2. How an item is drawn
-- =============================================================================
-- &amp; rather than &. The whole URL goes through app.html_escape on its way
-- into the href, which is correct: a bare ampersand in an attribute is invalid
-- markup and some mail clients truncate the link at it. Asserting the raw form
-- would be asserting a bug.
select ok((select html like '%staging.ami.uk.com/article?kind=news&amp;slug=zz-test-dig-live%'
             from app.pending_digest_items() where title = 'TEST digest live article'),
          'An item links to itself on the site, using the address in settings');

select ok((select html like '%storage/v1/object/public/public-media/test/dig.jpg%'
             from app.pending_digest_items() where title = 'TEST digest live article'),
          'and shows its picture from the public bucket, which needs no signing');

select ok((select html not like '%<img%'
             from app.pending_digest_items() where title = 'TEST digest event'),
          'An item with no picture carries no image tag at all, rather than a broken one');

select ok((select html like '%Members only%'
             from app.pending_digest_items() where title = 'TEST digest guidance'),
          'A members only item says so, so nobody follows the link and is turned away');

select ok((select html like '%Manchester%' and html like '%' || to_char(now() + interval '30 days', 'FMDD') || '%'
             from app.pending_digest_items() where title = 'TEST digest event'),
          'An event carries its date and its venue, which is the part somebody acts on');

-- The one place in the schema that builds markup rather than substituting into
-- it, so the escaping is done by hand and has to be checked by hand.
update public.news_articles
   set title = 'TEST digest <script>alert(1)</script> article'
 where slug = 'zz-test-dig-live';

select ok((select html not like '%<script>%' and html like '%&lt;script&gt;%'
             from app.pending_digest_items() where title like '%script%'),
          'A script tag in a headline survives as words rather than as an element');


-- =============================================================================
-- 3. Sending it
-- =============================================================================
-- Staging first. Publishing an article on a staging deployment must not mail the
-- membership, and it would be a poor guard that covered the button somebody
-- presses and not the job that runs itself.
select is((select (app.queue_content_digest() ->> 'sent')::int),
          0, 'On staging with an empty allow list, the digest reaches nobody');

select is((select count(*)::int from public.email_outbox
            where template_code = 'content_digest'),
          0, 'and nothing at all is queued');

-- Marked anyway, which is deliberate: holding items back would turn a quiet week
-- into one enormous digest the day the first person subscribes.
select is((select count(*)::int from app.pending_digest_items()
            where title like 'TEST digest%'),
          0, 'but the items are marked as announced, so they are not carried forward');

select is((select (app.queue_content_digest() ->> 'items')::int),
          0, 'A second run has nothing to say and says nothing');


-- Now with somebody on the allow list and something new to announce.
update public.system_settings
   set value = 'ann.dig@test.invalid, ned.dig@test.invalid, eve.dig@test.invalid, ola.dig@test.invalid'
 where key = 'bulletin_allow';

insert into public.news_articles (slug, title, summary, status, published_at)
values ('zz-test-dig-two', 'TEST digest second article', 'Another one.',
        'published', now() - interval '1 hour');
insert into public.events (slug, title, starts_at, location, status, published_at)
values ('zz-test-dig-event2', 'TEST digest second event', now() + interval '40 days',
        'Bristol', 'published', now() - interval '1 hour');

select is((select (app.queue_content_digest() ->> 'sent')::int),
          3, 'With three of the four on the allow list, three digests go out');

select is((select count(*)::int from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ola.dig@test.invalid'),
          0, 'Ola, who takes neither channel, gets nothing and is not counted');

select ok((select html like '%TEST digest second article%' and html like '%TEST digest second event%'
             from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ann.dig@test.invalid'),
          'Ann, who takes both, gets one email carrying both halves');

select ok((select html like '%TEST digest second article%' and html not like '%TEST digest second event%'
             from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ned.dig@test.invalid'),
          'Ned, who takes only the newsletter, gets the article and not the event');

select ok((select html like '%TEST digest second event%' and html not like '%TEST digest second article%'
             from public.email_outbox
            where template_code = 'content_digest' and to_email = 'eve.dig@test.invalid'),
          'Eve, who takes only events, gets the event and not the article');

select ok((select html like '%staging.ami.uk.com/preferences?t=%'
             from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ann.dig@test.invalid'),
          'Every digest carries an unsubscribe link, because it is not a notice');

select ok((select o.html like '%' || pr.unsubscribe_token::text || '%'
             from public.email_outbox o
             cross join public.member_preferences pr
            where o.template_code = 'content_digest' and o.to_email = 'ann.dig@test.invalid'
              and pr.member_id = 'd1b00000-0000-0000-0000-000000000002'),
          'and the token in it is that member''s own');

select ok((select html !~ '\{\{' from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ann.dig@test.invalid'),
          'with no placeholder left unfilled');

select is((select reply_to from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ann.dig@test.invalid'),
          'bulletin@ami.uk.com',
          'and replies go to a mailbox somebody reads');


-- THE ONE MEMBERS WOULD NOTICE. Correcting a typo in an article that has already
-- been announced must not announce it again.
update public.news_articles set summary = 'Another one, corrected.'
 where slug = 'zz-test-dig-two';

select is((select (app.queue_content_digest() ->> 'items')::int),
          0, 'Editing an article that has already gone out announces nothing');

select is((select count(*)::int from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ann.dig@test.invalid'),
          1, 'and Ann still has exactly one digest, not two');


-- Added by 0032. A digest invites a reply as much as a bulletin does.
select is(app.from_address_for('content_digest'), 'bulletin@ami.uk.com',
          'A digest comes from the bulletin address rather than from no-reply');

select is((select from_email from public.email_outbox
            where template_code = 'content_digest' and to_email = 'ann.dig@test.invalid'),
          'bulletin@ami.uk.com',
          'and the queued row carries it');



-- =============================================================================
-- 4. Who may set it off
-- =============================================================================
select sign_in_as('aa000000-0000-0000-0000-0000000000d1');
select lives_ok($$select public.run_content_digest()$$,
                'A super user can send the digest by hand');
reset role;

insert into auth.users (id, email) values
  ('aa000000-0000-0000-0000-0000000000d9', 'plain.dig@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('d0000000-0000-0000-0000-000000000009','aa000000-0000-0000-0000-0000000000d9',
   'Plain','Digmember','plain.dig@test.invalid');

select sign_in_as('aa000000-0000-0000-0000-0000000000d9');
select throws_ok($$select public.run_content_digest()$$, '42501', null,
                 'and nobody else can');

select throws_ok($$select app.queue_content_digest()$$, '42501', null,
                 'nor reach the function underneath it');
reset role;


-- -----------------------------------------------------------------------------
-- The verdict
-- -----------------------------------------------------------------------------
do $$
declare v_failed integer := num_failed();
begin
  if v_failed > 0 then
    raise exception 'TESTS FAILED: % of 28. Do not use this project until it is fixed.', v_failed;
  end if;
end $$;

select 'ALL 28 TESTS PASSED' as result;

rollback;
