# 0061: a work email, a private email, and which one AMI writes to

Database 49, admin 45. Site 75 is unchanged.

Steve, 1 November: one email as the work email, one as the private email, and
a way to choose which is used for communications.

**The two emails already exist** and still come from ARCA's Dynamics:

| On the website | In Dynamics | Shown as |
|---|---|---|
| `people.email` | Email | Work email |
| `people.alt_email` | Email Address 2 | Private email |

Change either address in Dynamics, as before.

**New:** `people.preferred_email`, either work or private, owned by the
website. Everyone starts on work, so nothing changes until the office chooses
otherwise.

**Admin 45.** Edit details has a new box, **Send AMI emails to**, offering the
work email and, where one is held, the private email. The members card shows
the address AMI writes to and marks it work email or private email. The
Emails button now opens the log by membership number, so it finds mail sent to
either address.

**Where it takes effect.** One place in the database queues every email to a
person: `app.queue_message`. That covers decision letters, CPD receipts and
notices, the monthly CPD email, bulletins and the daily digest. A message
addressed to one of a member's own emails goes to their chosen one. A message
to any other address (a test bulletin to the address the office typed) is left
alone. The suppression list is checked against the address the email really
goes to. The monthly CPD preview shows the right address.

On staging, the bulletin, the digest and the monthly CPD email still never
leave `bulletin_allow`. If the chosen address isn't on that list, the message
stays on the allowed one.

**Not affected:** the contact form and application acknowledgements, which
go to the address typed into the form, and signing in.

Decisions taken, flag if wrong:

- Dynamics Email is the work email and Email Address 2 the private one. If
  ARCA's records are not kept that way for some people, their addresses will
  appear under the wrong label. Correct those in Dynamics.
- Only the office chooses, in Edit details. Members cannot choose it on their
  profile page yet; that would be a site change.
- Choosing private when there is no private email is refused. If the private
  email is later removed in Dynamics, AMI quietly falls back to the work email.

Tests: 56 (18) is new. It went red with the switch to the chosen address
taken out (4) and with the staging rule taken out (1). Test 55 is now 17 and
went red with the choice left out of the save. Test 36 now expects Emails to
search by number. Test 19 expects v45. Database 912, all passing, and clean in
staging order. All admin browser tests pass against admin 45.

## Order

1. Run `supabase/migrations/0061_preferred_email.sql`. Expect "Success. No
   rows returned".
2. Run `tests/56_preferred_email_supabase.sql`. Expect `ALL 18 TESTS PASSED`.
3. Run `tests/54_edit_member_details_supabase.sql` again. Expect
   `ALL 22 TESTS PASSED`.
4. Upload admin 45 to `ami-admin`. The tag says v45.
5. Members, Edit details on someone with a private email: Send AMI emails to
   lists both. Choose private, Save. It says which address AMI now writes to,
   and the card says private email. Set it back if it was only a test.
6. `check-staging-is-up-to-date.sql` (sent separately): every row yes.

## The way back

Upload admin 44 again. In the database, everybody can be put back on work with
`update public.people set preferred_email = 'work';`
