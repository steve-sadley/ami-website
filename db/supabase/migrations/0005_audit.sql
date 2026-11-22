-- =============================================================================
-- 0005  Audit log, sign in events, feature usage
--
-- The audit log is append only, and that is enforced twice: no update or delete
-- policy, AND revoked grants plus a trigger that raises. The second layer is the
-- one that matters, because every write in the system goes through a Worker
-- holding the service role, which is exempt from every policy. A log the
-- application can rewrite is not a log.
-- =============================================================================

create table public.audit_log (
  id          bigserial primary key,
  occurred_at timestamptz not null default now(),
  actor_id    uuid references public.people(id),
  actor_role  text,
  action      text not null,
  table_name  text not null,
  row_id      text,
  before      jsonb,
  after       jsonb,
  note        text
);
create index audit_log_time  on public.audit_log (occurred_at desc);
create index audit_log_table on public.audit_log (table_name, row_id);
create index audit_log_actor on public.audit_log (actor_id, occurred_at desc);

alter table public.audit_log enable row level security;
-- NOT forced, deliberately. See the note at the end of this file.
alter table public.audit_log no force row level security;
grant select on public.audit_log to authenticated;

create policy audit_select_staff on public.audit_log
  for select to authenticated using ((select app.is_staff()));
-- No insert policy for authenticated: rows are written by the trigger below,
-- which is security definer, and by Workers holding the service role.
-- No update or delete policy for anybody.

revoke update, delete on public.audit_log from public, anon, authenticated, service_role;

create trigger audit_log_append_only
  before update or delete on public.audit_log
  for each row execute function app.deny_write();

-- -----------------------------------------------------------------------------
-- The generic audit trigger
-- -----------------------------------------------------------------------------
create or replace function app.audit_row() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after  jsonb;
  v_row_id text;
begin
  if tg_op = 'DELETE' then
    v_before := to_jsonb(old);
    v_row_id := (to_jsonb(old) ->> 'id');
  elsif tg_op = 'INSERT' then
    v_after  := to_jsonb(new);
    v_row_id := (to_jsonb(new) ->> 'id');
  else
    v_before := to_jsonb(old);
    v_after  := to_jsonb(new);
    v_row_id := (to_jsonb(new) ->> 'id');
    -- an update that changed nothing is noise, not history
    if v_before = v_after then
      return new;
    end if;
  end if;

  insert into public.audit_log (actor_id, actor_role, action, table_name, row_id, before, after)
  values (auth.uid(), current_user, tg_op, tg_table_name, v_row_id, v_before, v_after);

  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

comment on function app.audit_row() is
  'Attach to any table whose changes must be answerable later. Writes the actor, '
  'the operation and the before and after values.';

-- Attached to everything whose change somebody may one day have to explain.
create trigger members_audit
  after insert or update or delete on public.members
  for each row execute function app.audit_row();
create trigger membership_years_audit
  after insert or update or delete on public.membership_years
  for each row execute function app.audit_row();
create trigger role_grants_audit
  after insert or update or delete on public.role_grants
  for each row execute function app.audit_row();
create trigger membership_grades_audit
  after insert or update or delete on public.membership_grades
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- auth_events
-- -----------------------------------------------------------------------------
create table public.auth_events (
  id          bigserial primary key,
  occurred_at timestamptz not null default now(),
  person_id   uuid references public.people(id),
  email       text,
  event       text not null,
  succeeded   boolean not null,
  ip_hash     text,
  user_agent  text
);
create index auth_events_time   on public.auth_events (occurred_at desc);
create index auth_events_person on public.auth_events (person_id, occurred_at desc);

alter table public.auth_events enable row level security;
alter table public.auth_events force  row level security;
grant select on public.auth_events to authenticated;

create policy auth_events_select_staff on public.auth_events
  for select to authenticated using ((select app.is_staff()));

comment on table public.auth_events is
  'Retention is indefinite by decision of 8 August 2026. Nothing deletes from '
  'here on a schedule. The privacy notice must say so, and an erasure request '
  'will need a person to decide what can go.';

-- -----------------------------------------------------------------------------
-- feature_usage
-- -----------------------------------------------------------------------------
-- Deliberately has NO member column. Council needs to know which features
-- members use. Nobody needs to watch what an individual member does, and
-- leaving the column out is a better guarantee than a policy saying nobody will look.
create table public.feature_usage (
  feature_key text not null,
  day         date not null,
  count       integer not null default 0,
  primary key (feature_key, day)
);

alter table public.feature_usage enable row level security;
alter table public.feature_usage force  row level security;
grant select on public.feature_usage to authenticated;

create policy usage_select_staff on public.feature_usage
  for select to authenticated using ((select app.is_staff()));

comment on table public.feature_usage is
  'Aggregate only. There is no member column and there must never be one.';

-- -----------------------------------------------------------------------------
-- restricted: staff working notes
-- -----------------------------------------------------------------------------
create table restricted.staff_notes (
  id         uuid primary key default gen_random_uuid(),
  subject    text not null,
  subject_id uuid not null,
  note       text not null,
  author_id  uuid references public.people(id),
  created_at timestamptz not null default now()
);

alter table restricted.staff_notes enable row level security;
alter table restricted.staff_notes force  row level security;
-- No grants and no policies. Reached only by a Worker holding the service role,
-- and the role cannot even see the schema.


-- =============================================================================
-- Why a few tables are enabled but NOT forced
-- =============================================================================
-- FORCE row level security makes the policies apply to the TABLE OWNER as well.
-- That is the only thing it does. Client keys are anon and authenticated, never
-- the owner, so forcing adds nothing against the threat this design is actually
-- built for. What it does affect is the schema's own machinery: a trigger
-- function is security definer, so it runs as the owner, and under FORCE it is
-- refused by the policies on the table it exists to maintain.
--
-- On a local Postgres this is invisible, because the owner is a superuser and
-- superusers escape FORCE. On a hosted Supabase project the migration role is
-- not a superuser, so it is not invisible at all: the first attempt to create a
-- member fails.
--
-- Eight tables are therefore enabled and not forced, and every one of them is
-- written by this schema rather than by a client:
--
--   audit_log             app.audit_row()
--   banned_words          app.find_banned_word()
--   cpd_year_summaries    app.refresh_cpd_summary()
--   forum_post_revisions  app.keep_post_revision()
--   forum_threads         app.forum_thread_counters()
--   wallet_passes         app.revoke_previous_pass()
--   role_grants           app.apply_bootstrap_super_user()
--   bootstrap_super_users app.apply_bootstrap_super_user()
--
-- Nothing is weakened for a client. The grants and the policies are unchanged,
-- anon still holds nothing, and a member still cannot read or write another
-- member's row. Tests 1 and 2 check exactly that: forced everywhere except this
-- named list, and no client write to any of them.
--
-- Everything else in the schema, including people, members, membership_years and
-- cpd_entries, remains forced, because nothing but a client or a service role
-- Worker writes to it.
