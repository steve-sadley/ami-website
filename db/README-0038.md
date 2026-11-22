# 0038  The CPD scheme for 2027

Site 61, admin 19, database 23. Migrations 0038 and 0039.

## What this release is

The scheme agreed on 30 October (AMI_CPD_Proposal.docx) is now how the site
works.

- **Points come from the activity.** A member chooses what they did and the
  form says what it is worth and whether it is core. There is no points box any
  more. The database sets the value whatever the browser sends.
- **A reflection following a training course needs 500 words.** A live count
  under the box; Send stays off until it is reached; the database counts again.
- **Activities that arrive on their own cannot be logged by hand.** AMI
  committee, AGM and Seminar, ARCA training and the ARCA AGM, Technical Reviews
  and ARCA News. They are switched to "Member logs it: off".
- **Practice of Management is once a year.**
- **Evidence is required** for an external course, a qualification, an article
  and an ACAD regional meeting.
- **A CPD receipt goes out for every point earned and cannot be switched off**
  (0039, Steve's decision on 30 October). The switch is gone from /profile and
  /preferences, and a trigger holds it on, exactly as 0034 did for the reminder.

The office can change every figure on the CPD activity types screen. The CPD
review queue shows the reflection, its word count, and a flag when evidence is
needed and none was attached.

The fourteen activity types from August are switched off, not deleted.

## Run it in this order

1. **Migration 0038**, then **migration 0039**, in the SQL editor.
2. **Test 22**, `tests/22_cpd_scheme_2027_supabase.sql`, Run without RLS. Expect
   `ALL 30 TESTS PASSED`.
3. **Tests 01, 02, 04, 06 and 10 again.** 01, 02, 04 and 06 use test activity
   types of their own now, because a member can no longer log the August ones;
   06 and 10 had their receipt checks inverted in place for 0039, so the files
   record that a decision moved. Expect 75, 30, 51, 50 and 16.
4. **Site 61**, then **admin 19** (tag V19).

## Then check

1. **Admin, CPD activity types.** Fourteen new rows with points, and the old
   fourteen with active off.
2. **On the site, signed in as a test member, My CPD, Log an activity.** The
   list has no AMI Seminar or Technical Review in it. Choose Reflection
   following a training course: it says 2 points, non core, and a box opens
   with "0 of 500 words" and Send greyed out.
3. **Choose External training course and press Send without a file.** It asks
   for evidence.
4. **My profile.** There is no CPD receipt switch any more.

## Not in this release, and next

The read and answer and watch and answer items, Zoom, Dynamics, the AI review
and the monthly email. See `claude/ami-cpd-automation-plan.md`.

The CPD scheme page on the site still lists the old activities. It is
editable on the Pages screen, CPD scheme.

## Also changed

`run_tests.sh` only ran test files numbered 00 to 19. File 22 would have been
skipped without a word. It now runs every numbered file.

## The first upload failed on staging, and why

`check constraint "cpd_activity_value" ... is violated by some row`. The rule
that every switched on activity has a value was added BEFORE the fourteen August
types were switched off, and on staging they were switched on and valueless at
that moment. Nothing was changed: the SQL editor runs the file as one
transaction, so the failure undid all of it.

The mirror passed because `run_tests.sh` seeds the starting lists AFTER every
migration, so there the table was empty when the rule arrived. Fixed by
switching them off first, and by switching off and naming anything else with
no value rather than failing. `log_cpd` is also now create or replace, so the
file really can be run twice.

`tools/replay-staging-order.sh 0037` now rebuilds a mirror in staging's order
(migrations, then the starting lists as they were run in August, then the new
migrations twice, then every suite). It passes. Run it before handing over any
migration that touches a table the starting lists fill.
