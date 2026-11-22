# 0064: applicants book their professional interview on the site

Database 52, site 81, admin 47.

Steve, 3 November: replace the Doodle poll. Applicants book the professional
interview; times that clash with Steve's Outlook calendar are not offered; a
booking goes into Outlook and both sides are emailed. Interviews are on
Microsoft Teams and last 1 hour 15 minutes.

## How it works

1. The office adds times on **Interview slots** (75 minutes by default; two
   cannot overlap).
2. On an application, **Invite to interview** emails the applicant a private
   link. Sending it again makes a new link and the old one stops working. The
   link lasts 60 days.
3. The applicant opens `/interview#t=...`. The site reads Steve's Outlook
   calendar and hides any slot with something busy, tentative or out of office
   in it. Free and working elsewhere do not count as clashes.
4. They choose a time. The site checks Outlook again for that slot, writes the
   interview into the calendar as a Teams meeting with the applicant invited,
   and emails both: the applicant at their application address, the office at
   `interview_notify` (Reply-To the applicant). The applicant also gets
   Outlook's own calendar invitation with the Teams link.
5. Up to 24 hours beforehand the applicant can change or cancel it from the
   same link. Changing cancels the old Outlook event.
6. The office sees everything on **Interviews**, and can cancel any interview
   with a reason the applicant is told. That cancels the Outlook event too.
   The application card shows the interview and its Teams link.

Settings in `system_settings` (super users): `interview_notice_hours` (24),
`interview_days_ahead` (90), `interview_notify` (steve.sadley@arca.org.uk;
comma separated for more than one).

## Decisions taken, flag if wrong

- Teams, not Zoom. One Microsoft registration does the calendar and the
  meeting link; Zoom would need the Zoom app that is still waiting on the
  account owner.
- Bookings and changes close 24 hours before. Inside that, applicants reply to
  the invitation email.
- Outlook "working elsewhere" is not a clash; "tentative" is.
- The office is not told when an invitation is sent, only when something is
  booked, changed or cancelled.
- Deciding an application does not cancel its interview. A decided
  application's link stops working, so it cannot be booked or changed.
- A slot somebody holds cannot be moved, withdrawn or deleted until their
  interview is cancelled.

## What Steve has to do, in order

### The database

1. Supabase, SQL editor: run `supabase/migrations/0064_interview_booking.sql`.
   Expect "Success. No rows returned".
2. Run `tests/64_interview_booking_supabase.sql`, Run without RLS. Expect
   `ALL 44 TESTS PASSED`.

### Microsoft Entra (ARCA's tenant)

3. entra.microsoft.com, **App registrations**, **New registration**. Name
   `AMI interview booking`, accounts in this organisational directory only, no
   redirect URI. Register. Copy the **Application (client) ID** and the
   **Directory (tenant) ID** from the Overview page.
4. **Certificates & secrets**, **New client secret**, 24 months. Copy the
   **Value** straight away (it is shown once). Put a reminder in your diary
   for its expiry.
5. **Do not add any API permissions here.** Exchange grants the calendar
   permission in the next step, for your mailbox alone. A permission granted
   in Entra would cover every mailbox in ARCA.
6. **Enterprise applications**, find `AMI interview booking`, copy its
   **Object ID** (this is a different ID from step 3).

### Exchange Online (limits it to your calendar)

7. Open PowerShell and run `Connect-ExchangeOnline` (install the module first
   with `Install-Module ExchangeOnlineManagement` if you need to). Then, with
   the two IDs filled in:

```
New-ServicePrincipal -AppId <client id from step 3> -ObjectId <object id from step 6> -DisplayName "AMI interview booking"
New-ManagementScope -Name "AMI interview calendar" -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'steve.sadley@arca.org.uk'"
New-ManagementRoleAssignment -App <client id> -Role "Application Calendars.ReadWrite" -CustomResourceScope "AMI interview calendar"
```

8. Check it: `Test-ServicePrincipalAuthorization -Identity <client id> -Resource steve.sadley@arca.org.uk`
   should say InScope True, and the same with somebody else's address should
   say False. Exchange can take up to two hours to apply it.

### Cloudflare

9. `ami-site`, Settings, Variables and Secrets, add four:

```
MS_TENANT_ID       the Directory (tenant) ID        Text
MS_CLIENT_ID       the Application (client) ID      Text
MS_CLIENT_SECRET   the secret Value                 Secret
MS_CALENDAR        steve.sadley@arca.org.uk         Text
```

10. Upload **site 81** (after the settings, because they are read at deploy
    time). Then upload **admin 47**; it shows v47.

### Check it end to end

11. Admin, **Interview slots**: add a time three days ahead. Put something
    busy in your Outlook over a second slot and add that one too.
12. Submit a test application at `/apply` with an address you can read, then
    on **Applications** press **Invite to interview**. Expect the email within
    a minute.
13. Open the link. Expect the first slot offered and the clashing one not.
14. Book it. Expect: the page says booked; a Teams meeting in your Outlook
    with the test address invited; the confirmation at the test address and
    at yours; the calendar invitation at the test address.
15. On the page, Change the time, then Cancel. Expect the Outlook event to
    move and then be cancelled, with an email each time.
16. Refuse the test application afterwards.

Until step 9 is done, the booking page says booking is not open yet and asks
the applicant to reply to their invitation, rather than offering times it
cannot check.

## Tests

- 64 (44, database): who may invite, the hashed link and the second invitation
  killing the first, nothing callable from a browser, the page's slots, two
  applicants on one slot, holds lapsing, confirming and its emails, only a
  Teams link kept, changing, cancelling inside and outside the notice period,
  the office's reason, overlapping and booked slots, the office's views. Went
  red with the hold granted to visitors, with the Teams check removed and with
  holds never lapsing.
- 65 (38, the Worker against pretend Microsoft): clashes hidden and refused,
  the event as a Teams meeting with the applicant invited and a transactionId,
  the event taken out again when the database fails, the old event cancelled
  on a change, the database's words passed on, the office door as the staff
  member. Went red with the clash filter removed and with the clean up
  removed.
- 66 (24, the booking page in a browser): token after the # and never in an
  address, UK time including summer time, booking, a time just taken, change
  and cancel, inside the notice period, markup kept as words. Went red with
  the name unescaped and the time zone wrong.
- 67 (16, the admin screens in a browser): Invite and its link, the
  application card, Interviews and Cancel with a reason. Went red with the
  send and the reason check removed.
- 61 brought up to site 80's password rules (14).
- Test 19 expects v47. Database 990, all passing, and clean in staging order.
