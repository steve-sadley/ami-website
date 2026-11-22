# 0027, the email outbox

What to run, in what order, and what to look at afterwards.

## Run this

In the Supabase SQL editor, on `ami-staging`, in this order.

1. `supabase/migrations/0027_email_outbox.sql`
2. `tests/05_email_supabase.sql`, choosing **Run without RLS** when it asks,
   because the file switches it on itself. Expect **ALL 46 TESTS PASSED**.
3. `tests/02_admin_actions_supabase.sql` again, expecting 30. 0027 rewrites both
   decision functions, so this is the file that proves it did not break them.

Nothing else changes. There are no new Cloudflare bindings: the drain uses the
SMTP2GO key and the Supabase secret that are already there.

## What it does

Approving or refusing an application now queues a letter to the applicant in the
same transaction that records the decision. The Worker sends what is queued.

The reason it is a queue rather than a send is that a decision is made in the
admin app, and the admin app is a browser, and a browser must never hold the
SMTP2GO key. Writing it down first also means the letter cannot be lost by a
network failure, cannot be sent twice by a double click, and is not sent at all
for a decision that was rolled back.

## What to look at once it is in

**The Email queue screen in the admin.** New, beside the other four working
screens. Waiting, Failed, Suppressed, Sent. There is a **Send queued mail**
button on it, which is the same call a decision makes.

**Approve or refuse a TEST application** and watch the row appear and go. If
nothing sends, the queue will say why in the row rather than in a log.

**The wording.** Two templates are seeded, `application_approved` and
`application_refused`. Read both before a real applicant does. They are in
`email_templates` and only a super user may change one, which is new: 0010 let
any editor write to that table, which was harmless while nothing used it and is
not harmless now that it holds letters AMI sends about somebody's membership.

## The three things worth knowing

**A message is claimed before it is sent.** `claim_email_batch` moves a row to
`sending` and counts the attempt before it hands it over, under
`for update skip locked`, so two drains running at once cannot both pick up the
same message. Three attempts and it stops and says why.

**A suppressed address is recorded, not skipped.** If somebody's address is on
the bounce list when the letter is queued, or gets added afterwards, the row goes
to `suppressed` and says so, so the office knows to reach them another way. A
skipped row would sit at `queued` forever looking exactly like one about to go
out.

**`unsettled` in the drain's answer means look at the log.** It counts messages
that were sent but could not be marked as sent, which is the one case where
somebody might get a letter twice. It should always be zero.

## The bug this migration nearly shipped with

`refuse_application` was retyped in 0027 and `app.person_id()` became
`auth.uid()` on the line that writes the application event. Those were the same
value until 0017 and are different now, and `actor_id` is a foreign key to
`people(id)`, so every refusal would have died on the foreign key. All 173
existing tests still passed, because the fixtures in every other test file give a
person the same id for both.

`tests/05` gives them different ids on purpose, and that is the only reason it
was found. Worth copying into the other four files at some point.

## And one that is not fixed, because it cannot be from here

If SMTP2GO accepts a message and the call that marks it sent then fails, the
message is sent again on the next drain. The mark is retried, the count is
reported separately as `unsettled`, and the database caps the whole thing at
three attempts, so the worst case is bounded and visible. Closing it properly
needs an idempotency key at the provider, which is a separate job and only worth
doing if it ever actually happens.
