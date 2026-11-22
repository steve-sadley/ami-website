# 0060: the office edits a member's details

Database 48, admin 44, security check 7. Site 75 is unchanged.

Steve, 1 November. Dynamics owns a member's name, emails, whether they are a
member and their grade, and the member owns their mobile and addresses on
/profile. Four things only the website holds had no screen: membership
number, joining date, job title and employer. Until now they could only be
changed with SQL.

**Admin 44.** Members, any card, **Edit details** (membership staff, super
users and administrators; not editors). The dialog shows the number, joining
date, job title and employer filled in. Above them it says what Dynamics holds
(name, both emails, grade) and that those are changed in Dynamics. The card
now shows the employer beside the job title.

**0060.** `public.update_member_details(member, number, joined_on, title,
employer)`, membership staff only. It refuses rather than guesses:

- **Number:** trimmed and upper cased; letters, digits and hyphens, at most
  20; not held by another member in any case; and not a number the previous
  register keeps for somebody not yet loaded, unless the surname matches. That
  protects Abbott, Bennett, Carraher and Pain's numbers until Monday. A
  register number taken is remembered on the register, and one given up is
  released.
- **Joining date:** not in the future.
- **Employer:** found by name ignoring case, otherwise made; empty clears it.
- **Job title:** empty clears it.

The change is in the audit log as the member of staff who made it.
`admin_member_list` gains `employer`, `in_dynamics` and `alt_email` at the
end, and keeps the 0057 staff gate.

Decisions taken, flag if wrong:

- A number not in the usual six-digit form, such as TEST-1, is allowed, but the
  admin app asks "Save it anyway?" first.
- A new number shows on the member's wallet card only once the card is
  reissued. The app says so after saving. The QR code is unaffected, because
  it points at the member's public page, not the number.
- No grade, name or email editing here at all, even for a member not yet
  linked to Dynamics. Those are Dynamics' to own.

Tests: 54 (22) is new. It went red with the staff check removed (2) and with the
register check removed (1). Browser test 55 (13) is new and went red with the
button offered to editors and with the employer left out of the save. Test 19
expects v44. Database 894, all passing, and clean in staging order. Admin
browser tests 14, 19, 27, 30, 36, 41 and 55 all pass against admin 44.

## Order

Run 0059 first if it has not been (README-0059).

1. Run `supabase/migrations/0060_edit_member_details.sql`, Run without RLS. You
   should see it complete with no errors.
2. Run `tests/54_edit_member_details_supabase.sql`. Expect `ALL 22 TESTS PASSED`.
3. Run `tests/49_admin_views_staff_only_supabase.sql`. Expect `ALL 3 TESTS PASSED`,
   proving the members list is still staff only.
4. Upload admin 44 to `ami-admin`. The tag top right says v44.
5. Open Members. The cards show employers where held, and each has Edit details.
   Open one, change nothing, press Save. It should say Saved.
6. Run `check-staging-is-up-to-date.sql` from the security check 7 folder:
   every row yes.
7. Run security check 7 with `--compare security-report-2026-10-31-22-51.json`.
   Expect 492, all passing.

## The way back

Upload admin 43 again. The function and the extra view columns do no harm
left in place.
