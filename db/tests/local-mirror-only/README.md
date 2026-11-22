# Do not run these against Supabase

These three are the LOCAL variants of suites 01, 02 and 03. They are written for
a mirror database built by `run_tests.sh` and they are not correct against a
hosted project: pgTAP lives in its own schema there and the search path differs,
so a failure from one of these means nothing at all.

**The files to run on Supabase are the `_supabase.sql` ones, one folder up.**

## Why they are in a folder of their own, from 30 October 2026

They used to sit beside the Supabase variants, one word apart in the same list,
with the local one first alphabetically. On 30 October `03_public_site.sql` was
opened instead of `03_public_site_supabase.sql`, run against staging, and
reported one failure out of 25. Ten minutes went on chasing something that was
not there.

**The giveaway, if it happens again.** A Supabase variant NEVER returns a column
called `finish`. It either raises a red error naming the number of failures, or
returns one row saying `ALL N TESTS PASSED`. If you are looking at a column
headed `finish`, you are running the wrong file.

The set is also incomplete. There is no local variant of 04 and nothing beyond
it, so these three are not a suite and have not been for some time. The mirror
is driven entirely by the `_supabase.sql` files.
