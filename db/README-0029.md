# 0029: the CPD emails. What to run, in what order

Fifteen minutes, in the Supabase SQL editor on `ami-staging`. Choose **Run
without RLS** when it asks, because the test files switch it on themselves.

## 1. The migration

```
supabase/migrations/0029_cpd_email.sql
```

It is safe to run on a populated database. It adds three columns to
`member_preferences` with defaults, one small table, four email templates, and it
replaces `review_cpd` and `app.queue_email` with versions that do the same thing
and one more thing.

Nothing sends yet. Everything it queues sits in `email_outbox` until the drain is
called, which is the same arrangement 0027 uses for the application decisions.

## 2. The tests

```
tests/06_cpd_email_supabase.sql     expect 49
tests/02_admin_actions_supabase.sql expect 30
tests/04_member_area_supabase.sql   expect 51
tests/05_email_supabase.sql         expect 46
```

Run 06 first, then the other three, and in that order. 02 and 05 are the files
that prove 0029 did not break what 0027 and 0020 built, because 0029 retypes
`review_cpd` and `app.queue_email`, and a rewrite is where a check goes missing.
04 covers the members area, which now has two more preference columns under it.

Every file runs inside a transaction and rolls back, so it leaves nothing behind
and can be run as often as you like.

**276 database tests in total.** None of those numbers should ever go down.

## 3. The clock, which is not in the migration

Cloudflare Pages has no scheduled events, so neither the reminder job nor the
drain can be a cron trigger on the site project. `_worker.js` already says so and
already names the answer: pg_cron and pg_net, both of which the Supabase Pro plan
has.

They are not created by the migration because enabling an extension is a project
level act rather than a schema change, and because the drain URL is an address
rather than a fact about the database.

In the SQL editor, once:

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Nightly. The function decides for itself whether today is a reminder day, so
-- the schedule stays dumb and the rule lives in one place.
select cron.schedule('ami-cpd-reminders', '15 7 * * *', $$
  select app.queue_cpd_reminders();
$$);

-- Every five minutes. The drain takes no input that decides anything, and a
-- second caller during a drain gets an empty batch rather than a duplicate, so
-- calling it on a timetable is safe and needs no shared secret.
select cron.schedule('ami-mail-drain', '*/5 * * * *', $$
  select net.http_post(url := 'https://staging.ami.uk.com/api/mail/drain');
$$);
```

**Change that URL at cutover**, to `https://ami.uk.com/api/mail/drain`. A drain
pointing at staging after cutover looks like it is working and sends nothing.

To see what the jobs have done:

```sql
select * from cron.job;
select * from cron.job_run_details order by start_time desc limit 20;
```

## 4. What to look at once it is running

```sql
-- The queue, newest first. Status, attempts and the reason it failed.
select * from public.admin_email_queue limit 50;

-- How many reminders went out in each month.
select * from public.admin_cpd_reminders;
```

A row sitting at `queued` for more than five minutes means the drain is not being
called. A row at `failed` has been tried three times and `last_error` says why. A
row at `suppressed` was never sent because the address is on the bounce list, and
that is deliberate: 0027's rule is that a message which cannot be sent is marked
and kept rather than dropped, so the office can find it.

## 5. Two things to do by hand

**Read the four templates before a member does.** They are in the admin app under
email templates and they are the letters AMI sends. `cpd_accepted`,
`cpd_rejected`, `cpd_logged` and `cpd_reminder`. Ten minutes. Only a super user
can change them, because they are marked `is_service`.

**Check the reminder before July.** Run it by hand against a July date and read
what comes out of the queue rather than waiting to find out:

```sql
select app.queue_cpd_reminders(make_date(2026, 7, 15));
select to_email, subject, left(html, 400) from public.email_outbox
 where template_code = 'cpd_reminder' order by queued_at desc limit 5;
```

That writes real rows to `cpd_reminder_log`, so the real July run will then skip
those members. Delete the log rows afterwards if you want July to happen
properly:

```sql
delete from public.cpd_reminder_log where year = 2026 and month = 7;
```

## What 0029 decided, and what is still open

**Reminders go monthly from July**, and stop for the year the moment a member
meets the requirement. There is a softener: somebody who logged CPD in the last
30 days is skipped, because they are using the scheme and chasing them is how a
reminder becomes junk. `app.queue_cpd_reminders(current_date, 0)` switches the
softener off if you decide against it.

**One letter per member per press.** `review_cpd` takes an array and a queue of
forty can belong to a dozen people.

**A decision cannot be switched off.** The reminder and the logging receipt can.
That is 0002's rule, written on `member_preferences` before any of this existed:
membership notices are not preferences.

**The receipt is off by default.**

**Still open, and it is a decision rather than SQL.** `people.email` versus the
sign in address, which 0028 raised and which now matters more, because every
letter in this migration goes to `people.email`. A member who changes the address
they sign in with keeps the old one on the record, and their CPD decisions go
there. Settle it before the first member changes an email address.
