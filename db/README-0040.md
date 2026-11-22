# 0040  The CPD scheme page follows the activity types

Site 62, admin 20, database 25.

Steve, 30 October: the web pages should reflect the CPD ticked in the admin.

The two "what counts" cards on /cpd-scheme now list the activity types that
are switched on in the admin app's **CPD activity types** screen, core in the
first card and non core in the second, each with what it is worth
("AMI Seminar · 3 points", "Technical Review · 0.5 to 2 points"). Switch one
off, rename it or change its points, and the page follows on the next load.

The card headings and words stay editable on the Pages screen. Their bullet
lists are no longer offered there, because the page would ignore them; the
editor says where they come from instead. The two cards cannot be reordered,
because the first is always core.

If the list cannot be read, the page keeps the list in its markup rather than
showing an empty card.

## Run it in this order

1. **Migration 0040** in the SQL editor.
2. **Test 23**, `tests/23_public_cpd_activities_supabase.sql`, Run without
   RLS. Expect `ALL 8 TESTS PASSED`.
3. **Site 62**, then **admin 20** (tag V20).

## Then check

1. Open **/cpd-scheme** signed out. The first card lists AMI Council of
   Management or Technical Committee meeting, AMI AGM, AMI Seminar, Technical
   Review and ARCA training course, each with its points. The second lists the
   non core nine.
2. In the admin app, **CPD activity types**, switch **Self Directed Learning**
   off and save. Reload /cpd-scheme: it has gone from the second card.
3. **Switch it back on.**
4. **Pages, CPD scheme, What counts cards.** Each card says its list comes from
   CPD activity types, and there are no arrows to reorder them.

## Checked here

`tools/replay-staging-order.sh 0039` (staging's real order, with the starting
lists run where they were in August, and the new migration run twice) passes
every suite, as does `run_tests.sh`: 480 database tests.
