-- =============================================================================
-- OPTIONAL. Not a migration, and not run automatically.
--
-- Suggested starting values for the lists that are set from the backend. Run it
-- if you would rather start from something than from an empty screen, and change
-- everything afterwards from the admin area.
--
--   psql -d ami -f seeds/optional_starting_lists.sql
--
-- Nothing here is a decision. It is the working set that came out of the design
-- sessions, put somewhere useful rather than written into a migration where it
-- would need a developer to change.
--
-- The banned word list is NOT here. It is data rather than schema, it belongs to
-- the office, and a list of words committed to a repository is a list of words
-- somebody reads.
--
-- FORCE row level security binds the table owner too, and the role running this
-- on a hosted project is not a superuser, so forcing is lifted for the length of
-- the inserts and put back at the end. If this file stops part way through, run
-- the last block on its own to put the protection back.
-- =============================================================================

alter table public.membership_grades   no force row level security;
alter table public.cpd_requirements    no force row level security;
alter table public.cpd_activity_types  no force row level security;
alter table public.forum_categories    no force row level security;
alter table public.hero_statements     no force row level security;

-- -----------------------------------------------------------------------------
-- Membership grades
-- -----------------------------------------------------------------------------
-- requires_cpd: Member and Fellow yes, Associate no. Decision of 8 August 2026.
-- is_assessed matters more than it looks: every template that renders a grade
-- reads that flag rather than testing the name, so assessed and unassessed stay
-- distinguishable at a glance when the CPD grade is introduced.
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd, sort_order)
values
  ('associate', 'Associate', 'AAMI', true, true, false, 1),
  ('member',    'Member',    'MAMI', true, true, true,  2),
  ('fellow',    'Fellow',    'FAMI', true, true, true,  3)
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- CPD requirement
-- -----------------------------------------------------------------------------
-- Five and five for the grades that require it. Associate gets a row of zeroes
-- rather than no row, so a report can say an Associate met the requirement
-- instead of having nothing to say.
insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select y.year, g.id,
       case when g.requires_cpd then 5 else 0 end,
       case when g.requires_cpd then 5 else 0 end
  from public.membership_grades g
  cross join (values (2026), (2027)) as y(year)
on conflict (year, grade_id) do nothing;

-- -----------------------------------------------------------------------------
-- CPD activity types
-- -----------------------------------------------------------------------------
-- Core means asbestos technical competence. Non core means the wider
-- professional skills around it. Fourteen to start with, because removing one
-- later is harder than adding one: entries already logged against a type have to
-- go somewhere.
insert into public.cpd_activity_types (code, name, is_core, sort_order) values
  ('course_assessed',    'Assessed training course',                                  true,  1),
  ('course_unassessed',  'Unassessed training course',                                true,  2),
  ('seminar',            'Technical seminar or conference',                           true,  3),
  ('webinar',            'AMI webinar or recorded session',                           true,  4),
  ('reading_technical',  'Reading technical guidance, an approved code or a standard', true, 5),
  ('site_learning',      'Site based learning or shadowing',                          true,  6),
  ('assessment_passed',  'A technical assessment or examination passed',              true,  7),
  ('regional_meeting',   'Regional or branch meeting',                                false, 8),
  ('committee',          'Committee or working group service',                        false, 9),
  ('mentoring',          'Mentoring or supervising somebody',                         false, 10),
  ('writing_presenting', 'Writing or presenting on a technical subject',              false, 11),
  ('reading_general',    'Professional reading and trade press',                      false, 12),
  ('soft_skills',        'Management, commercial or communication training',          false, 13),
  ('briefing_delivered', 'An in house briefing or toolbox talk delivered',            false, 14)
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- Forum categories
-- -----------------------------------------------------------------------------
insert into public.forum_categories (slug, name, description, sort_order) values
  ('surveying',  'Surveying',
   'Management, refurbishment and demolition surveys.', 1),
  ('analysis',   'Analysis and air monitoring',
   'Bulk analysis, air monitoring and four stage clearance.', 2),
  ('removal',    'Removal and remediation',
   'Licensed and non licensed work, and notifiable non licensed work.', 3),
  ('duty',       'Duty to manage',
   'Management plans, registers and duty holder questions.', 4),
  ('regulation', 'Regulation and guidance',
   'HSE guidance, approved codes and enforcement.', 5),
  ('general',    'General discussion',
   'Everything else, including the trade and the job market.', 6)
on conflict (slug) do nothing;

-- -----------------------------------------------------------------------------
-- Hero statements
-- -----------------------------------------------------------------------------
-- The three that rotate on the home page, in the order they currently appear in
-- the prototype.
-- Guarded rather than left bare, because there is no unique key to conflict on
-- and running this file twice would otherwise leave six.
insert into public.hero_statements (statement, sort_order)
select * from (values
  ('Recognising and promoting best practice in asbestos management', 1),
  ('Raising standards of competence across the asbestos industry',   2),
  ('Supporting the professionals who keep people safe from asbestos', 3)
) as v(statement, sort_order)
where not exists (select 1 from public.hero_statements);

-- -----------------------------------------------------------------------------
-- Fees
-- -----------------------------------------------------------------------------
-- Deliberately not included. The figures are not set, and a placeholder fee in a
-- seed file is the kind of thing that ends up on an invoice.

-- -----------------------------------------------------------------------------
-- Forcing stays OFF, and this is the correction
-- -----------------------------------------------------------------------------
-- This file used to end by putting FORCE back on these five tables. That was
-- written before migration 0018, and it undid it, because a seed runs after the
-- migrations. The result was the fourth failure from 0018 all over again, on the
-- five tables the public site reads most: the register renders grades, the home
-- page renders hero statements, and both are read through views owned by the same
-- role that forcing binds. An anonymous visitor would have seen nothing.
--
-- Nothing is weakened by leaving it off. Row level security stays ENABLED on all
-- five, anon and authenticated hold only what they were granted one table at a
-- time, and neither has ever been affected by forcing. See 0018 for the full
-- argument.
--
-- Belt and braces, in case an older copy of this file has already run here.
do $$
declare t record;
begin
  for t in
    select n.nspname, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'restricted')
       and c.relkind = 'r'
       and c.relforcerowsecurity
  loop
    execute format('alter table %I.%I no force row level security', t.nspname, t.relname);
  end loop;
end $$;
