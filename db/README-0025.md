# 0025, the members area: what to run and in what order

Run these in the Supabase SQL editor on `ami-staging`, in this order.

1. `supabase/migrations/0025_member_area.sql`
2. `tests/04_member_area_supabase.sql`

Then re-run the three existing test files. All four should end with a single
green line. If any of them ends in red, stop.

    tests/01_security_supabase.sql        70 tests
    tests/02_admin_actions_supabase.sql   30 tests
    tests/03_public_site_supabase.sql     25 tests
    tests/04_member_area_supabase.sql     43 tests

168 in total, and all 168 pass on a mirror of ami-staging rebuilt from scratch by
a non superuser owner, which is the only way the four silent failures in 0018 to
0020 were ever found.

## The two bugs 0025 fixes

**The audit trigger was writing the wrong id, and every audited write by a member
created after 0017 would have failed.** `app.audit_row()` recorded the actor as
`auth.uid()`, and `audit_log.actor_id` references `people(id)`. Those were the
same value until 0017 separated a person from their account. 0017 backfilled the
existing rows so nothing broke at the time, and every test still passed because
the test fixtures give a person the same id for both. Every person created since
has two different values, so the foreign key is violated and the whole statement
is refused. The tables carrying an audit trigger include `members`,
`membership_years`, `cpd_entries` and `wallet_passes`, so a member logging a CPD
entry, the office approving an application and issuing a card would all have
failed outright on the first real member.

`tests/04` uses different values for the two columns deliberately. That is what
surfaced it.

**The two photograph policies keyed on different ids.** 0011 says the first path
segment is the owning person's id and applies that to all four buckets. 0021's
`member_photo_public` used the member id. A photograph stored under one is
unreachable by the other, so either the verification page silently shows no
picture or the member cannot upload at all, with no error either way. 0025
rewrites the public policy to reach the membership through `people`, keeping all
three conditions re-checked on every request. Nothing has been uploaded yet, so
there is nothing to migrate.

---

# 0026, the card and the verification page

Run in the Supabase SQL editor, in this order:

1. `supabase/migrations/0026_card_and_verification.sql`
2. `tests/01_security_supabase.sql`   now **75** tests, not 70
3. `tests/04_member_area_supabase.sql`

Then 02 and 03 if you want the full set. 173 in total.

## What 0026 changes

**The verification page can now say no.** On Steve's decision of 9 August, an
inactive membership is no longer filtered out of `public_profile`. It answers, and
it says plainly that the person is not a current member. A code already printed on
a card outlives the membership behind it, and a duty holder needs to be able to
tell a lapsed member from a forged card.

What an inactive row does not carry is as considered as what it does. The
photograph, the employer and the CPD position all go: somebody who has left has
not agreed to AMI publishing their face and their employer indefinitely. The name,
the number and the grade stay, because those three are what a duty holder is
matching against the card in their hand.

Five tests in 01 were rewritten to assert the new behaviour and the three things
that must NOT appear. Test 55 used to assert the opposite and would otherwise have
passed for the wrong reason.

**The view is dropped and recreated rather than replaced**, because CREATE OR
REPLACE cannot add a column in the middle of a view. Dropping a view drops its
grants with it, so the grant to anon is restated. Forgetting that line would take
every card down for everybody who is not signed in, which is everybody scanning
one.

**`issue_my_card`** generates the serial and the auth token, stores only the
token's hash, and returns the token once. Issuing revokes the previous pass by the
trigger in 0009, so a lost phone stops verifying the moment a new card is issued.
