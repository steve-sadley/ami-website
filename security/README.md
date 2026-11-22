# AMI security check

An attacker suite of a few hundred fixed checks, and an AI agent (Claude) that
probes further with read-only requests. Run it against staging before the real
members are loaded, and again after, and compare the two.

It does not replace the independent penetration test. It means that test
starts from a clean baseline.

## What it checks

- Signed out: every table and view read, every table written to, every staff
  and service function called; what the database tells strangers about itself.
- Forgery: made-up "service role" sign-ins, and a real member's sign-in edited.
- As a signed-in member: nothing of anybody else in any table; cannot make
  themselves super user, change their grade, letters or active switch, award
  themselves CPD, change settings, read the change history, call any staff
  function, or see anybody else's photograph or certificate folder; and,
  since version 7 (database 0059), cannot read who switched their own
  membership on or off or the office's reason, while still reading their
  own number and status.
- As membership staff: cannot make themselves super user or load members.
- Files: private buckets cannot be listed or reached, the public one cannot be
  uploaded to by strangers.
- The site's /api doors: refuse the signed-out and the made-up, do not let
  another website read their answers, refuse bad form input.
- Settings: security headers on the site and admin app, no secrets in the page
  code, no exposed files (.git, .env and the rest), sign-in settings.

Nothing it sends can change real data: writes aim at rows that do not exist,
forms are only ever sent invalid, nobody is signed up.

## Setting it up (once, about 10 minutes)

1. Check Node is installed. Open Terminal and type `node -v`.
   You should see v18 or higher. If not, install the LTS version from nodejs.org.

2. Unzip AMI-security-check into a folder, for example Documents/ami-security.

3. Copy `security.config.example.json` to `security.config.json` in the same
   folder and fill it in with a text editor. Never paste these into a chat.
   - supabaseUrl and supabaseAnon: the staging project's URL and publishable key.
   - syncUrl: the ami-dynamics-sync Worker's address.
   - anthropicKey: for the agent. Leave empty to run the fixed suite only.

4. The test accounts. Create them in Supabase (Authentication, Users, Add
   user, Create new user, tick Auto Confirm), then run
   make-security-test-accounts.sql. Put their emails and passwords in
   memberEmail, memberPassword, staffEmail and staffPassword. The check signs
   in as them itself. The member must have no staff role, and the staff
   account membership only.

## Running it

In Terminal, in that folder:

    node ami-security-check.mjs --config security.config.json --agent

It takes a few minutes. You should see a count of passed, failed and to
review, and two files: `security-report-<date>.md` (send it to Claude) and
`security-report-<date>.json` (keep it).

After the members are loaded, run it again with the first run to compare:

    node ami-security-check.mjs --config security.config.json --agent --compare security-report-<first>.json

The report then starts with every check whose answer changed.

It refuses to run against the live site unless you add `--live`.

To check only that the two test accounts can sign in, in a second and without
a report:

    node ami-security-check.mjs --config security.config.json --sign-in

Each line says OK or FAIL, with Supabase's own reason, such as
`invalid_credentials` (the password in the config is not the account's) or
`email_not_confirmed`. `reset-staff-test-password.sql` sets a new one.

`check-admin-views-gated.sql` lists every admin view and whether it answers
staff only.

## Version 7, 1 November 2026

For database 0059 and 0060. Two new checks as a member: the office columns on
their own members row are refused, and their own number and status still come
back. Two more staff functions, `member_activation` and `update_member_details`,
must be refused both signed out and as a member, four checks. The self-test
(`node test-security-check.mjs`) is 30 checks and includes a site where a
member can read those columns, which it must catch.
`check-staging-is-up-to-date.sql` now also checks 0059 and 0060.

Run 0059 and 0060 first, then run it with
`--compare security-report-2026-10-31-22-51.json`. Expect the same 486 as
before plus six new ones, 492 in all, every one a pass. The six show as new
checks in the comparison, not as changes.

## Version 9, 22 November 2026

For database 0061 to 0066 and site 85. Version 8 (0061 to 0063) had gone
missing from Downloads, so version 9 is built on version 7 and covers
everything since.

- New tables and views: email_change_requests, the three interview tables,
  admin_email_change_requests, admin_member_changes, admin_interview_slots and
  public_guidance. Signed out they must give nothing (public_guidance apart,
  which must not give a storage address). A member must get NO rows at all
  from the interview tables or any admin view: a row there is now a failure,
  not something to review.
- New functions: the member's own three email actions and
  can_read_member_documents refused to somebody signed out; email_change_decide,
  interview_invite and interview_office_cancel refused to a member; the six
  service functions (the five interview ones and guidance_file) refused both
  signed out and, new in this version, as a member. The new ones are called with
  their real arguments, so the answer is the permission check rather than
  "no such function".
- As a member: cannot offer an interview time, book directly, or file an email
  change for somebody else; cannot list content-media (0066).
- Signed out: content-media cannot be listed or reached as a public file.
- The interview doors: a made up invitation link is refused and shows no times
  or names; GET is refused; only the four doors exist; office-cancel refuses
  somebody signed out, a made up sign in and a member.
- The guidance door: refuses an unknown name, a name that climbs out of its
  folder and a storage address; takes GET only; a members only document is
  refused to a visitor and to a made up sign in, given to the test member, and
  never put in a shared cache. Skipped if no members only document with a file
  is published.

The self-test is 37 checks and includes a pretend site with each of the new
holes, every one caught by the check written for it.

Run it with `--compare security-report-2026-10-31-22-51.json`. The new checks
show as new, not as changes. Every one should pass.
