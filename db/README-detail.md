# AMI website, phase 1 database

The schema, the access rules and the tests that prove them, for the rebuilt
ami.uk.com on Cloudflare Pages plus Workers plus Supabase.

Written from `AMI-Phase-1-Data-Model-and-Security-Specification.docx` version 3.0,
8 August 2026. Where this and the specification disagree, this is right and the
specification needs updating, because this has been run.

## State

Every migration applies cleanly and all 56 access tests pass. 50 tables, 173
policies.

It has been run end to end twice, on PostgreSQL 16 against the local stub in
`tests/00_local_supabase_stub.sql`: once with the schema owned by a superuser,
and once with it owned by a role that is **not** a superuser, which is what a
hosted Supabase project actually gives you. The second run is the one that
matters, and the first version of this schema failed it. See "Why some tables are
not forced" below. It has NOT yet been applied to a hosted Supabase project.

## What is in here

```
supabase/migrations/
  0001_foundation.sql        schemas, the revoke, shared triggers, enum types
  0002_identity.sql          people, members, grades, years, preferences, slugs, roles
  0003_helpers.sql           the functions every policy calls
  0004_identity_rls.sql      policies for 0002
  0005_audit.sql             audit log, sign in events, feature usage
  0006_applications.sql      the membership application, and approval
  0007_cpd.sql               requirements, activity types, entries, summaries
  0008_forum.sql             categories, threads, posts, the banned word filter
  0009_card.sql              wallet passes, registrations, issues
  0010_content_and_email.sql news, events, guidance, videos, email, consent
  0011_storage.sql           four private buckets and their policies
  0012_public_views.sql      the only three things anon can read
  0013_bootstrap.sql         the six role codes, and the first super user
  0014_configuration.sql     grade fees and admin settings

seeds/
  optional_starting_lists.sql  suggested values, NOT run automatically

tests/
  00_local_supabase_stub.sql local development only, NEVER run against Supabase
  01_security.sql            56 pgTAP tests of the access rules
```

Policies live in the same migration as their tables, with one exception. The
identity tables in 0002 come before the helper functions in 0003, because the
helpers read them, so their policies are in 0004.

## Running it locally

```bash
apt-get install -y postgresql-16 postgresql-16-pgtap
initdb -D ./pgdata && pg_ctl -D ./pgdata -o '-p 5433' start
createdb -p 5433 ami

psql -p 5433 -d ami -f tests/00_local_supabase_stub.sql
for f in supabase/migrations/*.sql; do psql -p 5433 -v ON_ERROR_STOP=1 -d ami -f "$f"; done
psql -p 5433 -d ami -f tests/01_security.sql
```

The test file wraps everything in a transaction and rolls back, so it can be run
repeatedly against the same database.

## Applying it to Supabase

Do NOT run `00_local_supabase_stub.sql`. Supabase provides the auth schema, the
`auth.uid()` function, the storage schema and the three roles already.

```bash
supabase link --project-ref <ref>
supabase db push
```

Then run `tests/01_security.sql` against the staging project through the SQL
editor or `psql`, having first enabled pgTAP with `create extension pgtap`.

Migrations are files and belong in version control. Never type a change into the
Supabase dashboard: a schema that exists only in a hosted editor cannot be
rebuilt, reviewed or rolled back.

## Nothing is hard coded

Two things only are written into a migration. The six role codes, because the
helper functions in 0003 name them, so adding a seventh means changing a function
as well as a row. And one email address, `steve.sadley@arca.org.uk`, so that
somebody can get in at all.

Everything else is configuration, set from the backend:

| Set in the backend | Table |
|---|---|
| Membership grades, and which require CPD | `membership_grades` |
| The fee for each grade and year | `grade_fees` |
| The CPD requirement, per year and per grade | `cpd_requirements` |
| CPD activity types and the core split | `cpd_activity_types` |
| Forum categories | `forum_categories` |
| The banned word list | `banned_words` |
| The rotating home page headline | `hero_statements` |
| Who holds which role | `role_grants` |
| The way back in | `bootstrap_super_users` |
| Anything else | `admin_settings` |

That list is also the list of admin screens phase 2 has to build.

`seeds/optional_starting_lists.sql` holds a suggested starting set for the lists
that came out of the design sessions. It is optional, it is never run
automatically, and it is a convenience rather than a decision. The banned word
list is not in it, and should not be: it is data, it belongs to the office, and a
list of words in a repository is a list of words somebody reads. Fees are not in
it either, because a placeholder fee in a seed file is the kind of thing that
ends up on an invoice.

## How the first super user gets in

A role can only be granted by a super user, so the first one cannot be granted by
anybody. `bootstrap_super_users` is the way in. An address listed there is
granted `super_user` and `administrator` automatically the first time a person
row is created for it, and the grant goes to the audit log like any other.

Listing an address grants nothing on its own. Nothing is created for that person
and nothing happens until they actually sign in.

It is also the way BACK in. If the only super user ever loses their account, add
an address, have that person sign in, and they arrive with the role. The table is
readable and writable by a super user and by nobody else, because a readable list
of the accounts worth attacking is exactly that.

**On having only one.** The trigger in 0002 stops a super user removing their own
role, so the common accident is covered. One super user still means one person
who can grant anything, and one person whose absence stops everybody. The
recovery route above exists for that, and a second named super user remains the
safer position whenever Steve wants one.

## The five things worth understanding before changing anything

**0. Why some tables are not forced.** `force row level security` extends the
policies to the TABLE OWNER as well. That is the only thing it does, and client
keys are `anon` and `authenticated`, never the owner, so forcing adds nothing
against the threat this design is built for. What it does affect is the schema's
own machinery: a trigger function is security definer, so it runs as the owner,
and under forcing it is refused by the policies on the table it exists to
maintain.

On a local Postgres that is invisible, because the owner is a superuser and
superusers escape forcing. On Supabase the migration role is not a superuser, so
it is not invisible at all: the first attempt to create a member fails, and so
does the banned word filter, silently, which is worse.

Eight tables are therefore enabled and not forced, and every one is written by
this schema rather than by a client: `audit_log`, `banned_words`,
`bootstrap_super_users`, `cpd_year_summaries`, `forum_post_revisions`,
`forum_threads`, `role_grants` and `wallet_passes`. Test 2 asserts that list
exactly, so a ninth appearing is noticed. Tests 51 to 53 prove a client still
cannot write to them. Everything else, including `people`, `members`,
`membership_years` and `cpd_entries`, remains forced.

`app.approve_application()` was changed from security definer to security invoker
for the same reason. It now runs as the member of staff who called it, so every
row it writes is written under their own policies and appears in the audit log
under their name. A function that escalates to the owner would work too, and
would quietly become a way round the policies it sits behind.

**1. The revoke in 0001 is the foundation.** Supabase grants `anon` and
`authenticated` broad privileges on the public schema by default, and sets
default privileges so every new table inherits them. 0001 revokes both. Every
table since is granted back one at a time. Without that revoke, a table where
somebody forgets to enable row level security is readable by the world, and the
whole design rests on nobody ever forgetting. Test 1 checks the catalogue for
exactly that, so a table added later without protection fails the build.

**2. The restricted schema is not a policy, it is an absence of privilege.**
`anon` and `authenticated` hold nothing on it, not even usage on the schema
itself, so no query from a browser can reach it however wrongly a policy is
written. One rule goes with it: **a view in `public` may never select from
`restricted`.** A security definer view would reach straight through the split
and undo the point of it.

**3. The audit log is append only twice over.** It has no update or delete
policy, and that alone is not enough, because every write in the system goes
through a Worker holding the service role, which is exempt from every policy.
Update and delete are also revoked at the grant level and blocked by a trigger
that raises, and that is proved for staff and for the service role.

**4. `members.is_active` is the only thing that decides who is current.** No job
lapses a membership, no calculation infers it, and nothing except a member of
staff can change it. The register, the profile page and the card all read that
one column. If somebody appears who should not, there is one place to look.

**5. Policies wrap the helpers.** Always `(select app.member_id())`, never a bare
`app.member_id()`. Wrapped, the planner evaluates it once per query. Bare, it
evaluates once per row, and on `cpd_entries` and `forum_posts` that is the
difference between a fast page and a slow one.

## Three subtleties that cost time to find

**A policy on a table cannot select from that same table.** The first version of
the forum edit rule did, and Postgres raised "infinite recursion detected in
policy". The answer is `app.post_has_reply()`, which is security definer, so it
reads the table with the owner's rights and the recursion never starts.

**A schema owned by a non superuser behaves differently.** Everything above about
forcing was found by running the migrations as a role without superuser rights,
which is what Supabase gives you. Always run that second pass before handing
anything over.

**`created_at` defaults to `now()`, which is the transaction timestamp.** Two
posts written in one transaction carry the same value, so "does this post have a
reply" cannot be answered by comparing timestamps. `forum_posts.seq` is an
identity column and the comparison uses that. The same trap is waiting anywhere
else ordering matters within a transaction.

## What is deliberately not here

No payments, no payment provider, no card detail, anywhere. AMI invoices and
collects exactly as it does now, and the office records the result against the
membership year. `membership_years` keeps the fee and payment columns so that if
online payment is ever added it fills in a row that already exists.

No verified scopes, no change notices, no automatic CPD, no assessment engine, no
employer accounts. All designed, all deferred, and all recorded in section 2.4 of
the specification with the reason.

`cpd_entries` carries `how_recorded`, `rule_id` and `source_id` from day one even
though nothing writes an automatic entry yet, and there is a check constraint
saying an automatic entry cannot exist without a rule and a source behind it.
That constraint is what will make the first automatic award defensible.

## Still needed before this goes live

None of these blocks the schema any more. Each is now a value somebody types into
the backend rather than a line somebody edits in a file.

- Sign in as `steve.sadley@arca.org.uk`, which arrives holding `super_user`.
- Set the grades, the CPD requirement, the activity types, the forum categories,
  the fees and the banned words, either from scratch or by running
  `seeds/optional_starting_lists.sql` first and editing from there.
- Grant the other roles to the office.
- The Playwright half of the test suite: cross site scripting payloads in every
  free text field, a file with a permitted extension and a disallowed signature,
  the wallet pass updating on a real device when a membership is switched off,
  and an A grade on the security headers and the TLS configuration.
- An independent penetration test before launch.
