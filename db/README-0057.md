# 0057 and site 72: fixes from the first security check (31 October)

First run of the security check on staging, before any real member data: 482
checks, 468 passed. What it found, and what was done:

- Members could read two admin views (admin_member_list and
  admin_dynamics_member_check), seeing only their own row. 0057 wraps every
  admin_ view in a staff gate (`app.is_staff()`), columns unchanged, still
  security_invoker. Test 49 checks every admin_ view there is, so a new one
  without the gate fails. Note: the SQL editor runs as the owner, who is not
  staff, so admin_ views now show nothing there; read the tables instead.
  Re-running 0053 or 0054 would restate two views without the gate: run 0057
  again afterwards (test 49 would catch it).
- /api/pass/status listed every Worker binding by name to anybody. Now it says
  only whether Apple and Google wallets are ready (all the card page reads).
- /api/cpd/evidence and /api/photo answered a made up sign in with 400 (bad
  input) before checking it. Both now ask Supabase Auth first (`signedIn`) and
  refuse with 401 before reading anything.
- README.md was served publicly from the site. The Worker now answers 404 for
  any .md.
- /assets/* sent "no-store, public, max-age=31536000, immutable": `_headers`
  now removes the inherited no-store (`! Cache-Control`).
- The admin app's "missing headers" were Cloudflare Access's redirect: the
  check now records the app being behind Access as a pass.

Left as they are, for Steve: /api/mail/drain can be asked by anybody to send
mail already queued (it cannot add mail); the public register can be listed in
full (name, grade, employer, joining year, number: no contact details);
security.txt (needs a contact address).

Tests: 49 (3); 20 and 33 updated; 46 and 47 read admin views as staff. Database 835.

## Site 73 and admin 42: the mail drain, AMI staff only (Steve, 31 October)

/api/mail/drain now answers only the database's schedule, which sends the
shared secret DRAIN_KEY in an X-Drain-Key header, or a member of staff signed in
to the admin app (any staff role, checked through whoami). Anybody else gets
401 and nothing is claimed. Admin 42 sends the staff member's sign in with every
drain. The pg_cron job `ami-mail-drain` has to send the key: see the handover.
Tests: 35 (16), 27 (21).
