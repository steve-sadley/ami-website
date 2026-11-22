-- =============================================================================
-- Membership grades, the full set
--
-- Not a migration. Run it once in the Supabase SQL editor, or:
--
--   psql -d ami -f seeds/membership_grades_full_set.sql
--
-- Three grades were seeded in August from the design sessions: Associate,
-- Member and Fellow. The Rules of Membership carry eight. This file adds the
-- five that were missing, sets a sentence against every grade for the home page,
-- and puts them all in one order.
--
-- It is safe to run twice. The inserts conflict on `code` and do nothing, the
-- updates set the same values again, and the CPD requirement rows conflict on
-- the year and grade pair.
--
-- READ THE FOUR NOTES AT THE BOTTOM BEFORE RUNNING. Three of them are decisions
-- rather than transcription, and one is a straight conflict between the rules
-- document and a decision taken on 8 August. Everything here can also be changed
-- afterwards from the Grades screen in the admin app, which is the better route
-- once the site is live.
-- =============================================================================

alter table public.membership_grades no force row level security;

-- -----------------------------------------------------------------------------
-- The five that were missing
-- -----------------------------------------------------------------------------
insert into public.membership_grades
  (code, name, post_nominals, is_assessed, appears_on_register, requires_cpd,
   sort_order, blurb)
values

('affiliate', 'Affiliate', null, false, true, false, 1,
 'For mature candidates employed in an industry associated with asbestos removal and management whose work contributes to the advancement of the industry.'),

('entrant', 'Entrant', null, true, true, true, 2,
 'For those with at least three years in the profession who are committed to continuing development and to progressing through the Institute.'),

('technician', 'Technician', 'Tech-AMI', true, true, true, 3,
 'For those with at least five years in the profession holding a Supervisor or Academically Qualified Person card, working in asbestos removal or management.'),

('competent_person', 'Competent Person Qualification', 'AMI-CPQ', true, true, true, 5,
 'For holders of the RPSH Level 4 Certificate, the BOHS CCP (Asbestos) or the BOHS Certificate of Competence in Asbestos.'),

('honorary_fellow', 'Honorary Fellow', 'Hon. AMI', false, true, false, 8,
 'Conferred by invitation of the Council on those who have rendered notable service to asbestos removal and management and made an extraordinary contribution to the Institute.')

on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- The three that already existed
-- -----------------------------------------------------------------------------
-- Renumbered so all eight run in one order, and given the sentence the home page
-- has been falling back to a default for. Nothing else about them is touched:
-- `requires_cpd` on Associate is left exactly as the 8 August decision set it.
-- See note 2.
update public.membership_grades set sort_order = 4,
  blurb = 'For those in full-time employment in asbestos management or a satellite discipline, including those working in asbestos management outside the United Kingdom.'
 where code = 'associate';

update public.membership_grades set sort_order = 6,
  blurb = 'For mature candidates with at least ten years relevant experience, an approved qualification or membership of another approved body, following a professional interview.'
 where code = 'member';

update public.membership_grades set sort_order = 7,
  blurb = 'For Full Members of at least five years standing with ten years in a senior position, invited to transfer by the Council for distinguished professional attainment.'
 where code = 'fellow';

-- -----------------------------------------------------------------------------
-- CPD requirement rows for the new grades
-- -----------------------------------------------------------------------------
-- Same rule as the original seed. Five and five where CPD is required, a row of
-- zeroes where it is not, so a report can say the requirement was met rather
-- than having nothing to say.
insert into public.cpd_requirements (year, grade_id, core_required, non_core_required)
select y.year, g.id,
       case when g.requires_cpd then 5 else 0 end,
       case when g.requires_cpd then 5 else 0 end
  from public.membership_grades g
  cross join (values (2026), (2027)) as y(year)
on conflict (year, grade_id) do nothing;

-- -----------------------------------------------------------------------------
-- Check what you have
-- -----------------------------------------------------------------------------
--   select sort_order, code, name, post_nominals, is_assessed,
--          appears_on_register, requires_cpd
--     from public.membership_grades order by sort_order;

-- =============================================================================
-- THE FOUR NOTES
-- =============================================================================
--
-- 1. THE RULES DOCUMENT SAYS SEVEN GRADES AND THEN LISTS EIGHT.
--    Honorary Fellow, Fellow, Full Member, Competent Person Qualification,
--    Associate, Technician, Entrant, Affiliate. Eight are loaded here. Worth
--    settling which is right, because the number appears in the Rules.
--
-- 2. ASSOCIATE AND CPD IS A STRAIGHT CONFLICT.
--    The rules document says an Associate shall "offer such evidence of
--    continuing professional development as the Council of Management may
--    require". The seed of 8 August set Associate to require no CPD, recorded as
--    a decision. This file does NOT change it, because overwriting a recorded
--    decision from a document is the wrong way round. If the document wins:
--
--      update public.membership_grades set requires_cpd = true
--       where code = 'associate';
--      update public.cpd_requirements set core_required = 5, non_core_required = 5
--       where grade_id = (select id from public.membership_grades
--                          where code = 'associate');
--
-- 3. THE ORDER IS A JUDGEMENT.
--    Ascending, least senior first, because that is the order the three existing
--    grades were already in and the home page renders straight from it. Affiliate,
--    Entrant, Technician, Associate, Competent Person, Member, Fellow, Honorary
--    Fellow. The one genuinely arguable place is Competent Person Qualification,
--    put above Associate because it rests on a substantial technical
--    qualification. Drag it anywhere you like in the admin app.
--
-- 4. THREE FLAGS ARE INTERPRETATION, NOT TRANSCRIPTION.
--    `is_assessed` is set false for Honorary Fellow and Affiliate, because
--    neither is assessed against evidence in the way the others are: one is
--    conferred by invitation and the other turns on the Council being satisfied
--    about the applicant's employment. `requires_cpd` is false for the same two,
--    since they are the only grades in the document with no CPD clause.
--    `appears_on_register` is true for all eight, which is the assumption that
--    every member is a member publicly. If Entrant or Affiliate should not be
--    listed publicly, that flag also governs whether the grade shows on the home
--    page at all, because `public_grades` filters on it.
--
-- ALSO WORTH DECIDING: the document heads the grade "Full Member" but the body
-- says "the Grade of Member". The database says Member. Left alone, since
-- renaming a grade changes what appears on the card and the register.
-- =============================================================================
