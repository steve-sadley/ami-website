# 0062: members see and ask to change their emails; the office sees every change members make

Database 50, site 76, admin 46, security check 8. Run 0061 first (README-0061).

Steve, 1 November: show both emails on the member's own details, let the member
change them and choose which one AMI uses, and give the admin app a record of
every edit members make to their records.

**The emails stay Dynamics'.** Steve chose "request, office applies". A member
asks for a change on their profile. The request waits in the admin app's new
Email changes screen. The office changes the contact in Dynamics (Email is the
work email, Email Address 2 the private one). The next sync brings it in, and
the request closes itself when the website's addresses match what was asked
for. Someone not linked to Dynamics can have the change applied in the admin
app. Declining needs a reason, which the member reads on their profile.

**Site 76, /profile.** It gains a new **Your emails** card:

- **Two boxes:** work and private, filled in with what AMI holds.
- **Ask for this change:** sends the request. While it's waiting, the card
  says so and offers Withdraw. A declined request shows the office's reason.
- **Send AMI emails to:** the member's own choice of work or private. It saves
  at once, because the website owns it (0061).

The old Email address box is now **Sign-in email**. It shows the account's own
address, and its hint explains that this isn't where AMI writes. The password
reset link goes to the sign-in address.

**Admin 46.** Two new screens under Today, for membership staff:

- **Email changes:** waiting, done and declined requests, each showing current
  against asked for. Linked members get a note saying what to change in
  Dynamics; others get an Apply button; every request can be declined. A
  request is flagged when an address it asks for is on somebody else's record.
- **Member changes:** every change members made to their own record, newest
  first, field by field: their details (telephone, addresses, photograph),
  their switches, and their email requests. Changes made by the office or
  brought in from Dynamics are not listed.

**0062.** The new parts:

- `email_change_requests`: a member can read only their own requests and
  cannot write to the table directly.
- `request_my_email_change`: replaces an earlier waiting request; at most five
  a day.
- `withdraw_my_email_change` and `set_my_preferred_email`.
- `email_change_decide`: membership staff; Apply only for someone unlinked,
  refused in plain words when an address belongs to somebody else.
- A trigger that closes a request when its addresses arrive.
- Audit triggers on `people`, `member_preferences` and `email_change_requests`.
  These were never audited before.
- `my_profile` gains the emails, the choice and the latest request, added at
  the end.
- `admin_email_change_requests` and `admin_member_changes`, both behind the
  staff gate, narrowed to membership staff.

Decisions taken, flag if wrong:

- No email is sent to the office when a member asks. The Email changes screen
  shows the count. Say if you want a notice emailed to info@.
- The member is not emailed when a request is declined or done. They see it on
  their profile for 30 days.
- A member can't remove their work email, only change it. They can remove the
  private one.
- The Member changes screen includes addresses, so it is for membership staff
  only, not editors.

Tests: 57 (27) is new. It went red with the auto-close removed, with office
changes listed as the member's, and with members allowed to write requests
directly. 58 (15, the profile page in a browser) went red with the sign-in box
showing the record's address and with a note not escaped. 59 (16, the two
admin screens) went red with Apply offered to linked members and with changes
not escaped. Test 16 was given the paging its fake database had lacked since
admin 38, and passes against 43 and 46. Test 19 expects v46. Database 939,
all passing, and clean in staging order. Every site and admin browser test
passes.

## Order

1. Run `supabase/migrations/0062_member_emails_and_changes.sql`.
2. Run `tests/57_member_emails_and_changes_supabase.sql`. Expect `ALL 27 TESTS PASSED`.
3. Upload site 76 to `ami-site`.
4. Upload admin 46 to `ami-admin`. The tag says v46.
5. Sign in as the test member and open /profile. You should see Your emails.
   Ask for a change, then Withdraw it.
6. In the admin app, open Member changes. The test member's request and
   withdrawal are listed.
7. Run `check-staging-is-up-to-date.sql`: every row yes.
8. Run security check 8 with `--compare` against the 1 November report.

## The way back

Upload site 75 and admin 45 again. The database side can stay: nothing reads
it but the new pages.
