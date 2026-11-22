#!/bin/bash
# Rebuild a mirror in the order STAGING saw it: every migration up to LAST,
# then the starting lists exactly as they were run on staging in August, then
# the newer migrations TWICE, then every suite.
#
# WHY. run_tests.sh seeds AFTER every migration, so a migration meets an empty
# table there and a full one on staging. 0038 passed the mirror and failed on
# staging on 30 October for exactly that reason. Run this before handing over a
# migration that touches a table the starting lists fill.
#
# Usage:  tools/replay-staging-order.sh LAST [SEEDED_AT]
#   LAST       the last migration staging already has, e.g. 0039
#   SEEDED_AT  the migration after which the starting lists were run on staging
#              in August; 0020 by default. The first version of this tool seeded
#              just before the new migrations, which is right only for the first
#              migration after a seed and wrong for every one after that.
set -e
DB=ami_stage
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; LAST=${1:?give the last migration staging already has, e.g. 0037}; SEEDED_AT=${2:-0020}
P="su postgres -c"
$P "dropdb --if-exists $DB" >/dev/null
$P "createdb -O owner_test $DB"
$P "psql -q -d $DB -c 'create extension if not exists pgtap'" >/dev/null
$P "psql -q -d $DB -c 'create schema if not exists extensions'" >/dev/null
$P "psql -q -d $DB -c 'create extension if not exists pgcrypto with schema extensions'" >/dev/null
$P "psql -q -d $DB -c 'grant usage on schema extensions to public'" >/dev/null
$P "psql -q -v ON_ERROR_STOP=1 -d $DB -f $R/tests/00_local_supabase_stub.sql" >/dev/null
$P "psql -q -d $DB -c \"do \\\$\\\$ declare t record; begin for t in select tablename from pg_tables where schemaname='storage' loop execute format('alter table storage.%I owner to owner_test', t.tablename); end loop; end \\\$\\\$\"" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant all on schema storage to owner_test'" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant all on schema auth to owner_test'" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant all on all tables in schema auth to owner_test'" >/dev/null 2>&1 || true
$P "psql -q -d $DB -c 'grant anon, authenticated, service_role to owner_test'" >/dev/null
export PGPASSWORD=x
run(){ psql -h 127.0.0.1 -U owner_test -d $DB -q -v ON_ERROR_STOP=1 -f "$1" > /tmp/replay-stage.log 2>&1 || { echo "FAILED $(basename $1)"; tail -5 /tmp/replay-stage.log; exit 1; }; }
NEW=(); SEEDED=0
# The grades seed needs columns added later than the starting lists, so it goes
# in just before the new migrations, which is where it sat on staging too.
seed(){ run $R/tools/starting-lists-as-run-on-staging.sql; run $R/seeds/AMI-banned-words.sql; SEEDED=1; }
for f in $R/supabase/migrations/*.sql; do
  n=$(basename $f | cut -c1-4)
  if [[ "$n" > "$SEEDED_AT" && $SEEDED -eq 0 ]]; then seed; fi
  if [[ "$n" > "$LAST" ]]; then NEW+=("$f"); else run $f; fi
done
[ $SEEDED -eq 1 ] || seed
run $R/seeds/membership_grades_full_set.sql
for f in "${NEW[@]}"; do run $f; echo "  ran $(basename $f)"; done
for f in "${NEW[@]}"; do run $f; done; echo "  and all of them a second time"
for f in $R/tests/[0-9][0-9]_*_supabase.sql; do
  printf '  %-42s ' $(basename $f); psql -h 127.0.0.1 -U owner_test -d $DB -qtA -f $f 2>&1 | grep -E 'TESTS PASSED|TESTS FAILED|ERROR' | head -1
done

# Leave nothing behind: run_tests.sh drops and recreates owner_test, which it
# cannot do while this database still belongs to it.
su postgres -c "dropdb --if-exists $DB"
