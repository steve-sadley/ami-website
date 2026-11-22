-- =============================================================================
-- The public surface, proved rather than asserted.
--
--   psql -d ami -f tests/03_public_site.sql
--
-- Everything an anonymous visitor can reach, and everything they cannot. The
-- tests that matter most here are the ones checking that anon gets the RIGHT
-- ROWS rather than merely no error, because a view that returns nothing raises
-- nothing and looks exactly like a working site with no content in it.
--
-- Same discipline as 01 and 02: every fixture value is prefixed or uses a
-- .invalid address, so this runs on an empty database and on a populated one.
-- =============================================================================
create extension if not exists pgtap;

begin;
select plan(25);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('member', 'Member', 'MAMI', true, true, true, 2)
on conflict (code) do nothing;

-- A grade that is deliberately off the register, so the public grade list has
-- something it must not show.
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values ('test_hidden', 'Test hidden grade', 'XXXX', false, false, false, 99)
on conflict (code) do nothing;

insert into public.hero_statements (statement, sort_order, active) values
  ('TEST hero visible', 901, true),
  ('TEST hero switched off', 902, false);

insert into public.page_blocks (page_key, block_key, body, sort_order, status) values
  ('test-about', 'intro',   'TEST published block', 1, 'published'),
  ('test-about', 'unfinished', 'TEST draft block',  2, 'draft');

insert into public.news_articles (slug, title, category, summary, body, status, published_at) values
  ('test-published-article', 'TEST published article', 'Technical',
   'A summary.', 'The body of the article.', 'published', now() - interval '1 day'),
  ('test-draft-article', 'TEST draft article', 'Technical',
   'A summary.', 'Should not be readable.', 'draft', null),
  ('test-future-article', 'TEST future article', 'Technical',
   'A summary.', 'Not yet.', 'published', now() + interval '30 days');

insert into public.guidance_documents (slug, title, category, summary, storage_path,
                                       members_only, status, published_at) values
  ('test-open-guidance',    'TEST open guidance',    'Surveying', 's', 'a/b.pdf', false, 'published', now()),
  ('test-members-guidance', 'TEST members guidance', 'Surveying', 's', 'a/c.pdf', true,  'published', now());

-- A listed member, so the register and the numbers have something real in them.
insert into auth.users (id, email) values
  ('c1c1c1c1-1111-1111-1111-111111111111', 'pub@test.invalid');
insert into public.people (id, auth_user_id, given_name, family_name, email) values
  ('c1c1c1c1-1111-1111-1111-111111111111','c1c1c1c1-1111-1111-1111-111111111111',
   'Pat','Public','pub@test.invalid');
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select 'c2c2c2c2-1111-1111-1111-111111111111', 'c1c1c1c1-1111-1111-1111-111111111111',
       'TEST-P-0001', g.id, date '2021-01-01', true, 'current'
  from public.membership_grades g where g.code = 'member' limit 1;
insert into public.member_preferences (member_id, list_on_register, public_profile)
values ('c2c2c2c2-1111-1111-1111-111111111111', true, true);
insert into public.register_slugs (slug, member_id)
values ('test-pat-public', 'c2c2c2c2-1111-1111-1111-111111111111');

create or replace function try_dml(p_sql text) returns void language plpgsql as $$
begin execute p_sql; end $$;

-- =============================================================================
-- 1. The headline
-- =============================================================================
set local role anon;

select is((select count(*)::int from public.public_hero where statement = 'TEST hero visible'), 1,
          'anon sees an active hero statement, not an empty home page');

select is((select count(*)::int from public.public_hero where statement = 'TEST hero switched off'), 0,
          'and does not see one that has been switched off');

select throws_ok('select * from public.hero_statements', '42501', null,
                 'anon cannot read the hero_statements table itself');

-- =============================================================================
-- 2. The grade list an application form offers
-- =============================================================================
select is((select count(*)::int from public.public_grades where code = 'member'), 1,
          'anon sees the grades a person can apply for');

select is((select count(*)::int from public.public_grades where code = 'test_hidden'), 0,
          'and not a grade that is kept off the register');

select throws_ok('select * from public.membership_grades', '42501', null,
                 'anon cannot read the grades table, which carries flags that are none of their business');

-- =============================================================================
-- 3. Articles
-- =============================================================================
select is((select body from public.public_article where slug = 'test-published-article'),
          'The body of the article.',
          'anon can read a published article, body and all');

select is((select count(*)::int from public.public_article where slug = 'test-draft-article'), 0,
          'a draft article is not readable');

select is((select count(*)::int from public.public_article where slug = 'test-future-article'), 0,
          'and neither is one published with a date in the future');

select is((select count(*)::int from public.public_article where slug = 'test-open-guidance'), 1,
          'open guidance is readable');

select is((select count(*)::int from public.public_article where slug = 'test-members-guidance'), 0,
          'members only guidance is not, and it is filtered in the view rather than in the page');

select throws_ok('select * from public.news_articles', '42501', null,
                 'anon cannot read the articles table');

select throws_ok('select * from public.guidance_documents', '42501', null,
                 'nor the guidance table, where the unpublished drafts live');

-- =============================================================================
-- 4. Page text
-- =============================================================================
select is((select body from public.public_page
            where page_key = 'test-about' and block_key = 'intro'),
          'TEST published block', 'anon sees a published block');

select is((select count(*)::int from public.public_page
            where page_key = 'test-about' and block_key = 'unfinished'), 0,
          'and not one that is still a draft');

-- =============================================================================
-- 5. The numbers on the home page
-- =============================================================================
select cmp_ok((select members from public.public_numbers), '>', 0::bigint,
              'the home page count is a real number rather than zero');

select is((select members from public.public_numbers),
          (select count(*) from public.public_register),
          'and it agrees with the register it claims to be counting');

-- =============================================================================
-- 6. The application form
-- =============================================================================
-- The one place a stranger writes a row, and the reason it goes through a Worker.
select throws_ok(
  $$select * from public.submit_application('Ann','Applicant','ann@test.invalid')$$,
  '42501', null, 'anon cannot submit an application directly');
reset role;

set local role authenticated;
select throws_ok(
  $$select * from public.submit_application('Ann','Applicant','ann@test.invalid')$$,
  '42501', null, 'and neither can a signed in member, because the form does not run as one');
reset role;

set local role service_role;
-- Named arguments, because the form grew and positional ones stopped being
-- readable the moment there were fourteen of them.
-- BY SHAPE AND NOT BY VALUE, and this is the third time that distinction has
-- cost a test run.
--
-- This asserted 'AMI-<year>-0001' until 30 October 2026. The reference is the
-- highest one this year plus one, so 0001 is only ever right on a database with
-- no applications in it. On staging, which has two real ones, it answered
-- AMI-2026-0003, which is exactly correct, and the suite called it a failure.
--
-- The same mistake as the six checks in test 07 that counted absolute numbers,
-- and it is recorded in the handover as a standing lesson. A test that only
-- passes on an empty database is a test nobody can run where it matters.
--
-- What matters is proved either way: nothing passed a reference in, and one came
-- back, in this year, in the right shape.
select matches((select reference from public.submit_application(
             p_given_name      => 'Ann',
             p_family_name     => 'Applicant',
             p_email           => 'ann@test.invalid',
             p_telephone       => '07700 900000',
             p_date_of_birth   => date '1985-04-02',
             p_private_address => '1 Test Street, Testton',
             p_employer_name   => 'Test Ltd',
             p_job_title       => 'Surveyor',
             p_date_appointed  => date '2020-01-06',
             p_invoice_name    => 'Test Ltd Accounts',
             p_invoice_address => '2 Test Street, Testton',
             p_signed_name     => 'Ann Applicant')),
          '^AMI-' || to_char(now(),'YYYY') || '-[0-9]{4}$',
          'the service role CAN, and the reference is generated rather than sent');


select throws_ok(
  $$select * from public.submit_application(
      p_given_name => 'Ann', p_family_name => 'Applicant',
      p_email => 'ann.dob@test.invalid', p_date_of_birth => current_date - 5)$$,
  '22023', null, 'a date of birth five days ago is refused rather than stored');

select throws_ok(
  $$select * from public.submit_application('Ann','Applicant','ANN@test.invalid')$$,
  '23505', null, 'a second application for the same address is refused while the first is open');

select throws_ok(
  $$select * from public.submit_application('Ann','Applicant','not-an-address')$$,
  '22023', null, 'and an address that is not an address is refused before it is stored');
reset role;

-- Read back as the owner rather than as service_role. On a hosted project the
-- service role holds every grant; the local stub does not, and a test that only
-- passes on one of them is testing the harness.
select is((select status::text from public.membership_applications
            where lower(email) = 'ann@test.invalid'),
          'submitted', 'and the application arrives submitted, ready for the queue');

select is((select private_address from public.membership_applications
            where lower(email) = 'ann@test.invalid'),
          '1 Test Street, Testton',
          'and everything the paper form asks for is stored, not just the name');

select * from finish();
rollback;
