-- =============================================================================
-- 0007  Continuing professional development
--
-- Five core and five non core points a year, for the grades that require it.
-- Points arrive two ways in phase 1: the member logs their own, or AMI staff
-- award them. EVERY self logged entry is reviewed before it counts.
-- =============================================================================

create table public.cpd_requirements (
  id               uuid primary key default gen_random_uuid(),
  year             integer not null,
  grade_id         uuid not null references public.membership_grades(id),
  core_required    numeric(5,1) not null default 5 check (core_required >= 0),
  non_core_required numeric(5,1) not null default 5 check (non_core_required >= 0),
  created_at       timestamptz not null default now(),
  unique (year, grade_id)
);

comment on table public.cpd_requirements is
  'Associate has a row with zeroes rather than no row at all, so a report can '
  'say an Associate met the requirement instead of having nothing to say.';

create table public.cpd_activity_types (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  is_core    boolean not null,
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger cpd_activity_types_updated before update on public.cpd_activity_types
  for each row execute function app.set_updated_at();

comment on table public.cpd_activity_types is
  'Core means asbestos technical competence. Non core means the wider '
  'professional skills around it. A lookup table so the office can add one '
  'without a developer. Removing one is harder, because entries already logged '
  'against it have to go somewhere, so the list starts narrow.';

-- -----------------------------------------------------------------------------
-- cpd_entries
-- -----------------------------------------------------------------------------
create table public.cpd_entries (
  id               uuid primary key default gen_random_uuid(),
  member_id        uuid not null references public.members(id),
  year             integer not null,
  occurred_on      date not null,
  activity_type_id uuid not null references public.cpd_activity_types(id),
  title            text not null,
  provider         text,
  duration_minutes integer check (duration_minutes is null or duration_minutes > 0),
  points           numeric(4,1) not null check (points > 0),
  is_core          boolean not null,
  how_recorded     public.cpd_how_recorded not null default 'self_declared',
  status           public.cpd_entry_status not null default 'pending',
  evidence_ref     text,
  rule_id          uuid,
  source_id        uuid,
  recorded_by      uuid references public.people(id),
  recorded_at      timestamptz not null default now(),
  reviewed_by      uuid references public.people(id),
  reviewed_at      timestamptz,
  review_note      text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- An automatic award has to point at the rule that valued it and the source
  -- that evidenced it. Nothing writes automatic entries in phase 1, and this
  -- constraint is what stops the first one being written without either.
  constraint cpd_automatic_needs_rule_and_source
    check (how_recorded <> 'automatic' or (rule_id is not null and source_id is not null)),

  -- An accepted or rejected entry has to say who decided and when.
  constraint cpd_decision_is_attributed
    check (status = 'pending' or (reviewed_by is not null and reviewed_at is not null))
);

create index cpd_entries_member on public.cpd_entries (member_id, year);
create index cpd_entries_queue  on public.cpd_entries (status, recorded_at)
  where status = 'pending';

create trigger cpd_entries_updated before update on public.cpd_entries
  for each row execute function app.set_updated_at();
create trigger cpd_entries_audit
  after insert or update or delete on public.cpd_entries
  for each row execute function app.audit_row();

comment on column public.cpd_entries.how_recorded is
  'Stored, not derived. It appears on the members area screen, the CPD record '
  'and every export from day one. A scheme that cannot say where a line came '
  'from is a list of claims, and adding this column later means rewriting every '
  'row and every template. Only self_declared and awarded_by_ami are used in phase 1.';
comment on column public.cpd_entries.status is
  'Defaults to pending. NOTHING counts towards a member''s total until a member '
  'of staff accepts it. A rejected entry is visible to the member with the '
  'reason and appears nowhere else.';

create table public.cpd_evidence (
  id            uuid primary key default gen_random_uuid(),
  cpd_entry_id  uuid not null references public.cpd_entries(id) on delete cascade,
  storage_path  text not null,
  original_name text not null,
  byte_size     integer not null check (byte_size > 0),
  content_type  text not null,
  signature_ok  boolean not null default false,
  uploaded_at   timestamptz not null default now()
);
create index cpd_evidence_entry on public.cpd_evidence (cpd_entry_id);

create table public.cpd_adjustments (
  id           uuid primary key default gen_random_uuid(),
  cpd_entry_id uuid not null references public.cpd_entries(id),
  action       text not null,
  reason       text not null,
  actioned_by  uuid references public.people(id),
  actioned_at  timestamptz not null default now(),
  member_told_at timestamptz
);
create index cpd_adjustments_entry on public.cpd_adjustments (cpd_entry_id);

comment on table public.cpd_adjustments is
  'The design promises a member can always see why a point changed. That promise '
  'needs a table.';

-- -----------------------------------------------------------------------------
-- cpd_year_summaries
-- -----------------------------------------------------------------------------
-- So the dashboard, the record and the register do not each recompute the same
-- sum. Counts ACCEPTED entries only.
create table public.cpd_year_summaries (
  member_id       uuid not null references public.members(id) on delete cascade,
  year            integer not null,
  core_points     numeric(6,1) not null default 0,
  non_core_points numeric(6,1) not null default 0,
  entry_count     integer not null default 0,
  requirement_met boolean not null default false,
  updated_at      timestamptz not null default now(),
  primary key (member_id, year)
);

create or replace function app.refresh_cpd_summary(p_member_id uuid, p_year integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_core     numeric(6,1);
  v_non_core numeric(6,1);
  v_count    integer;
  v_grade    uuid;
  v_req_core numeric(5,1);
  v_req_non  numeric(5,1);
begin
  select coalesce(sum(points) filter (where is_core), 0),
         coalesce(sum(points) filter (where not is_core), 0),
         count(*)
    into v_core, v_non_core, v_count
    from public.cpd_entries
   where member_id = p_member_id and year = p_year and status = 'accepted';

  select grade_id into v_grade from public.members where id = p_member_id;

  select core_required, non_core_required into v_req_core, v_req_non
    from public.cpd_requirements
   where year = p_year and grade_id = v_grade;

  insert into public.cpd_year_summaries
    (member_id, year, core_points, non_core_points, entry_count, requirement_met, updated_at)
  values
    (p_member_id, p_year, v_core, v_non_core, v_count,
     coalesce(v_core >= v_req_core and v_non_core >= v_req_non, false), now())
  on conflict (member_id, year) do update set
    core_points     = excluded.core_points,
    non_core_points = excluded.non_core_points,
    entry_count     = excluded.entry_count,
    requirement_met = excluded.requirement_met,
    updated_at      = now();
end;
$$;

create or replace function app.cpd_summary_trigger() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    perform app.refresh_cpd_summary(new.member_id, new.year);
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    perform app.refresh_cpd_summary(old.member_id, old.year);
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create trigger cpd_entries_summary
  after insert or update or delete on public.cpd_entries
  for each row execute function app.cpd_summary_trigger();

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------
alter table public.cpd_requirements    enable row level security;
alter table public.cpd_requirements    force  row level security;
alter table public.cpd_activity_types  enable row level security;
alter table public.cpd_activity_types  force  row level security;
alter table public.cpd_entries         enable row level security;
alter table public.cpd_entries         force  row level security;
alter table public.cpd_evidence        enable row level security;
alter table public.cpd_evidence        force  row level security;
alter table public.cpd_adjustments     enable row level security;
alter table public.cpd_adjustments     force  row level security;
alter table public.cpd_year_summaries  enable row level security;
-- maintained by app.refresh_cpd_summary(), so enabled and not forced
alter table public.cpd_year_summaries  no force row level security;

grant select on public.cpd_requirements   to authenticated;
grant update on public.cpd_requirements   to authenticated;
grant select, insert, update on public.cpd_activity_types to authenticated;
grant select, insert, update, delete on public.cpd_entries to authenticated;
grant select, insert, delete on public.cpd_evidence to authenticated;
grant select, insert on public.cpd_adjustments to authenticated;
grant select on public.cpd_year_summaries to authenticated;

create policy cpd_req_select_all on public.cpd_requirements
  for select to authenticated using (true);
create policy cpd_req_update_staff on public.cpd_requirements
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

create policy cpd_types_select_all on public.cpd_activity_types
  for select to authenticated using (true);
create policy cpd_types_write_staff on public.cpd_activity_types
  for insert to authenticated with check ((select app.is_membership_staff()));
create policy cpd_types_update_staff on public.cpd_activity_types
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

-- A member reads their own entries, and inserts only a self declared, pending
-- one. If a member could write an automatic entry, or accept their own, the
-- whole argument for publishing a CPD figure collapses.
create policy cpd_select_own on public.cpd_entries
  for select to authenticated
  using (member_id = (select app.member_id()));

create policy cpd_insert_own on public.cpd_entries
  for insert to authenticated
  with check (
    member_id = (select app.member_id())
    and how_recorded = 'self_declared'
    and status = 'pending'
    and rule_id is null
    and source_id is null
    and reviewed_by is null
  );

-- Editable only while it is still a draft. Once staff have accepted it, it is a
-- record rather than a draft.
create policy cpd_update_own_pending on public.cpd_entries
  for update to authenticated
  using (member_id = (select app.member_id()) and status = 'pending')
  with check (
    member_id = (select app.member_id())
    and status = 'pending'
    and how_recorded = 'self_declared'
  );

create policy cpd_delete_own_pending on public.cpd_entries
  for delete to authenticated
  using (member_id = (select app.member_id()) and status = 'pending');

create policy cpd_select_staff on public.cpd_entries
  for select to authenticated using ((select app.is_staff()));
create policy cpd_insert_staff on public.cpd_entries
  for insert to authenticated with check ((select app.is_membership_staff()));
create policy cpd_update_staff on public.cpd_entries
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

create policy cpd_ev_select_own on public.cpd_evidence
  for select to authenticated
  using (exists (select 1 from public.cpd_entries e
                 where e.id = cpd_entry_id and e.member_id = (select app.member_id())));
create policy cpd_ev_insert_own on public.cpd_evidence
  for insert to authenticated
  with check (exists (select 1 from public.cpd_entries e
                      where e.id = cpd_entry_id
                        and e.member_id = (select app.member_id())
                        and e.status = 'pending'));
create policy cpd_ev_delete_own on public.cpd_evidence
  for delete to authenticated
  using (exists (select 1 from public.cpd_entries e
                 where e.id = cpd_entry_id
                   and e.member_id = (select app.member_id())
                   and e.status = 'pending'));
create policy cpd_ev_select_staff on public.cpd_evidence
  for select to authenticated using ((select app.is_staff()));

create policy cpd_adj_select_own on public.cpd_adjustments
  for select to authenticated
  using (exists (select 1 from public.cpd_entries e
                 where e.id = cpd_entry_id and e.member_id = (select app.member_id())));
create policy cpd_adj_select_staff on public.cpd_adjustments
  for select to authenticated using ((select app.is_staff()));
create policy cpd_adj_insert_staff on public.cpd_adjustments
  for insert to authenticated with check ((select app.is_membership_staff()));

create policy cpd_sum_select_own on public.cpd_year_summaries
  for select to authenticated
  using (member_id = (select app.member_id()));
create policy cpd_sum_select_staff on public.cpd_year_summaries
  for select to authenticated using ((select app.is_staff()));
