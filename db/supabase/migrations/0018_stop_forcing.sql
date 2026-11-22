-- =============================================================================
-- 0018  Stop forcing row level security, and say why
--
-- This removes FORCE from every table. It is not a weakening, and the reasoning
-- matters more than the change, so it is written out in full.
--
-- WHAT FORCE ACTUALLY DOES
--
-- Row level security applies to everybody EXCEPT the table owner. FORCE extends
-- it to the owner as well. That is the only thing it does.
--
-- Nothing that reaches this database from a browser is the owner. The public key
-- authenticates as `anon`. A signed in member authenticates as `authenticated`.
-- Neither has ever been affected by FORCE, before or after this migration, and
-- both are still bound by exactly the same grants and policies they were bound by
-- yesterday. The service role bypasses row level security entirely and always did.
--
-- So FORCE was never protecting against the thing this design exists to protect
-- against. What it did do was bind the ONE role that has to be able to read these
-- tables: the owner, which is what every trigger function, every security definer
-- helper and every public view runs as.
--
-- WHAT IT BROKE, IN ORDER
--
-- 1. Every audit trigger, every CPD summary refresh, every forum counter and the
--    approval function, all refused by the policies on the tables they exist to
--    maintain. Invisible locally, because a local superuser escapes FORCE. Fatal
--    on Supabase, where the migration role is not a superuser.
--
-- 2. The banned word filter. app.find_banned_word() reads banned_words as the
--    owner, so forcing it meant the function found nothing and every post
--    published. No error, anywhere. That one would have been discovered by
--    somebody swearing on the forum.
--
-- 3. app.person_id(), once a person stopped being their login. It reads people,
--    the policies on people call it, and Postgres stops the loop with "stack
--    depth limit exceeded".
--
-- 4. THE PUBLIC REGISTER. The three public views are owned by the same role, so
--    under FORCE they returned nothing to an anonymous visitor. The register and
--    every profile page would have been blank for the public, and the tests did
--    not catch it because they only checked that the query did not ERROR. That is
--    the fourth failure from one setting, and it is the one that would have gone
--    live.
--
-- FOUR FAILURES, ALL SILENT, FROM A SETTING THAT DEFENDS AGAINST NOTHING IN THIS
-- ARCHITECTURE. So it goes.
--
-- WHAT STILL PROTECTS THE DATA, UNCHANGED
--
--   The revoke in 0001, so anon and authenticated hold nothing they were not
--   granted one table at a time.
--   Row level security ENABLED on every table, with default deny.
--   A policy per command, so a read never confers a write.
--   The restricted schema, which those roles cannot see at all.
--   Three public views that expose named columns and filter themselves.
--   The service role key living only in Worker bindings.
--
-- The tests are the proof, and this migration comes with four more of them: that
-- an anonymous visitor gets the RIGHT ROWS from the register and the profile, not
-- merely no error, which is the check whose absence let this through.
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
    execute format('alter table %I.%I no force row level security', t.nspname, t.relname);
  end loop;
end $$;

-- Belt and braces: row level security itself stays ENABLED everywhere. This is
-- the setting that matters and the one the tests assert on.
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
