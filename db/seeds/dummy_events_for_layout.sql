-- =============================================================================
-- DUMMY. Seven calendar events, for looking at the layout. Not a migration, not
-- run automatically, and NOT to be left on the live site.
--
--   Supabase SQL editor, or:  psql -d ami -f seeds/dummy_events_for_layout.sql
--
-- Same discipline as the dummy news. Every slug begins `zz-demo-`, so the whole
-- lot comes out again with the one statement at the bottom, and a real event
-- cannot be caught by it because a real event does not carry the prefix.
--
-- The seven are chosen to exercise the page rather than just to fill it:
--
--   five upcoming, at spreading intervals, so the calendar panel on the right of
--     the news page has something to sort and the date blocks show different
--     months rather than all reading the same
--   one members only, which SHOULD NOT APPEAR anywhere on the public site. If it
--     does, the filter on public_content is not doing its job and that is worth
--     knowing before the site goes live
--   one already past, which should appear in the article list but NOT in the
--     calendar panel, because the panel shows what has not happened yet
--
-- Dates are relative to the day you run this, so it stays current however long
-- it sits there, and are written in Europe/London rather than UTC so a 9.30am
-- start says 9.30am on the page through the summer as well as the winter.
--
-- No image_path is set. The site falls back to a stock photograph keyed by a
-- stable hash of the slug, so nothing needs uploading first.
-- =============================================================================

alter table public.events no force row level security;

insert into public.events
  (slug, title, kind, starts_at, ends_at, location, description,
   capacity, members_only, status, published_at)
values

-- ---------- upcoming ----------
('zz-demo-autumn-technical-seminar',
 'Autumn technical seminar',
 'Seminar',
 ((current_date + 9)  + time '09:30') at time zone 'Europe/London',
 ((current_date + 9)  + time '16:00') at time zone 'Europe/London',
 'Nottingham',
 'A full day on analysis, four stage clearance and the questions that come up on site. Core CPD.',
 120, false, 'published', now() - interval '5 days'),

('zz-demo-duty-to-manage-webinar',
 'Duty to manage: what a good management plan looks like',
 'Webinar',
 ((current_date + 21) + time '12:30') at time zone 'Europe/London',
 ((current_date + 21) + time '13:30') at time zone 'Europe/London',
 'Online',
 'An hour at lunchtime on management plans, registers and the questions duty holders ask.',
 null, false, 'published', now() - interval '3 days'),

('zz-demo-north-west-regional-meeting',
 'North West regional meeting',
 'Regional meeting',
 ((current_date + 38) + time '18:00') at time zone 'Europe/London',
 ((current_date + 38) + time '20:30') at time zone 'Europe/London',
 'Manchester',
 'An evening meeting for members in the North West, with a technical item and time to talk.',
 60, false, 'published', now() - interval '9 days'),

('zz-demo-surveying-refresher-day',
 'Surveying refresher day',
 'Training',
 ((current_date + 74) + time '09:00') at time zone 'Europe/London',
 ((current_date + 74) + time '16:30') at time zone 'Europe/London',
 'Birmingham',
 'Management, refurbishment and demolition surveys, and where the three are confused in practice.',
 40, false, 'published', now() - interval '12 days'),

('zz-demo-annual-general-meeting',
 'Annual General Meeting and dinner',
 'AGM',
 ((current_date + 132) + time '14:00') at time zone 'Europe/London',
 ((current_date + 132) + time '23:00') at time zone 'Europe/London',
 'Coventry',
 'The AGM, followed by the annual dinner. Papers are circulated to members beforehand.',
 200, false, 'published', now() - interval '20 days'),

-- ---------- should be invisible to the public ----------
-- If this one shows up on /news, the members_only filter on public_content has
-- stopped working. That is the point of it being here.
('zz-demo-members-only-briefing',
 'Members only briefing: the new CPD year',
 'Briefing',
 ((current_date + 45) + time '13:00') at time zone 'Europe/London',
 ((current_date + 45) + time '14:00') at time zone 'Europe/London',
 'Online',
 'For members only. Should never appear on the public news page or in the calendar panel.',
 null, true, 'published', now() - interval '2 days'),

-- ---------- already happened ----------
-- Should appear in the list of items and NOT in the calendar panel, which only
-- shows what is still to come.
('zz-demo-summer-forum-past',
 'Summer members forum',
 'Regional meeting',
 ((current_date - 24) + time '18:00') at time zone 'Europe/London',
 ((current_date - 24) + time '20:00') at time zone 'Europe/London',
 'Leeds',
 'An evening meeting held in the summer. Here to prove the calendar shows only what is ahead.',
 60, false, 'published', now() - interval '60 days');

-- -----------------------------------------------------------------------------
-- WHAT TO LOOK FOR
-- -----------------------------------------------------------------------------
--   /news                    Upcoming events panel lists FIVE, soonest first,
--                            not the members only one and not the past one
--   /news?kind=event         six items: the five ahead and the one behind
--   the Events filter pill   wears the held white and red state when chosen
--
-- -----------------------------------------------------------------------------
-- TAKING THEM OUT AGAIN
-- -----------------------------------------------------------------------------
--   delete from public.events where slug like 'zz-demo-%';
--
-- And, if the dummy news is still in as well:
--
--   delete from public.news_articles where slug like 'zz-demo-%';
--
-- Worth doing before the site goes anywhere near a member. These read
-- plausibly on purpose, which makes them harder to spot than obvious filler.
-- An AGM in the calendar that nobody has booked a room for is the kind of
-- placeholder that gets believed.
-- -----------------------------------------------------------------------------
