# 0046  The image library, every photograph editable, and the communication log

Site 70, admin 27, database 33.

Steve, 31 October: an image library rather than photos on the page editor;
every photograph on the pages editable; and a communication log recording
every email the system sends.

## What it does

**Image library**, a new screen under Content. Every picture the site can use,
uploaded once and chosen from anywhere. It starts with the site's own five
photographs (marked built in) and every picture already uploaded. Each picture
has a name, a description for people who cannot see it, and shows where it is
used. A picture in use cannot be deleted: archive it, and it stays where it is
but is no longer offered. Uploads are converted exactly as before: turned the
right way up, scaled, stripped of location and camera details.

**Every picture field opens the library**: the page photographs on Pages, the
home page headline, news, guidance, events and video. Uploading happens in
the library window, and the picture is then in the library for next time.

**The photographs that could not be changed now can:**

- **The home page headline.** Each headline now carries its own photograph
  and the short label on it (Content, Home page headline). The two always turn
  together, whatever the number of headlines. The old rule, keep the number of
  headlines equal to the four photographs, is gone. Existing headlines keep the
  photographs they show today.
- **The picture for an item with none of its own.** News, events, guidance and
  video without a picture used one of four fixed photographs. Now it is any
  library picture ticked "use where an item has no picture of its own". The
  site's four are ticked to start with. An item always gets the same one.

**Communication log**, a new screen under Today. Every email the system has
sent or tried to send, newest first, searchable by name, address or subject,
with Sent, Not sent and Waiting tabs. Read it opens exactly what went. On the
Members screen, **Emails** on a member opens the log showing only theirs.

It already held every letter the database queues (decisions, receipts,
reminders, bulletins, the digest). Four emails were never in it, because the
site sends them as it handles a form: the application acknowledgement, the
office's notice of an application, and the contact form's enquiry and its
acknowledgement. Those are now written to the log after sending, as sent or
failed with the reason.

**This changes an earlier decision.** The contact form deliberately stored
nothing ("the office already has somewhere it keeps messages"). Logging every
email means enquiries are now kept. The privacy notice needs a line saying so,
and the office should decide how long the log is kept.

Also fixed: the daily digest email could not show one of the site's own
photographs chosen for a news item; it now can.

## Run it in this order

1. **Migration 0046** in the SQL editor.
2. **Test 34**, `tests/34_library_and_log_supabase.sql`, Run without RLS.
   Expect `ALL 30 TESTS PASSED`.
3. **Site 70**, then **admin 27** (tag V27).

## Then check

1. **Content, Image library.** The five built in photographs and anything
   uploaded before. Each says where it is used.
2. **Upload a picture** there. It appears with its size; rename it and give it
   a description. Save.
3. **Content, Pages, About.** The banner says which picture it is. **Choose
   from the library**, pick yours, Save draft, Publish. The About page shows it.
4. **Content, Home page headline.** Open one: its photograph and label. Change
   the photograph; the home page shows it with that headline.
5. **Today, Communication log.** Send yourself a contact form enquiry from the
   site; both emails appear, marked sent by the site. Read it opens one.
6. **Today, Members, Emails** on the test member: only theirs.

## Checked here

669 database tests, and staging's order replayed. Test 34 went red when a
picture in use could be deleted and when the log could be written by a signed
in user; its first run found the library's guard could not tell an editor from
the owner, and that headlines loaded after the migration had no photograph.
Test 35 (11, the Worker) went red when an email was not logged and when a
failure was not. Test 36 (17, the admin screens) went red when a logged email
was shown as raw HTML and when Emails on a member did not filter. Test 37 (9,
the public pages) went red when a picture address was not checked and when
the headlines did not ask for their photographs. Tests 14 and 16 now go
through the library.
