# 0048: CPD from ARCA's records in Dynamics

Database 35, admin 30, site 71, and the new Worker ami-dynamics-sync 1.
Item 5 of the CPD automation plan, as Steve settled it on 31 October: three
named views, and a new read-only app registration.

## What it does

A Worker of its own, `ami-dynamics-sync`, reads three system views in ARCA's
Dynamics three times each weekday, or when Sync now is pressed:

- `AMI Sync: Regional meetings`, earning `regional_meeting_2027` (1 non core)
- `AMI Sync: ARCA AGM`, earning `arca_agm` (1 non core)
- `AMI Sync: Training completions`, earning `arca_training` (1 core), once the
  office has said the course counts

The Worker hands rows to the database exactly as Dynamics gave them. The
database, not the Worker, knows which column is which (`dynamics_feeds`, set by
the office from the column names the sync reports), matches people, and awards.

## The rules, and where they live

- Rows are written only by `dynamics_record`, granted to service_role, into a
  run that is running and under twenty minutes old. `dynamics_run_begin` takes
  an advisory lock and refuses to begin on top of a run; a run stuck for twenty
  minutes is marked failed, so it never blocks the next.
- Sync now: `dynamics_sync_request` as the staff member, then the Worker begins
  exactly that run. Nothing in an address can start a sync.
- Matching is `app.feed_who`, Zoom's rule from 0042 taken out into one function:
  a remembered link, else exactly one current membership with the address.
  `feed_link` and `feed_dismiss` are restated to settle both feeds: an address
  linked or dismissed from either is linked or dismissed for both.
- Awards go through `app.award_cpd` with the session's event key, so reading
  the same rows again awards nothing, and a recording given the same key awards
  once. The receipt email is the usual `cpd_awarded`.
- Nothing before `cpd_feeds_from` (2027-01-01) is awarded. A row gone from a
  view, or changed, never moves or removes an award.
- A row Dynamics has not changed is not written again, so the audit log holds
  changes, not three copies a day.
- Training: every course seen goes into `dynamics_courses`. Completions wait
  (`course_waiting`) until `dynamics_course_decide`; Counts awards everybody
  waiting at once. A course with awards cannot be switched to Does not count.
- `cpd_feed_sessions` gains regional meetings and the AGM (the AGM is still
  never listed as missed), so the monthly email lists missed regional meetings.

## Order

1. Run `supabase/migrations/0048_dynamics_feed.sql` on staging.
2. Run `tests/39_dynamics_feed_supabase.sql`: `ALL 52 TESTS PASSED`.
3. Upload site 71, then admin 30.
4. The rest is `ami-dynamics-sync/README.md`: the app registration, the role,
   the views, the Worker, the binding, and the first sync.

## Tests

- 39 (52, database): rights, nothing read until columns are named, matching,
  London dates, before the scheme, read twice, shared links with Zoom, courses,
  the AGM, the monthly email's sessions, runs and overlap.
- 40 (26, JavaScript): the Worker against pretend Microsoft, Dynamics and
  database; only reads from Dynamics; names never values as columns; the run is
  logged whatever fails; Sync now refused for a member; and the site's door.
- 41 (15, browser): the three admin screens under the real policy.

Database total 749.
