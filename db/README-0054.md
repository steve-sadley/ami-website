# 0054: AMI's members come from Dynamics

Database 41, admin 40, ami-dynamics-sync 4. Steve, 31 October: Dynamics holds
whether somebody is an AMI member (AMI Member? on the contact) and their grade
(AMI Category), and is the one source of truth. Agreed: Dynamics owns who is a
member, the grade, first and last name, Email and Email Address 2; the website
owns the membership number and everything else. Approving an application still
makes the member on the website; the office adds them in Dynamics too.

- Fourth feed `ami_members`, view "AMI Sync: Members" on Contact, filtered to
  AMI Member? = Yes. Read first each run by `dynamics_members_record`: links a
  contact to a website person (`people.dynamics_contact_id`) by email the first
  time, only when exactly one unlinked person holds it, then by contact; copies
  name and emails (a collision is reported, not forced); maps AMI Category
  through `dynamics_grade_map` (by name when unambiguous, otherwise the office
  maps it); switches an inactive membership on.
- `dynamics_members_close` switches off linked memberships whose contact left
  the view, with reason "No longer an AMI member in ARCA's Dynamics", unless the
  view held under 80% of the linked active members (then nobody, and the run
  says so). `dynamics_members_seen` keeps only current AMI members.
- `people_dynamics_guard` and `members_dynamics_guard` (INVOKER) refuse a signed
  in user changing name, emails, grade or active for a linked person; the sync
  and other definer functions pass.
- Attendance: `contact_field` (the Delegate Name lookup) on each attendance feed.
  `dynamics_decide` matches by contact first (`matched_by = 'contact'`). A row
  whose contact is an AMI member in Dynamics without a website record is kept and
  said so in People to match.
- `admin_dynamics_member_check`, the admin screen Members and Dynamics: in
  Dynamics only, on the website only, AMI Categories (map to a grade).

Order: run 0054, then test 47 (ALL 24 TESTS PASSED); deploy worker.js version 4;
upload admin 40; build the Members view in Dynamics; Sync now; name the members
columns (Edit on AMI members) and the Delegate contact column on each attendance
feed; Sync now again; check Members and Dynamics.

Tests: 47 (24), 39 adjusted for four feeds, 40 (33), 41 (27). Database 818.
