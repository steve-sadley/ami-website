# 0047  The monthly CPD email

Admin 29, database 34. The site is unchanged (70).

Item 6 of the plan. On the first working day of each month, every current
member whose grade requires CPD gets one email. Members cannot switch it off.
It replaces the monthly reminder, which is not scheduled and must not be.

## What it says

- where they stand this year, core and non core, and what is still needed
- the AMI seminars and webinars held last month that they did not attend,
  each with a link to its recording and questions where there is one (ARCA
  regional meetings join this list when the Dynamics feeds are built)
- the ARCA AGM is never listed as missed, but every email says attending it
  earns CPD points
- up to five things they can read or watch on the site now and the points each
  earns, with links to Earn CPD and to log an activity

Nothing from before the scheme starts (1 January 2027) is listed as missed.
The wording is the email template `cpd_monthly`, which a super user can change;
the two lists are built by the database and put where the template says.

**The first working day** is the first weekday that is not on the new **Bank
holidays** screen under CPD (England and Wales, to the end of 2028, are in).
So January 2027's goes on Monday 4 January, and May 2027's on Tuesday 4 May.

**On staging** it reaches only the addresses in `bulletin_allow`, as the
bulletins and the digest do, and counts the rest as held back.

**Members, Monthly CPD email** on any member shows theirs as it would be
today, and the date the next one goes. Nothing is sent from there.

## Run it in this order

1. **Migration 0047** in the SQL editor.
2. **Test 38**, `tests/38_cpd_monthly_supabase.sql`, Run without RLS. Expect
   `ALL 28 TESTS PASSED`.
3. **Admin 29** (tag V29).
4. **Remove the old reminder and schedule this**, in the SQL editor, once. The
   old reminder may be scheduled as `ami-cpd-reminders`; both running would send
   two emails on the first working day:

```sql
select cron.unschedule('ami-cpd-reminders');
select cron.schedule('ami-cpd-monthly', '0 7 * * *', $$ select app.queue_cpd_monthly() $$);
```

It runs at seven every morning (UTC) and does nothing except on the first
working day. On staging the next is Monday 2 November 2026, to the allow list
only. Where `ami-mail-drain` is scheduled, as on staging, it goes on its own.

## Then check

1. **Members, Monthly CPD email** on the test member: their standing, and the
   date it goes next.
2. **CPD, Bank holidays**: the list, starting Christmas 2026.
3. To see a real one now, with your own address in `bulletin_allow`:
   `select app.queue_cpd_monthly(current_date, true);` then **Email queue,
   Send queued mail**. The second argument skips the first working day test
   for this one run; it still sends nobody two in a month.

## Checked here

697 database tests, staging's order replayed. Test 38 went red when the ARCA
AGM was listed as missed, when a second run in a month sent again, and when the
first working day test was skipped. Test 36 (23) covers the preview and the
Bank holidays screen.
