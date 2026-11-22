# 0033, reissuing a card

Run this before pressing Add on the card page again. Two minutes.

## What was wrong

`wallet_passes` has a unique index allowing one live pass per member per
platform, and a trigger meant to revoke the old one when a new one is issued.
The trigger was AFTER INSERT.

**A unique index is enforced as the row goes in. An AFTER INSERT trigger runs
once it is already there.** So the second card a member ever issued was refused
by the index, and the trigger that would have made room for it never ran.

The first card a member issues works. Every one after it fails with 23505. That
means Reissue my card has never worked, and neither has the ordinary Add button
for anybody who already holds a card. Losing a phone is precisely when a member
needs this, so it is not a small one.

It showed on the site as "Your card could not be issued just now", which is the
message for any database refusal the Worker does not recognise.

## Why nothing caught it

Every fixture in the other eight suites issued exactly one card, and one card is
the only case that passes. **No test had ever called `issue_my_card` at all.**

That also hid a second thing: `issue_my_card` calls `extensions.gen_random_bytes`
and the mirror installed pgcrypto into `public`, so the function raised "schema
extensions does not exist" on the mirror while working perfectly on staging.
`run_tests.sh` now creates the `extensions` schema and installs pgcrypto into it,
the way Supabase does. That is a mirror that had been quietly lying about the
thing it exists to check.

## What to run

In the Supabase SQL editor, in this order.

**1. The migration.** Paste `supabase/migrations/0033_card_reissue.sql` and run
it. It drops the trigger and recreates it as BEFORE INSERT. The function body is
untouched. There is no data to repair: the index made a second live row
impossible, so there is at most one live pass per member and it is the one they
are holding.

**2. The new suite.** Paste `tests/09_card_reissue_supabase.sql` and choose **Run
without RLS** when it asks, because the file switches it on itself.

Expect:

```
ALL 19 TESTS PASSED
```

**3. Then 04, to be sure nothing else moved.** Expect 51.

The whole set is now 365: 75, 30, 25, 51, 46, 49, 42, 28 and 19.

## What the new suite covers

The second card and the third, because a fix that works once is not a fix. That
the old pass is revoked rather than deleted, and says why. That the serial and
the token change every time. That a reissue on Apple leaves a live Google pass
alone. That another member reissuing does not revoke yours. That a membership
which has been switched off cannot mint a card, and nor can an account with no
membership.

## If you cleared a pass by hand

You do not need to undo it. A pass revoked by hand is in exactly the state the
trigger would have left it in, and the reason column simply says something
different.

## Proved rather than assumed

The mirror was rebuilt from scratch by a non superuser owner, the bug was
reproduced first with 0033 held back, and the same run passed once it was put
back. All nine suites, 365 tests.
