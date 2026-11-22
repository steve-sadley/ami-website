# 0030: bulletins. What to run, and how to send the first one

Run 0029 and its tests first. This builds on them.

## 1. The migration

```
supabase/migrations/0030_bulletins.sql
```

Safe on a populated database. It adds one small table, seven columns across two
existing tables, a handful of functions, and it replaces three policies on
`email_campaigns`.

**One thing changes that nobody asked for.** 0010 gave EDITORS insert and update
on `email_campaigns`. That was harmless while nothing used the table. It is not
harmless now: without this change an editor could have written and sent a letter
to every member on the register, under AMI's name, and nothing about it would
have looked wrong. Campaigns now belong to membership staff and super users,
which is the same line 0027 drew on service templates.

## 2. The tests

```
tests/07_bulletins_supabase.sql   expect 38
tests/04_member_area_supabase.sql expect 51
```

04 is there because 0030 retypes the `my_profile` view to carry the two new
preference columns, and 04 is the file that proves the members area still reads
what it expects.

**314 database tests in total.** None of those numbers should ever go down.

## 3. Check the four settings

```sql
select key, value from public.system_settings order by key;
```

| Key | What it is for | Today |
|---|---|---|
| `environment` | `staging` or `live` | **staging** |
| `site_url` | where the unsubscribe link points | `https://staging.ami.uk.com` |
| `bulletin_from` | the Reply-To on a bulletin | `bulletin@ami.uk.com` |
| `bulletin_allow` | who may receive one while not live | empty |

**Put your own address in `bulletin_allow` before you try anything.** While the
environment is anything but live, a send reaches only the addresses listed here
and records everybody else as withheld. That is deliberate: a staging deployment
that can mail the membership is a hazard sitting in the open.

```sql
update public.system_settings
   set value = 'steve.sadley@arca.org.uk'
 where key = 'bulletin_allow';
```

Only a super user can change any of these.

## 4. Sending the first one

In the admin app, a new screen under Today called **Bulletins**.

1. **New.** Give it a name for the office, a subject line and a body.
2. **Put `{{unsubscribe_url}}` in the body**, as the address of a link. The
   database refuses to send a bulletin without it, because a bulletin with no way
   out is not lawful and a browser is not a place to keep that rule.
   `{{given_name}}`, `{{family_name}}`, `{{membership_number}}` and `{{grade}}`
   are filled in for each member and work in the subject line too.
3. **Who it goes to.** Leave the audience as `{}` for every active member who
   takes the newsletter. The keys are listed under the field.
4. **Audience.** Shows the actual list of names. The same query sends it, so what
   you see is what goes.
5. **Send test.** Goes to one address, marked `[TEST]` in the subject, carrying no
   unsubscribe token, so clicking the link in it cannot unsubscribe anybody.
   Nothing can go to the membership until one of these has been sent.
6. **Send.** Asks you to type the number of recipients. The count is fetched
   again at that moment rather than taken off the card, so a bulletin whose
   audience has changed since you looked cannot go out on a stale number.

The admin app then calls the drain repeatedly until the queue is empty and tells
you how far it has got. The Worker sends 10 a call, so 200 members is about 20
calls and a few seconds.

**A sent bulletin cannot be sent again.** Copy it into a new one.

## 5. What to look at afterwards

```sql
select * from public.admin_campaigns;
```

`delivered`, `failed` and `withheld` per bulletin. A `withheld` count on staging
is the guard working, not a fault.

```sql
select email, status, reason from public.email_sends
 where campaign_id = '...' order by status, email;
```

## 6. The unsubscribe page

`/preferences` on the public site, new in site bundle 44. It works with no sign
in, from the token in the link, and it lands somebody on a page of switches
rather than a bare confirmation, so a member who only wanted the CPD reminders
stopped does not have to leave everything.

The same five switches now also appear on `/profile` for a member who is signed
in, because somebody who has signed in looks for their settings in one place.

## At cutover

```sql
update public.system_settings set value = 'live'                 where key = 'environment';
update public.system_settings set value = 'https://ami.uk.com'   where key = 'site_url';
```

And the pg_cron drain job from 0029 needs its URL changed at the same moment, or
nothing queued by any of this is ever sent. All three are one line each and all
three are silent when forgotten, which is why they are written down here.

## Still open

**`bulletin@ami.uk.com` has to exist twice.** As a mailbox in Microsoft 365, so a
reply reaches somebody, and on a domain SMTP2GO is verified to send for. The
domain is already verified because `no-reply@ami.uk.com` sends today, so the
second half is done; the mailbox is not.

**A line in the privacy notice about bulletins and how to stop them.** It belongs
on the list of things a solicitor should look at, which is already flagged on
that page.
