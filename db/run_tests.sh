#!/bin/bash
# Rebuilds a database that mirrors ami-staging and runs every suite against it.
#
# All migrations are run by a NON-SUPERUSER owner, which is the whole point:
# Supabase's migration role is not a superuser, a superuser escapes FORCE row
# level security, and that one difference caused four silent failures in 0018
# that all looked like working code locally.
#
# Three things changed on 15 August 2026:
#   the paths come from the script's own location rather than being absolute,
#     so the bundle runs wherever it is unzipped
#   owner_test is granted membership of anon, authenticated and service_role,
#     because the test files switch role as they go and the Supabase SQL editor
#     connects as a superuser, which may set role to anything. owner_test may
#     not, so without this every suite dies on its first role switch
#   it actually runs the suites, and prints the counts
set -e
DB=${1:-ami_mirror}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="su postgres -c"

$P "dropdb --if-exists $DB" >/dev/null
$P "psql -q -c \"drop role if exists owner_test\" postgres" >/dev/null
$P "psql -q -c \"create role owner_test login password 'x' createrole\" postgres" >/dev/null
$P "createdb -O owner_test $DB"

# extensions and the stub need a superuser; everything after this is owner_test.
$P "psql -q -v ON_ERROR_STOP=1 -d $DB -c 'create extension if not exists pgtap'" >/dev/null
# pgcrypto lives in the `extensions` schema on Supabase, and issue_my_card calls
# extensions.gen_random_bytes by that name. Installed into public here, the
# function raises "schema extensions does not exist" on the mirror while working
# perfectly on staging, which is the mirror lying about the thing it exists to
# check. 23 August 2026.
$P "psql -q -v ON_ERROR_STOP=1 -d $DB -c 'create schema if not exists extensions'" >/dev/null
$P "psql -q -v ON_ERROR_STOP=1 -d $DB -c 'create extension if not exists pgcrypto with schema extensions'" >/dev/null
$P "psql -q -d $DB -c 'grant usage on schema extensions to public'" >/dev/null 2>&1 || true
$P "psql -q -v ON_ERROR_STOP=1 -d $DB -f $ROOT/tests/00_local_supabase_stub.sql" >/dev/null
# Supabase's migration role does not own storage.objects either, but it can write
# policies on it. Hand it over so the run models the real thing.
$P "psql -q -d $DB -c \"do \\\$\\\$ declare t record; begin for t in select tablename from pg_tables where schemaname='storage' loop execute format('alter table storage.%I owner to owner_test', t.tablename); end loop; end \\\$\\\$\"" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant all on schema storage to owner_test'" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant all on schema auth to owner_test'" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant all on all tables in schema auth to owner_test'" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant anon, authenticated, service_role to owner_test'" >/dev/null

export PGPASSWORD=x
for f in $ROOT/supabase/migrations/*.sql; do
  echo "  $(basename $f)"
  psql -h 127.0.0.1 -U owner_test -d $DB -q -v ON_ERROR_STOP=1 -f "$f" > /tmp/mig.log 2>&1 \
    || { echo "FAILED $(basename $f)"; tail -25 /tmp/mig.log; exit 1; }
done

for s in optional_starting_lists AMI-banned-words membership_grades_full_set; do
  echo "  seeds/$s.sql"
  psql -h 127.0.0.1 -U owner_test -d $DB -q -v ON_ERROR_STOP=1 -f "$ROOT/seeds/$s.sql" > /tmp/seed.log 2>&1 \
    || { echo "FAILED seeds/$s"; tail -25 /tmp/seed.log; exit 1; }
done

# A member who has nothing to do with any test file, because ami-staging has
# real rows in it and a mirror that does not is a mirror that lies. Six checks in
# 07 counted "every active member who takes the newsletter", passed on an empty
# mirror and failed on staging. This is what makes that fail here instead.
psql -h 127.0.0.1 -U owner_test -d $DB -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
insert into public.membership_grades (code, name, post_nominals, sort_order)
values ('mirror-real','Mirror Real Grade','MRG',97) on conflict (code) do nothing;
insert into public.people (id, given_name, family_name, email)
values ('77000000-0000-0000-0000-000000000001','Mirror','Member','mirror.member@example.com')
on conflict (id) do nothing;
insert into public.members (id, person_id, membership_number, grade_id, joined_on, is_active, status)
select '77b00000-0000-0000-0000-000000000001','77000000-0000-0000-0000-000000000001','MIRROR-0001',
       g.id, date '2021-01-01', true, 'current'
  from public.membership_grades g where g.code = 'mirror-real'
on conflict (id) do nothing;
insert into public.member_preferences (member_id)
values ('77b00000-0000-0000-0000-000000000001') on conflict (member_id) do nothing;
SQL

echo "--- loaded ---"
psql -h 127.0.0.1 -U owner_test -d $DB -qtA -c "select 'grades='||(select count(*) from public.membership_grades)||' cpd_req='||(select count(*) from public.cpd_requirements)||' types='||(select count(*) from public.cpd_activity_types)||' cats='||(select count(*) from public.forum_categories)||' hero='||(select count(*) from public.hero_statements)||' banned='||(select count(*) from public.banned_words)||' templates='||(select count(*) from public.email_templates)"

echo "--- tests ---"
fail=0
for f in $ROOT/tests/[0-9][0-9]_*_supabase.sql; do
  printf '  %-42s ' "$(basename $f)"
  out=$(psql -h 127.0.0.1 -U owner_test -d $DB -qtA -f "$f" 2>&1 \
        | grep -E 'TESTS PASSED|TESTS FAILED|ERROR' | head -1)
  echo "$out"
  case "$out" in *"TESTS PASSED"*) ;; *) fail=1 ;; esac
done

# The total is added up from what the files said rather than written here, so
# it cannot go on claiming 412 after a file is added. It said 412 for a week.
total=$(for f in $ROOT/tests/[0-9][0-9]_*_supabase.sql; do
  psql -h 127.0.0.1 -U owner_test -d $DB -qtA -f "$f" 2>/dev/null \
    | grep -oE 'ALL [0-9]+ TESTS PASSED' | grep -oE '[0-9]+'; done | paste -sd+ | bc)
echo
if [ "$fail" -eq 0 ]; then
  echo "$total database tests, all passing."
else
  echo "SOMETHING FAILED. None of these numbers should ever go down."
  exit 1
fi
