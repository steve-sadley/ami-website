# 0042  Zoom attendance: CPD for being there

Site 65, admin 22, database 28.

## What this release is

**For the office**, two new screens in the admin app under CPD.

**Zoom sessions.** Write the session down: a title members will recognise,
meeting or webinar, the Zoom number (spaces are fine), the date, and what it
counts as (AMI Seminar is 3 core points, AMI AGM 2). Optionally its planned
length. After it has finished, press **Fetch attendance**. The site reads the
report from Zoom and the database decides:

- anybody present for **75%** of the session gets the points straight away,
  marked as recorded automatically, with the usual email
- somebody who left and came back has both stretches put together; somebody on
  a laptop and a phone at once is counted once, not twice
- time in the waiting room does not count, nor time before the start
- people are matched by **email**, to a current member only. A display name is
  never matched to anybody

The session then shows what was found ("47 attended, 41 awarded, 3 to match")
and **Who attended** lists everybody with their minutes and outcome. Pressing
Fetch attendance again is safe: nobody is awarded twice, and the recording of
the same seminar in CPD to read and watch awards nothing more if it carries the
same event key.

**People to match.** Anybody Zoom gave an email for that is not a current
member's, and anybody Zoom gave only a name for. **Link to a member** by
membership number: the points follow at once if they were there long enough,
and the address is remembered, so next time they match on their own. **Not a
member** is remembered too, for guests. A name with no email is linked for that
session only, because a name is never safe to remember.

**Nothing before 2027.** A session held before 1 January 2027 is read and
recorded and awards nothing, as the plan says. The date is a setting,
`cpd_feeds_from`, so it can be moved back on staging to test with a real
meeting. It must go back to 2027-01-01.

**Also fixed, and it matters.** The admin app's security policy from admin 18
did not allow the app to reach the site. Every request to the Worker was
refused by the browser before it left: **Send queued mail** and the sending of
a bulletin both said the site could not be reached, and the mail waited.
Admin 22 allows the three site addresses. Test 27 proves it, and was seen to
fail against admin 21's policy. And a dialog with no fields (the Attachments
list on an application) threw as it opened and showed nothing; fixed.

## The Zoom app, which can come later

Nothing in this release needs Zoom to deploy. Until the three secrets are on
the site, Fetch attendance answers "Zoom is not connected yet" and everything
else works, including the Send queued mail fix. So deploy first, and set up
Zoom when there is time.

To set it up, signed in to Zoom as the account owner or an admin:

1. Go to **marketplace.zoom.us**, then **Develop**, **Build App**, choose
   **Server-to-Server OAuth App**, and **Create**. Call it "AMI website CPD".
   If the option is missing, your Zoom role needs "Server-to-Server OAuth app"
   switched on under User Management, Roles, Advanced features. The owner has
   it already.
2. **App credentials** shows three values: Account ID, Client ID and Client
   Secret. Leave this tab open. Do not copy them into email, chat or a file.
3. **Information**: the company name (Asbestos Management Institute), and a
   developer name and email. Zoom will not activate the app without them.
4. **Features**: leave alone. Nothing is needed there.
5. **Scopes**, **Add scopes**: search for and tick these eight, every one ending
   `:admin`:

| Scope | What it reads |
|---|---|
| `report:read:meeting:admin` | when a meeting ran |
| `report:read:list_meeting_participants:admin` | who joined a meeting, and when |
| `report:read:webinar:admin` | when a webinar ran |
| `report:read:list_webinar_participants:admin` | who joined a webinar |
| `meeting:read:list_past_instances:admin` | which occurrence of a reused meeting number |
| `webinar:read:list_past_instances:admin` | the same for webinars |
| `meeting:read:list_registrants:admin` | an email Zoom held back from the report |
| `webinar:read:list_registrants:admin` | the same for webinars |

   The names are Zoom's and Zoom has renamed scopes before. If one is not
   offered under that name, tick the closest; anything missing, Fetch attendance
   names in Zoom's own words.
6. **Activation**: **Activate your app**. It should say activated.
7. In Cloudflare, `ami-site`, Settings, Variables and Secrets, add three, each
   as **Secret**, pasting from the Zoom tab:

```
ZOOM_ACCOUNT_ID
ZOOM_CLIENT_ID
ZOOM_CLIENT_SECRET
```

8. **Upload the site bundle again** (65, or whatever is latest), because
   bindings are read at deploy time. Then do the real meeting check below.

## Run it in this order

1. **Migration 0042** in the SQL editor.
2. **Test 25**, `tests/25_zoom_attendance_supabase.sql`, Run without RLS.
   Expect `ALL 46 TESTS PASSED`.
3. **Site 65**, then **admin 22** (tag V22).
4. **Admin, Email queue, Send queued mail.** It now reaches the site, which it
   has not done since admin 18. Expect a count, not "could not be reached".
5. **Admin, CPD, Zoom sessions.** It opens. Fetch attendance on a test session
   says Zoom is not connected yet, which is right until the app exists.

## Then, once the Zoom app exists, check with a real meeting

1. **Move the start back, on staging only:**
   `update public.system_settings set value = '2026-10-01' where key = 'cpd_feeds_from';`
2. Hold a short Zoom **meeting with registration on**. Register and join as
   yourself, using the address on the test member's record, and stay to the end.
   Leave and rejoin once if you like.
3. Wait for the meeting to end, then **about half an hour**: Zoom's report is
   not ready at once. Pressing early is harmless and says so.
4. **Admin, CPD, Zoom sessions, New.** Title, Meeting, the number, today's date,
   Counts as AMI Seminar. Save. **Fetch attendance.** Expect a line saying how
   many lines were read and how many were awarded.
5. **Who attended**: you, with your minutes. **My CPD** as the test member: 3
   core points, recorded automatically, and the receipt in the email queue.
6. Anybody else who joined from an address no member holds is in **People to
   match**.
7. **Put the start back:**
   `update public.system_settings set value = '2027-01-01' where key = 'cpd_feeds_from';`

## Checked here

`run_tests.sh` gives 558 database tests and `tools/replay-staging-order.sh 0041`
passes in staging's order. Test 25 was proved by breaking it three ways: summing
the times instead of taking their union, granting the record function to
signed in users, and removing the ten minute limit on an import. Each went red.
Test 26 (36 checks, the Worker against a stub Zoom) went red when the London
date was read off the UTC string and when the whole Zoom line was passed on.
Test 27 (20 checks, the admin screens in a browser under the real policy) went
red seven times against admin 21's policy.

## What it does not do yet

It does not fetch on its own. Pages has no scheduled events, so the office
presses the button after each session; a pg_cron job could do it later. The
Zoom report has to exist, so a meeting deleted in Zoom before its attendance
was read cannot be read. And Dynamics, item 5 of the plan, will feed the same
People to match screen and the same remembered links.
