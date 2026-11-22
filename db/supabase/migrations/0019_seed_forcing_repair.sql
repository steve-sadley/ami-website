-- =============================================================================
-- 0019  Repairing what the seed file put back
--
-- Migration 0018 removed FORCE from every table and explained at length why it
-- had to go. The optional starting lists then ran AFTER it and ended with five
-- lines putting forcing back on membership_grades, cpd_requirements,
-- cpd_activity_types, forum_categories and hero_statements. A seed runs after
-- the migrations, so the seed won.
--
-- That is the fourth failure from 0018 again, on the five tables the public site
-- reads most. The register renders grades. The home page renders hero statements.
-- Both are read through views owned by the same role forcing binds, so an
-- anonymous visitor would have got an empty page and no error anywhere.
--
-- It did not show up in testing because the test databases never had the starting
-- lists loaded, and it did not show up in the SQL editor because that connects as
-- a superuser, which escapes forcing. It only appears on the live site, to the
-- public, silently. Exactly the shape of the bug 0018 was written about.
--
-- The seed file has been corrected. This migration repairs a database where the
-- old copy has already run.
-- =============================================================================

do $$
declare t record;
begin
  for t in
    select n.nspname, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'restricted')
       and c.relkind = 'r'
       and c.relforcerowsecurity
  loop
    raise notice 'forcing removed from %.%', t.nspname, t.relname;
    execute format('alter table %I.%I no force row level security', t.nspname, t.relname);
  end loop;
end $$;

-- Row level security itself stays ENABLED everywhere. That is the setting that
-- matters and the one the tests assert on.
do $$
declare t record;
begin
  for t in
    select n.nspname, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'restricted')
       and c.relkind = 'r'
       and not c.relrowsecurity
  loop
    execute format('alter table %I.%I enable row level security', t.nspname, t.relname);
  end loop;
end $$;

-- The report. Both counts must read 0.
select count(*) filter (where c.relforcerowsecurity) as still_forced,
       count(*) filter (where not c.relrowsecurity)  as rls_off
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('public', 'restricted') and c.relkind = 'r';
