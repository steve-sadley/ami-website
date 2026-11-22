-- =============================================================================
-- 0001  Foundation
--
-- Schemas, the revoke that the whole security design depends on, and the shared
-- trigger functions. Nothing here creates a table.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Schemas
-- -----------------------------------------------------------------------------
-- app         helper functions used by policies. No tables.
-- restricted  material no browser may ever query. See 0005.
create schema if not exists app;
create schema if not exists restricted;

comment on schema app is
  'Helper functions used by row level security policies. Contains no tables.';
comment on schema restricted is
  'Material no browser may query under any circumstances. anon and authenticated '
  'hold no privileges here, not even usage. Reached only by a Worker holding the '
  'service role. A view in public may NEVER select from this schema.';

-- -----------------------------------------------------------------------------
-- The revoke
-- -----------------------------------------------------------------------------
-- Supabase grants anon and authenticated broad privileges on the public schema
-- by default, and sets default privileges so every NEW table inherits them.
-- Without this block, any table where somebody later forgets to enable row level
-- security is readable by the world, and the entire design rests on nobody ever
-- forgetting. Every table below is granted back explicitly, one at a time.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- restricted is invisible. Not select, not usage on the schema itself.
revoke all on schema restricted from anon, authenticated;
alter default privileges in schema restricted revoke all on tables from anon, authenticated;

-- app holds functions that policies call, so the roles need usage on the schema.
-- Execute is granted per function in 0003.
grant usage on schema app to anon, authenticated, service_role;
revoke all on all functions in schema app from anon, authenticated;
alter default privileges in schema app revoke all on functions from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared trigger functions
-- -----------------------------------------------------------------------------
create or replace function app.set_updated_at() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function app.set_updated_at() is
  'Maintains updated_at. Attached to every editable table.';

-- Blocks update and delete outright, whatever the caller. Used on the audit log,
-- because the service role bypasses every policy and would otherwise be able to
-- rewrite the record of what it did.
create or replace function app.deny_write() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'This table is append only. % is not permitted on %.',
    tg_op, tg_table_name using errcode = '42501';
end;
$$;

comment on function app.deny_write() is
  'Raises on update or delete. The audit log is append only and this is what '
  'makes that true for the service role as well as for staff.';

-- -----------------------------------------------------------------------------
-- Enumerated types
-- -----------------------------------------------------------------------------
-- Only where the list is genuinely settled. Anything AMI staff need to change
-- without a developer is a lookup table instead, because an enum value cannot be
-- removed and ALTER TYPE ... ADD VALUE cannot run in the transaction that uses it.
create type public.member_status as enum
  ('applicant', 'current', 'lapsed', 'resigned', 'removed');

create type public.application_status as enum
  ('draft', 'submitted', 'under_review', 'approved', 'refused', 'withdrawn');

create type public.cpd_how_recorded as enum
  ('self_declared', 'awarded_by_ami', 'automatic');

create type public.cpd_entry_status as enum
  ('pending', 'accepted', 'rejected');

create type public.forum_thread_status as enum
  ('published', 'hidden', 'removed');

create type public.forum_post_status as enum
  ('published', 'held', 'hidden', 'removed');

create type public.word_match_type as enum
  ('whole_word', 'contains');

create type public.wallet_platform as enum
  ('apple', 'google');

create type public.card_issue_reason as enum
  ('first_issue', 'renewal', 'photograph_changed', 'replacement');

create type public.content_status as enum
  ('draft', 'published', 'archived');
