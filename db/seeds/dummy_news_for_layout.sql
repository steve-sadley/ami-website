-- =============================================================================
-- DUMMY. Five news articles, for looking at the layout. Not a migration, not
-- run automatically, and NOT to be left on the live site.
--
--   Supabase SQL editor, or:  psql -d ami -f seeds/dummy_news_for_layout.sql
--
-- Every slug begins `zz-demo-`, so the whole lot comes out again with the one
-- statement at the bottom of this file. That prefix is the only reason it is
-- safe to run this against staging: without it, removing the dummies later
-- means somebody reading titles and deciding one at a time, which is how a
-- placeholder ends up in front of a member.
--
-- No image_path is set on any of them, deliberately. The site falls back to a
-- stock photograph chosen by a stable hash of the slug, so each article keeps
-- the same picture between visits, and these five slugs were picked so that all
-- four stock photographs appear rather than the same one four times over. That
-- also means this file needs nothing uploaded to storage before it will show
-- you anything.
--
-- The dates run backwards from today, so the newest is the one that takes the
-- big feature card and the other four fall into the row list underneath. The
-- summaries are deliberately uneven in length, because a layout only shows its
-- problems when the text does not all stop in the same place.
-- =============================================================================

alter table public.news_articles no force row level security;

insert into public.news_articles
  (slug, title, category, summary, body, status, published_at)
values

('zz-demo-ami-welcomes-its-first-members',
 'AMI welcomes its first members to the register',
 'Institute',
 'The first individuals assessed under the new grading structure now appear on the public register, each with a grade, a region and a membership number that can be checked by anybody.',
 E'The institute has published the first entries on its public register.\n\nEach entry carries the member''s grade, the region they work in and the year they were assessed. Anybody can search the register without signing in, which is the point of it: a client checking whether somebody is a member should not have to ask the member.\n\nMembers appear on the register only once their assessment is complete and their subscription is paid. Nobody is listed automatically.',
 'published', now() - interval '2 days'),

('zz-demo-cpd-scheme-opens-for-2026',
 'CPD scheme opens for 2026',
 'CPD',
 'Ten points a year, five of them core. Activities can be logged as they happen and the record builds itself.',
 E'The continuing development scheme is now open for the 2026 year.\n\nMembers need ten points across the year, of which at least five must come from core activities. Points are logged as activities happen rather than gathered up at the end, and the personal record can be printed at any time.\n\nWhere an activity has been arranged by the institute, the points are added automatically and need no evidence.',
 'published', now() - interval '9 days'),

('zz-demo-membership-grades-explained',
 'Membership grades explained',
 'Membership',
 'What separates one grade from the next, what evidence each asks for, and how to apply for the one that matches your experience. A longer summary than the others, on purpose, because a card whose text runs to three lines is the case that finds the layout problems that a short one never will.',
 E'Membership is graded, and the grade is a statement about the individual rather than the employer.\n\nEach grade sets out the experience it expects and the evidence it asks for. Applying at the wrong grade is not a problem: applications are read by the office, and where the evidence supports a different grade the applicant is told so rather than refused.\n\nNothing is charged before an application is read, and nothing is decided automatically.',
 'published', now() - interval '17 days'),

('zz-demo-council-appoints-two-new-members',
 'Council appoints two new members',
 'Institute',
 'Both bring experience from the analytical side of the industry.',
 E'The council has appointed two new members, both with backgrounds in analysis and air monitoring.\n\nAppointments run for three years and are made against the skills the council needs rather than by rotation.',
 'published', now() - interval '26 days'),

('zz-demo-what-competence-means-in-practice',
 'Competence: what it actually means in practice',
 'Guidance',
 'Training records prove attendance. Competence is something else, and the difference matters on site.',
 E'A training certificate says somebody attended. It does not say they can do the work, and on site that difference is the whole question.\n\nCompetence is the combination of knowledge, experience and judgement, and only the first of those three comes from a course. This is why the institute assesses individuals on evidence rather than counting certificates, and why membership is renewed each year rather than awarded once.\n\nThe practical test is a simple one. Ask what somebody would do when the plan stops working.',
 'published', now() - interval '38 days');

-- -----------------------------------------------------------------------------
-- TAKING THEM OUT AGAIN
-- -----------------------------------------------------------------------------
-- Run this on its own when you have finished looking. It removes every dummy and
-- cannot touch a real article, because a real article does not carry the prefix.
--
--   delete from public.news_articles where slug like 'zz-demo-%';
--
-- Worth doing before the site goes anywhere near a member. A placeholder that
-- reads plausibly is harder to spot than one that says Lorem ipsum, and these
-- read plausibly on purpose.
-- -----------------------------------------------------------------------------
