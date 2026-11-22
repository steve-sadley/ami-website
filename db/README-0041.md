# 0041  Earn CPD on the site: read and answer, watch and answer

Site 64, admin 21, database 26.

## What this release is

**For the office**, a new screen in the admin app under CPD: **CPD to read and
watch**. Each item is something to read (a Technical Review, an ARCA News
update) or a recording to watch (an AMI Seminar, an ARCA regional meeting), and:

- the activity it counts as, which sets its points (a Technical Review takes
  anything from half a point to two)
- questions, each with two to six answers and the right one ticked
- a pass mark (80%) and attempts allowed (2: one retake)
- for a recording, its Vimeo number and how much must be watched before the
  questions open (80%)
- an event key, for a recording of something members could attend live, so
  nobody earns the same event twice

**For members**, a new page, **Earn CPD**, in the members bar beside My CPD.
It lists what is still to do and what is done. A member reads or watches,
answers, and is told their score straight away. 80% or more and the points go
onto their record at once, marked as recorded automatically, with an email
saying what was earned and where they now stand. Under 80% they can try once
more.

**A new order every time.** Each time the questions open, the questions are
shuffled and so are the answers within each one, so "number three is B" is no
use to anybody else, or to the same member on their retake. The page puts the
choices back into the stored order before sending, so the marking is unchanged.

**The right answers never reach a browser.** Members see items through a view
that leaves them out, and the database does the marking. A member is told how
many they got right, never which.

Also fixed: the CPD receipt and reminder emails both said "you can switch this
off on your preferences page", which stopped being true at 0039 and 0034.

## Run it in this order

1. **Migration 0041** in the SQL editor.
2. **Test 24**, `tests/24_cpd_learning_supabase.sql`, Run without RLS. Expect
   `ALL 32 TESTS PASSED`.
3. **Site 64**, then **admin 21** (tag V21). Site 64 replaces 63, which was
   never deployed.

## Then check

1. **Admin, CPD, CPD to read and watch, New.** Write a short Technical Review:
   a title, Read, Counts as Technical Review, 1 point, a paragraph of text, two
   questions with the right answers ticked, status Published. Save.
2. **On the site as the test member, Earn CPD.** It is listed. Open it, read it,
   answer one question wrongly on purpose and send: it gives your score and
   offers one more try. The questions and answers are in a different order
   from the first time.
3. **Answer both correctly and send.** It says 1 point core has gone onto your
   record. **My CPD** shows it as recorded automatically, and the test member's
   inbox (or the email queue in the admin app) has the receipt.
4. **Archive the test item** in the admin app, and reject or leave the test
   point as you prefer; it is the test member's.

## Checked here

`run_tests.sh` gives 512 database tests and `tools/replay-staging-order.sh 0040`
passes in staging's order. Test 24 was proved by putting the answers back into
the members' view on purpose: the check that no question reaching a member
carries its answer went red.
