# 0058: members keep the numbers they already have

Database 46, admin 43, security check 6. Steve, 31 October: keep AMI's numbering
(order of admission in the month, then MMYY: 020626 is the second admitted in
June 2026). `legacy_register` holds the current site's register (121, filled by
`load-current-register.sql`, real names so not a migration; nobody but the load
can read it). `dynamics_members_load(p_go)` replaces 0056's: a member found on
the register by surname and first name (short forms brought together by
`app.given_key`) keeps the number and joining date; two Dynamics records for one
entry are held back; anybody else gets `app.next_membership_number(today)`; a
linked member on a TEST- number takes theirs; register entries not in Dynamics
are reported. `next_membership_number()` (membership staff) fills the approval
dialog. Test 52 (16), test 48 restated. Database 860. The lock from 0056 stands.

Order: 0058, test 52, test 48, load-current-register.sql, then the preview.
