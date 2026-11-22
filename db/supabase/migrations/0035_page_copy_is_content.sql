-- =============================================================================
-- 0035  The page copy becomes content
--
-- Steve, 30 October 2026: "with the CMS everything needs to be editable on the
-- site", and when asked how far to go, "can we make it work like Umbraco".
--
-- Before this, four blocks existed: the About intro, the Membership intro, and
-- the office telephone number and address. Everything else on eleven public
-- pages was in the HTML, which is about five thousand words that needed a
-- developer and a deployment to change a comma in.
--
-- This migration does three things:
--
--   1. page_blocks gains `items jsonb`, because a repeating thing is not prose.
--   2. 135 blocks are seeded with the words that are on the pages TODAY.
--   3. public_page carries `items` so the site can read them.
--
-- WHY THE SEED IS GENERATED AND NOT TYPED
--
-- Every row below came off the markup by db/tools/extract-page-copy.py, which
-- holds one hand written mapping of element to block key and generates the seed,
-- the site's BLOCK_MAP and the admin app's PAGES from it. Five thousand words
-- retyped is five thousand chances to drop one, and a dropped word would not be
-- noticed: the page would go on rendering its fallback and look exactly right.
-- Generated, a block and the fallback it overrides are identical by
-- construction.
--
-- Re-run the extractor against the bundle rather than editing this file.
--
-- ON CONFLICT DO NOTHING, DELIBERATELY. A second run must never overwrite copy
-- somebody has edited in the admin app. Re-seeding a changed block is a decision
-- and not a side effect of running a migration twice. It is also what protects
-- the four blocks that already exist: `intro`, `phone` and `address` are in the
-- seed because the site has to go on rendering them, and their live values win.
--
-- EVERYTHING IS SEEDED AS PUBLISHED, because these words are already on the
-- site. Seeded as drafts, the first thing this migration would do is take the
-- whole site's copy down to its fallbacks, which look identical, so nobody would
-- notice until somebody edited a block and wondered why nothing changed.
--
-- WHAT THIS DOES NOT TOUCH
--
-- The privacy notice. 2,124 words of legal text going to a solicitor, where the
-- version that was approved matters and a deploy is a record of exactly what
-- changed and when. A page_blocks row is not that.
--
-- The grades, the fees, the hero statements and the news: already content, in
-- their own tables, and they stay there.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. items
-- -----------------------------------------------------------------------------
-- A block is prose in `body` OR a list in `items`, never both, and the document
-- type in the admin app decides which. JSON in the text column would have worked
-- and would have meant nothing could tell the two apart without parsing it,
-- which is how a rich text editor ends up showing somebody a bracket.
alter table public.page_blocks add column if not exists items jsonb;

comment on column public.page_blocks.items is
  'A repeating block: cards, steps, questions, bullets, or the one or two '
  'buttons at the foot of a section. Each item is an object whose keys the '
  'document type names. Null for a prose block.';

-- The rule said out loud rather than left to everybody remembering it. An empty
-- string counts as no body, because a browser sending a cleared field sends ''
-- about as often as it sends null.
alter table public.page_blocks drop constraint if exists page_blocks_body_or_items;
alter table public.page_blocks add  constraint page_blocks_body_or_items
  check (not (coalesce(body, '') <> '' and items is not null));


-- -----------------------------------------------------------------------------
-- 2. The seed
-- -----------------------------------------------------------------------------
-- A PLAIN INSERT, AND THE FIRST VERSION OF THIS MIGRATION WAS NOT.
--
-- It lifted FORCE row level security for the length of the inserts and put it
-- back afterwards, copying seeds/optional_starting_lists.sql, on the reasoning
-- that forcing binds the table owner and the role running a migration on a
-- hosted project is not a superuser.
--
-- Both halves of that were wrong here. FORCE has been OFF on every table in
-- this database since 0018, so there was nothing to lift. And putting it
-- "back" would have turned it ON for the first time, on this table, in the one
-- migration whose entire purpose is to put the public site's words into it.
--
-- 0018 spells out what that does, and it is worth repeating because this is the
-- table it would have happened to: the public views are owned by the same role
-- that forcing binds, so under FORCE public_page returns NOTHING to an
-- anonymous visitor. Every public page would have fallen back to its markup,
-- which looks identical, and the first symptom would have been somebody editing
-- a block and nothing changing on the site.
--
-- It did not show in the mirror because run_tests.sh runs
-- seeds/optional_starting_lists.sql after the migrations, and the last block of
-- that file un-forces every table in public and restricted. So the suite was
-- green while the migration was wrong, repaired by an OPTIONAL seed that
-- staging and live never run. An assertion that passes because something
-- downstream undid the fault is not protection. Test 11 now asserts what
-- actually matters instead: that anon can read the seeded copy.

insert into public.page_blocks (page_key, block_key, body, items, status, sort_order)
values
  ('home', 'hero_eyebrow', 'The institute for asbestos professionals', null, 'published', 0),
  ('home', 'hero_lede', 'AMI is the professional body for individuals working in asbestos removal, analysis, consultancy and management. Prove your competence and join a recognised community.', null, 'published', 10),
  ('home', 'hero_actions', null, '[{"label": "Become a member", "href": "/apply"}, {"label": "Explore membership grades", "href": "/membership#grades"}]'::jsonb, 'published', 20),
  ('home', 'hero_badge', 'Recognised best practice', null, 'published', 30),
  ('home', 'quick_cards', null, '[{"icon": "award", "title": "Become a member", "body": "Join at the grade that matches your experience and demonstrate your competence to employers and clients.", "href": "/apply", "link_label": "Join AMI →"}, {"icon": "book", "title": "Continuing Professional Development (CPD)", "body": "How the AMI scheme works, what counts towards it, and how points are earned and recorded.", "href": "/cpd-scheme", "link_label": "About CPD →"}, {"icon": "list", "title": "Members register", "body": "Browse the register of qualified asbestos professionals and member organisations.", "href": "/register", "link_label": "Open the register →"}]'::jsonb, 'published', 40),
  ('home', 'news_eyebrow', 'News & events', null, 'published', 50),
  ('home', 'news_heading', 'The latest from AMI', null, 'published', 60),
  ('home', 'news_link', null, '[{"label": "All news & events", "href": "/news"}]'::jsonb, 'published', 70),
  ('home', 'band_eyebrow', 'Best practice, recognised', null, 'published', 80),
  ('home', 'band_heading', 'Setting the standard for asbestos professionals across the UK', null, 'published', 90),
  ('home', 'band_body', '<p>From removal and analysis to surveying and duty holder management, AMI membership shows you work to a recognised standard.</p>', null, 'published', 100),
  ('home', 'band_link', null, '[{"label": "About AMI", "href": "/about"}]'::jsonb, 'published', 110),
  ('home', 'grades_eyebrow', 'Membership', null, 'published', 120),
  ('home', 'grades_heading', 'A grade for every stage of your career', null, 'published', 130),
  ('home', 'grades_lede', '<p>Membership recognises your knowledge, experience and commitment to best practice.</p>', null, 'published', 140),
  ('home', 'grades_link', null, '[{"label": "Compare all grades & fees", "href": "/membership#grades"}]'::jsonb, 'published', 150),
  ('home', 'cta_heading', 'Ready to be recognised?', null, 'published', 160),
  ('home', 'cta_body', '<p>Applications are read by the AMI office. Nothing is charged online and nothing is decided automatically.</p>', null, 'published', 170),
  ('home', 'cta_link', null, '[{"label": "Become a member", "href": "/apply"}]'::jsonb, 'published', 180),
  ('about', 'banner_heading', 'About the Asbestos Management Institute', null, 'published', 190),
  ('about', 'banner_lede', 'The professional body recognising and promoting best practice among the individuals who manage asbestos risk across the UK.', null, 'published', 200),
  ('about', 'intro_heading', 'Who we are', null, 'published', 210),
  ('about', 'intro', '<p>AMI is the professional body for individuals working across the asbestos industry, from removal and analysis to surveying, consultancy and duty holder management. It exists to raise standards, recognise competence and support its members throughout their careers.</p> <p>Membership recognises competence in people rather than in companies, and it is assessed on evidence. It is maintained by continuing professional development recorded each year against a published requirement, and it is open to independent verification by anybody who needs to rely on it.</p>', null, 'published', 220),
  ('about', 'intro_link', null, '[{"label": "Explore membership", "href": "/membership"}]'::jsonb, 'published', 230),
  ('about', 'glance_heading', 'At a glance', null, 'published', 240),
  ('about', 'glance', null, '[{"text": "Membership assessed on evidence"}, {"text": "Wholly focused on asbestos"}, {"text": "A published CPD requirement"}, {"text": "UK wide membership"}, {"text": "Guidance and HSE resources"}, {"text": "Members forum and events"}]'::jsonb, 'published', 250),
  ('about', 'purpose_eyebrow', 'What we stand for', null, 'published', 260),
  ('about', 'purpose_heading', 'Our purpose', null, 'published', 270),
  ('about', 'purpose_cards', null, '[{"icon": "award", "title": "Recognise", "body": "Grades and post nominals that give members credible, independent recognition of their competence."}, {"icon": "target", "title": "Promote", "body": "Clear standards and guidance that raise the quality and safety of asbestos work across the UK."}, {"icon": "people", "title": "Support", "body": "A community, continuing development and practical help so members can grow and stay current throughout their careers."}]'::jsonb, 'published', 280),
  ('about', 'practice_eyebrow', 'What we do', null, 'published', 290),
  ('about', 'practice_heading', 'Setting and sharing best practice', null, 'published', 300),
  ('about', 'practice_body', '<p>AMI brings the industry together to agree what good looks like, publishes practical guidance, and gives members the development and recognition they need to demonstrate it.</p><p>Through seminars, webinars and the Annual General Meeting, members stay current and connected across the whole sector.</p>', null, 'published', 310),
  ('about', 'practice_link', null, '[{"label": "Latest news", "href": "/news"}]'::jsonb, 'published', 320),
  ('about', 'cta_heading', 'Become part of AMI', null, 'published', 330),
  ('about', 'cta_body', '<p>Join the institute and demonstrate your commitment to best practice in asbestos management.</p>', null, 'published', 340),
  ('about', 'cta_link', null, '[{"label": "Apply for membership", "href": "/apply"}]'::jsonb, 'published', 350),
  ('membership', 'banner_heading', 'Membership and joining AMI', null, 'published', 360),
  ('membership', 'banner_lede', 'Recognition that shows employers, clients and duty holders you meet the standard for best practice in asbestos management.', null, 'published', 370),
  ('membership', 'intro_heading', 'Why join the Asbestos Management Institute', null, 'published', 380),
  ('membership', 'intro', '<p>AMI is the professional body for individuals across the asbestos industry, from removal and analysis to surveying, consultancy and duty holder management. Membership is a mark of competence and a commitment to continuing professional development.</p> <p>Whichever grade you join at, you become part of a recognised community with access to guidance, events and support, and you can use your membership to demonstrate your professional standing. Every current member appears on a public register that anybody can check.</p>', null, 'published', 390),
  ('membership', 'intro_links', null, '[{"label": "Start your application", "href": "/apply"}, {"label": "View the members register", "href": "/register"}]'::jsonb, 'published', 400),
  ('membership', 'benefits_heading', 'What every member gets', null, 'published', 410),
  ('membership', 'benefits', null, '[{"text": "A listing on the public members register"}, {"text": "AMI guidance notes and HSE resources"}, {"text": "Access to the members forum"}, {"text": "Webinars and AGM recordings"}, {"text": "A recorded CPD history"}, {"text": "Use of the AMI post nominals"}]'::jsonb, 'published', 420),
  ('membership', 'grades_eyebrow', 'Membership grades', null, 'published', 430),
  ('membership', 'grades_heading', 'Choose the grade that matches your experience', null, 'published', 440),
  ('membership', 'grades_lede', '<p>Each grade is awarded on assessed evidence of competence. Fees are billed annually and invoiced by the office.</p>', null, 'published', 450),
  ('membership', 'grades_link', null, '[{"label": "Apply for membership", "href": "/apply"}]'::jsonb, 'published', 460),
  ('membership', 'more_eyebrow', 'Member benefits', null, 'published', 470),
  ('membership', 'more_heading', 'More than a listing', null, 'published', 480),
  ('membership', 'more_body', '<p>Membership is a mark of competence you can show to employers, clients and duty holders, backed by guidance, continuing development and a community of peers.</p><p>Use your grade and post nominals to stand out, keep current through webinars and AGM sessions, and draw on the institute''s guidance when you need it.</p>', null, 'published', 490),
  ('membership', 'more_link', null, '[{"label": "Support and guidance", "href": "/support"}]'::jsonb, 'published', 500),
  ('membership', 'steps_eyebrow', 'How to join', null, 'published', 510),
  ('membership', 'steps_heading', 'Joining takes three steps', null, 'published', 520),
  ('membership', 'steps', null, '[{"title": "Choose your grade", "body": "Pick the grade that matches your experience. If you are not sure, apply anyway and the office will tell you which one fits."}, {"title": "Complete your application", "body": "Tell us about your role and experience and attach your CV, training records and qualifications. It takes about ten minutes."}, {"title": "Get confirmed", "body": "A person reads every application. Once it is approved you are added to the register and invoiced for the year."}]'::jsonb, 'published', 530),
  ('membership', 'steps_link', null, '[{"label": "Start your application", "href": "/apply"}]'::jsonb, 'published', 540),
  ('membership', 'faq_eyebrow', 'Questions', null, 'published', 550),
  ('membership', 'faq_heading', 'Membership questions', null, 'published', 560),
  ('membership', 'faq', null, '[{"question": "Who can join AMI?", "answer": "Membership is open to individuals working in or supporting the asbestos industry, including removal, analysis, surveying, consultancy and duty holder management. AMI recognises individuals rather than companies."}, {"question": "How much does membership cost?", "answer": "Fees vary by grade and are shown against each grade above. Membership is invoiced by the office once an application has been approved. The site does not take payment."}, {"question": "Can I move up a grade later?", "answer": "Yes. Membership grows with your career, and you can apply to move up a grade as your experience develops and your evidence supports it."}, {"question": "What is the CPD requirement?", "answer": "Members record continuing professional development each year against a published requirement. Points are earned by attending AMI events, completing assessments and logging your own development, and every entry is reviewed by the office."}, {"question": "Does my membership appear publicly?", "answer": "Every current member appears on the public register, so a client or duty holder can check a membership without having to ask you for proof. Your photograph appears on your profile only if you switch it on."}, {"question": "What happens if I let it lapse?", "answer": "A membership that is not current is removed from the public register. The office handles renewals by hand and will contact you before that happens."}]'::jsonb, 'published', 570),
  ('membership', 'cta_heading', 'Join AMI today', null, 'published', 580),
  ('membership', 'cta_body', '<p>Take the next step in your professional standing and become part of the Asbestos Management Institute.</p>', null, 'published', 590),
  ('membership', 'cta_link', null, '[{"label": "Start your application", "href": "/apply"}]'::jsonb, 'published', 600),
  ('cpd-scheme', 'banner_heading', 'Continuing Professional Development', null, 'published', 610),
  ('cpd-scheme', 'banner_lede', 'Membership says somebody was competent when they were assessed. CPD is what keeps that statement true.', null, 'published', 620),
  ('cpd-scheme', 'rule_eyebrow', 'The requirement', null, 'published', 630),
  ('cpd-scheme', 'rule_heading', 'Ten points a year, five of them core', null, 'published', 640),
  ('cpd-scheme', 'rule_body', '<p>Members at the grades that carry a CPD requirement record ten points across the year. At least five of those must come from core activities, which are the ones about asbestos technical competence. The remaining five come from the wider professional skills around the work.</p><p>The split matters more than the total. Ten points earned entirely from committee service and trade press would say nothing about whether somebody is still current on the technical work, which is the thing a client is relying on.</p><p>The year runs to the calendar year. Points are logged as activities happen rather than gathered up in December, and a member can see where they stand at any point.</p>', null, 'published', 650),
  ('cpd-scheme', 'counts_eyebrow', 'Earning points', null, 'published', 660),
  ('cpd-scheme', 'counts_heading', 'What counts', null, 'published', 670),
  ('cpd-scheme', 'counts', null, '[{"icon": "shield", "title": "Core activities", "body": "Asbestos technical competence. At least five points a year must come from this list.", "bullets": ["Assessed training course", "Unassessed training course", "Technical seminar or conference", "AMI webinar or recorded session", "Reading technical guidance, an approved code or a standard", "Site based learning or shadowing", "A technical assessment or examination passed"]}, {"icon": "person", "title": "Non core activities", "body": "The wider professional skills around the technical work.", "bullets": ["Regional or branch meeting", "Committee or working group service", "Mentoring or supervising somebody", "Writing or presenting on a technical subject", "Professional reading and trade press", "Management, commercial or communication training", "An in house briefing or toolbox talk delivered"]}]'::jsonb, 'published', 680),
  ('cpd-scheme', 'how_eyebrow', 'Recording', null, 'published', 690),
  ('cpd-scheme', 'how_heading', 'How a point gets onto the record', null, 'published', 700),
  ('cpd-scheme', 'how', null, '[{"icon": "pencil", "title": "The member logs it", "body": "A member records an activity from their own CPD screen, choosing the type and saying what they did. It arrives pending."}, {"icon": "check", "title": "The office accepts it", "body": "Nothing counts towards a total until the AMI office has accepted it. A member cannot accept their own entry, and cannot decide whether it is core."}, {"icon": "clock", "title": "Some points arrive on their own", "body": "Where AMI arranged the activity and knows who attended, the points are awarded automatically and need no evidence from the member."}]'::jsonb, 'published', 710),
  ('cpd-scheme', 'how_note_heading', 'Every point says how it arrived', null, 'published', 720),
  ('cpd-scheme', 'how_note_body', '<p>The record holds the source of each point as well as the point itself, so a line can always answer where it came from, whether the member declared it or AMI awarded it. That is the difference between a CPD figure and a list of claims, and it is the reason a figure can be published at all.</p>', null, 'published', 730),
  ('cpd-scheme', 'record_pill', '🔒 Members only', null, 'published', 740),
  ('cpd-scheme', 'record_heading', 'Your own record', null, 'published', 750),
  ('cpd-scheme', 'record_body', '<p>Members log activities, see where they stand against this year''s requirement and print a personal CPD record at any time, from the CPD screen behind the member login.</p><p>The printed record lists every activity with its date, its type and how the point was recorded, which is what an employer or an assessor is usually asking for.</p>', null, 'published', 760),
  ('cpd-scheme', 'record_link', null, '[{"label": "Sign in to your CPD record", "href": "/login"}]'::jsonb, 'published', 770),
  ('cpd-scheme', 'cta_heading', 'Not a member yet?', null, 'published', 780),
  ('cpd-scheme', 'cta_body', '<p>Membership is assessed on evidence and kept current through CPD. Apply at the grade that matches your experience.</p>', null, 'published', 790),
  ('cpd-scheme', 'cta_link', null, '[{"label": "Apply for membership", "href": "/apply"}]'::jsonb, 'published', 800),
  ('cscs-cards', 'banner_heading', 'CSCS cards', null, 'published', 810),
  ('cscs-cards', 'banner_lede', 'Cards for asbestos removal operatives, supervisors and managers, and for asbestos surveyors and analysts, under the AMI Skills Card Scheme.', null, 'published', 820),
  ('cscs-cards', 'scheme_eyebrow', 'AMI Skills Card Scheme', null, 'published', 830),
  ('cscs-cards', 'scheme_heading', 'A nationally recognised construction skills card scheme', null, 'published', 840),
  ('cscs-cards', 'scheme_body', '<p>CSCS cards for asbestos removal operatives, supervisors and managers, and for asbestos surveyors and analysts, are available under the AMI Skills Card Scheme.</p><p>This scheme is a nationally recognised construction skills card scheme carrying the CSCS logo. By carrying the CSCS logo the cards provide a means to verify that people who want to work on construction sites have the necessary training, qualifications and experience for the type of work they carry out.</p><p>All physical smartcards issued by ARCA use smart technology and contain an electronic chip. This can be used to check the identity of the card holder and, for example, when ARCA updates a card holder''s record with ‘successfully completed operative annual refresher’ this will automatically update the chip in the card. Virtual smartcards can also be issued to applicants, at no additional cost.</p>', null, 'published', 850),
  ('cscs-cards', 'scheme_link', null, '[{"label": "Download the card leaflet (PDF)", "href": "/assets/AM025-V2604-ARCA-AMI-Skills-Cards-Flyer.pdf"}]'::jsonb, 'published', 860),
  ('cscs-cards', 'which_eyebrow', 'The cards', null, 'published', 870),
  ('cscs-cards', 'which_heading', 'Which card, and where to apply', null, 'published', 880),
  ('cscs-cards', 'cards', null, '[{"icon": "award", "title": "Professionally Qualified Person", "body": "The AMI Skills Card for Professionally Qualified Person.", "href": "https://www.arca.org.uk/cscs-cards", "link_label": "Apply via ARCA"}, {"icon": "shield", "title": "Asbestos removal", "bullets": ["<b>Asbestos Removal Manager</b><br/>Temporary red cards and the black manager card.", "<b>Asbestos Removal Supervisor</b><br/>Temporary red cards and the gold supervisor card.", "<b>Asbestos Removal Operative</b><br/>Temporary red cards and the blue skilled worker card."], "href": "https://www.arca.org.uk/cscs-cards", "link_label": "Apply via ARCA"}, {"icon": "search", "title": "Asbestos surveying and analysis", "bullets": ["<b>Asbestos Analyst</b><br/>Temporary red and five year Academically Qualified Person white cards.", "<b>Asbestos Surveyor</b><br/>Temporary red and five year Academically Qualified Person white cards.", "<b>Asbestos Analyst and Surveyor</b><br/>Temporary red and five year Academically Qualified Person white cards."], "href": "https://www.atac.org.uk/asbestos-testing-consultancy-association-cscs-cards", "link_label": "Apply via ATaC"}]'::jsonb, 'published', 890),
  ('cscs-cards', 'cta_heading', 'Membership and cards are separate', null, 'published', 900),
  ('cscs-cards', 'cta_body', '<p>A CSCS card records the training and experience needed to work on a construction site. AMI membership records assessed individual competence. Many people hold both.</p>', null, 'published', 910),
  ('cscs-cards', 'cta_link', null, '[{"label": "About AMI membership", "href": "/membership"}]'::jsonb, 'published', 920),
  ('support', 'banner_heading', 'Support and guidance', null, 'published', 930),
  ('support', 'banner_lede', 'Practical, current support for AMI members, drawn from across the industry and from the regulator.', null, 'published', 940),
  ('support', 'resources_eyebrow', 'Resources', null, 'published', 950),
  ('support', 'resources_heading', 'Guidance and member resources', null, 'published', 960),
  ('support', 'resources', null, '[{"icon": "document", "title": "AMI guidance notes", "body": "Clear, practical guidance written for asbestos professionals and duty holders.", "href": "/news?kind=guidance"}, {"icon": "external", "title": "HSE publications", "body": "Straight to the regulator''s own guidance and approved codes of practice.", "href": "https://www.hse.gov.uk/asbestos/"}, {"icon": "video", "title": "Webinars and AGM", "body": "Recorded seminars, webinars and Annual General Meeting sessions.", "href": "/videos"}, {"icon": "calendar", "title": "Events and seminars", "body": "Everything in the AMI calendar, from regional meetings to the AGM.", "href": "/news?kind=event"}, {"icon": "award", "title": "Continuing development", "body": "What the CPD requirement asks for, how points are earned and how they are recorded.", "href": "/cpd-scheme"}, {"icon": "person", "title": "Check a membership", "body": "The public register, so a client or duty holder can confirm a membership themselves.", "href": "/register"}]'::jsonb, 'published', 970),
  ('support', 'forum_pill', '🔒 Members only', null, 'published', 980),
  ('support', 'forum_heading', 'The members forum', null, 'published', 990),
  ('support', 'forum_body', '<p>Discuss issues, share knowledge and ask questions across the AMI community. The forum sits behind your member login and is open to every current member.</p><p>It is not moderated in advance. Posts are checked against a word list before they publish, and members can edit or remove their own post until somebody has replied to it.</p>', null, 'published', 1000),
  ('support', 'forum_link', null, '[{"label": "Sign in to the forum", "href": "/login"}]'::jsonb, 'published', 1010),
  ('support', 'recent_eyebrow', 'Latest guidance', null, 'published', 1020),
  ('support', 'recent_heading', 'Recently published', null, 'published', 1030),
  ('support', 'cta_heading', 'Not a member yet?', null, 'published', 1040),
  ('support', 'cta_body', '<p>Join AMI for the guidance library, the members forum, recorded sessions and a recorded CPD history.</p>', null, 'published', 1050),
  ('support', 'cta_link', null, '[{"label": "Apply for membership", "href": "/apply"}]'::jsonb, 'published', 1060),
  ('contact', 'banner_heading', 'Contact us', null, 'published', 1070),
  ('contact', 'banner_lede', 'Questions about membership, guidance or the register? Send a message and the office will get back to you.', null, 'published', 1080),
  ('contact', 'form_heading', 'Send a message', null, 'published', 1090),
  ('contact', 'form_lede', 'The office reads everything and replies within two working days.', null, 'published', 1100),
  ('contact', 'form_note', 'AMI uses what you send here to answer you and for nothing else.', null, 'published', 1110),
  ('contact', 'phone', 'The office number goes here', null, 'published', 1120),
  ('contact', 'address', 'Asbestos Management Institute<br/>United Kingdom', null, 'published', 1130),
  ('contact', 'hours', 'Monday to Friday, 9am to 5pm', null, 'published', 1140),
  ('contact', 'checking', 'You do not need to ask. The <a href="/register">public register</a> confirms any current membership.', null, 'published', 1150),
  ('apply', 'banner_eyebrow', 'Membership', null, 'published', 1160),
  ('apply', 'banner_heading', 'Application for membership', null, 'published', 1170),
  ('apply', 'banner_lede', 'Complete this form and attach copies of the relevant certificates, diplomas and qualifications. Your application will be assessed and the appropriate grade of membership confirmed. An invoice for the fee for that grade will then be sent to the address you give at the bottom of this form.', null, 'published', 1180),
  ('apply', 'banner_note', '<a href="/contact" style="color:var(--link);font-weight:700">Contact head office</a> for further details if required.', null, 'published', 1190),
  ('apply', 'consent', '<p>By submitting this form you confirm that the information given is correct and complete, and that the documents attached are your own.</p>', null, 'published', 1200),
  ('apply', 'address_hint', 'Your own address, including the postcode. The invoice address is asked for separately at the bottom.', null, 'published', 1210),
  ('news', 'banner_heading', 'News and events', null, 'published', 1220),
  ('news', 'banner_lede', 'The latest from the institute, and everything coming up in the AMI calendar.', null, 'published', 1230),
  ('news', 'main_eyebrow', 'Latest', null, 'published', 1240),
  ('news', 'main_heading', 'From the institute', null, 'published', 1250),
  ('news', 'events_heading', 'Upcoming events', null, 'published', 1260),
  ('news', 'events_sub', 'The AMI calendar', null, 'published', 1270),
  ('videos', 'banner_eyebrow', 'Recordings', null, 'published', 1280),
  ('videos', 'banner_heading', 'Video library', null, 'published', 1290),
  ('videos', 'banner_lede', 'Recorded webinars, seminars and AGM sessions, hosted on Vimeo and gathered here.', null, 'published', 1300),
  ('videos', 'all_eyebrow', 'All recordings', null, 'published', 1310),
  ('videos', 'all_heading', 'Webinars, seminars and events', null, 'published', 1320),
  ('register', 'banner_heading', 'AMI members register', null, 'published', 1330),
  ('register', 'banner_lede', 'Every current member who has chosen to be listed. Somebody who is not here is not a current AMI member.', null, 'published', 1340)
on conflict (page_key, block_key) do nothing;


-- -----------------------------------------------------------------------------
-- 3. public_page carries items
-- -----------------------------------------------------------------------------
-- `items` is appended at the END of the select list on purpose. A create or
-- replace cannot add a column in the middle of a view, and DROPPING a view drops
-- every grant on it, which is a thing that gets noticed in production rather
-- than in a migration. Appended, the replace is legal, the grants are untouched
-- and nothing has to be restated.
--
-- The filter is unchanged: the public sees published blocks only, which is what
-- makes the admin app's draft and publish mean anything.
create or replace view public.public_page as
  select b.page_key, b.block_key, b.body, b.sort_order, b.items
    from public.page_blocks b
   where b.status = 'published'
   order by b.page_key, b.sort_order;

-- Said again rather than assumed. A replace keeps the grants, and this costs
-- nothing and removes the question.
grant select on public.public_page to anon, authenticated;
