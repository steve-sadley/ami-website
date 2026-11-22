# AMI phase 1 database

Twenty seven migrations, two seed files and 219 tests, as at 9 August 2026.
Everything here has been applied and proved on a database that mirrors the
`ami-staging` Supabase project. Nothing in it is untested SQL.

`README-detail.md` is the longer note that came with the earlier package and
still holds the design reasoning behind each migration.

## What is in here

```
supabase/migrations/    0001 to 0027, run in order
seeds/                  optional_starting_lists.sql, AMI-banned-words.sql
tests/                  five test files, plus a Supabase editor variant of each
                        and the local Postgres stub
run_tests.sh            rebuild a mirror database and run everything
README-0025.md          what 0025 changed and what to run
README-0027.md          the email outbox: what to run and what to look at
```

## Running it on Supabase

In the SQL editor, in this order. When it asks whether to run with or without
row level security, choose **Run without RLS**: the files switch it on
themselves, and letting Supabase append its own statements means running
something other than what was tested.

1. `supabase/migrations/0001` to `0027`, one at a time, in order.
2. `seeds/optional_starting_lists.sql`, once. Suggested grades, the CPD
   requirement, the 14 activity types, the six forum categories and the three
   hero statements. It is a convenience, not a decision, and everything in it is
   editable in the admin app afterwards.
3. `seeds/AMI-banned-words.sql`, once. 372 entries.
4. `tests/01_security_supabase.sql` — 75 tests
5. `tests/02_admin_actions_supabase.sql` — 30 tests
6. `tests/03_public_site_supabase.sql` — 25 tests
7. `tests/04_member_area_supabase.sql` — 43 tests
8. `tests/05_email_supabase.sql` — 46 tests

219 in total, and none of those numbers should ever go down.

Each test file runs inside a transaction and rolls back, so it leaves nothing
behind and can be run as often as you like. All five run on a populated
database as well as an empty one. Each ends with a single row saying it passed,
or a red error saying it did not. The `_supabase` variants exist because pgTAP
reports a failure as an ordinary row, which in the SQL editor would look like a
quiet pass.

**Do not run `tests/00_local_supabase_stub.sql` against Supabase.** It recreates
the auth schema, `auth.uid()`, the storage schema and the three browser roles,
which already exist there.

## Running it locally

```
./run_tests.sh
```

It drops and rebuilds a mirror database, applies the stub, applies every
migration as a non-superuser role called `owner_test`, loads the starting lists
and the banned words, then runs all three test files and prints the counts.

**Always run the migrations a second time as a non-superuser owner before
handing anything over.** Supabase's migration role is not a superuser, and a
schema owned by a non-superuser behaves differently, because `force row level
security` binds the table owner and superusers escape forcing. That one
difference caused four silent failures that all looked like working code on a
superuser database. The second pass is the only thing that found them.

## The five load bearing pieces

1. **The revoke in 0001.** Supabase grants anon and authenticated broad
   privileges on `public` by default and sets default privileges so every new
   table inherits them. 0001 revokes both, and every table is granted back one at
   a time. A test reads the catalogue directly, so a table added later without
   protection fails the build rather than sitting there readable.
2. **The `restricted` schema is an absence of privilege, not a policy.** The
   browser roles hold nothing on it, not even usage. A view in `public` may never
   select from `restricted`.
3. **The audit log is append only three times over.** No update or delete
   policy, revoked grants, and a trigger that raises. The third is the one that
   matters, because the service role bypasses every policy.
4. **`members.is_active` is the only thing deciding who is current.** No job, no
   calculation. The register, the profile page and the card all read that one
   column.
5. **Policies wrap the helpers**, `(select app.member_id())` and never bare, so
   the planner evaluates once per query rather than once per row.

## Eight tables are deliberately NOT forced

`audit_log`, `banned_words`, `bootstrap_super_users`, `cpd_year_summaries`,
`forum_post_revisions`, `forum_threads`, `role_grants`, `wallet_passes`. All are
written by the schema rather than by a client. A test asserts that exact list, so
a ninth is noticed.

`banned_words` in particular must stay unforced. `app.find_banned_word()` is
security definer and reads it as the table owner, and forcing binds the owner.
Force it and the filter stops working with no error anywhere: every post
publishes and nothing looks wrong.

## Traps worth knowing before you change anything

- **A policy on a table cannot select from that same table.** Postgres raises
  infinite recursion. Use a security definer helper, as `app.post_has_reply()`
  does.
- **`created_at` defaults to `now()`, the transaction timestamp.** Two rows
  written in one transaction carry the same value. `forum_posts.seq` is an
  identity column and every ordering comparison uses that.
- **A policy with no grant is a locked door with no handle.** `members` had an
  insert policy from 0002 and no INSERT grant, so approving an application could
  never work. Check both.
- **PostgREST exposes only the `public` schema.** A function in `app` is
  unreachable from a browser, which is why 0020 adds thin public wrappers.
- **A private bucket is unreachable by an `<img>` tag.** `/object/public/` ignores
  policies entirely and only serves buckets with `public = true`. Content
  pictures live in `public-media`; member photographs stay private and are
  fetched with a signed URL.
- **`storage.objects` belongs to Supabase.** Enabling row level security on it
  and granting on it both fail with "must be owner" on a hosted project and are
  needed on a plain Postgres, so both are attempted and their failure ignored.
  Creating policies on it works on both.
- **Some columns do not exist on the plain Postgres stub**, `storage.buckets
  .file_size_limit` among them, so 0023 wraps that part in an exception block.
- **Use named arguments** for `submit_application()`. It has fourteen parameters
  and positional calls silently passed a telephone number into a date column.

## Every fixture is collision proof

Test fixtures use `.invalid` email addresses, which the internet standards
reserve and nobody can register, `TEST-` membership numbers and `test-` slugs.
The suite runs on staging, where real rows already exist. A test that only ever
meets an empty database is a test nobody has run where it matters.
