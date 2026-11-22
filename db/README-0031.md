# 0031: the daily digest

Run 0029 and 0030 first. This builds on both.

## What it does

One email a day listing what AMI has published since the last one: news, events,
guidance and videos. It sends nothing on a day with nothing to announce.

**It is a digest rather than one email per item, and that is a change from what
was asked for.** Four news items published on a Tuesday afternoon is four emails
inside an hour to every member on the list, and that is the most reliable way to
make somebody switch the newsletter off. Once they have, they have also switched
off the one about the thing they did care about.

## 1. The migration and the test

```
supabase/migrations/0031_content_digest.sql
tests/08_content_digest_supabase.sql       expect 26
```

**Everything already published is marked as announced when the migration runs.**
Otherwise the first digest would be a list of everything AMI has ever published,
which is not the introduction anybody wants.

**340 database tests in total.**

## 2. The job

```sql
select cron.schedule('ami-content-digest', '30 18 * * *', $$
  select app.queue_content_digest();
$$);
```

Half past six UTC, so it lands after the working day. Daily costs nothing on a
quiet week because a run with nothing to announce sends nothing.

## 3. Before it runs for real

Check the picture address is right for your project:

```sql
select key, value from public.system_settings where key = 'media_url';
```

It should be your Supabase URL followed by
`/storage/v1/object/public/public-media/`. The bucket is public, so an ordinary
image tag in an email works with no signing, which is the whole reason content
pictures moved into it in 0023.

See what the next digest would carry, without sending anything:

```sql
select * from public.admin_digest_pending;
```

And send one by hand when you want to watch it happen. Super users only:

```sql
select public.run_content_digest();
```

## The four rules it obeys

**Published is not the same as public.** An item with a publication date in the
future is not announced until that date arrives, which is how you write something
on Saturday and let it out on Monday.

**Announced once.** Every item carries `notified_at`, set when it goes into a
digest. Correcting a typo in a published article does not announce it again.
Clear the column by hand if you genuinely want something announced a second time.

**An event whose date has gone is not announced.** An email inviting somebody to
last Thursday is worse than no email.

**Two switches, one email.** News, guidance and videos answer to the newsletter
switch and events answer to the events switch. A member who takes only events
gets a digest containing only the events. A member who takes neither gets nothing
and is not counted as having been written to.

And the staging guard from 0030 applies here too. It would be a poor sort of
guard that covered the button somebody presses deliberately and not the job that
runs itself at half past six.

## One thing that was wrong and is now only differently worded

0010 defined `email_templates.is_service` as "a letter that cannot be opted out
of". 0027 used it as "a letter only a super user may reword". Those are two
different ideas and nothing has ever enforced the first: whether a member can
refuse something is decided by the switches on `member_preferences`, one at a
time.

The digest forced the question, because a member can switch it off and yet an
editor must not be able to rewrite it. The flag keeps the meaning 0027 gave it
and the comment on the column is corrected. No behaviour changes; a sentence
stops being wrong.
