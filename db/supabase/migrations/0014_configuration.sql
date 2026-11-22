-- =============================================================================
-- 0014  Configuration
--
-- The fee for each grade, and a general settings table for anything else that
-- would otherwise get written into code.
--
-- Nothing in here is seeded. Every value is set from the backend.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- grade_fees
-- -----------------------------------------------------------------------------
-- The fee for a grade in a given year. Set from the backend, and history is kept
-- rather than overwritten, so a question about what 2026 cost is still
-- answerable in 2029.
--
-- The site takes no payments. This is the figure the office invoices against and
-- the default that appears when a membership year is recorded.
create table public.grade_fees (
  id          uuid primary key default gen_random_uuid(),
  grade_id    uuid not null references public.membership_grades(id),
  year        integer not null,
  fee_pence   integer not null check (fee_pence >= 0),
  vat_note    text,
  set_by      uuid references public.people(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (grade_id, year)
);
create trigger grade_fees_updated before update on public.grade_fees
  for each row execute function app.set_updated_at();
create trigger grade_fees_audit
  after insert or update or delete on public.grade_fees
  for each row execute function app.audit_row();

comment on column public.grade_fees.vat_note is
  'Free text. The VAT treatment does not need answering while the site raises no '
  'invoice, and this is where the answer goes when it does.';

-- When a membership year is created without a fee, take the one set for that
-- grade and year. It remains editable, because a member is occasionally charged
-- something other than the standard fee and the record has to be able to say so.
create or replace function app.default_membership_fee() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.fee_pence is null then
    select f.fee_pence into new.fee_pence
      from public.grade_fees f
      join public.members m on m.grade_id = f.grade_id
     where m.id = new.member_id and f.year = new.year;
  end if;
  return new;
end;
$$;

create trigger membership_years_default_fee
  before insert on public.membership_years
  for each row execute function app.default_membership_fee();

-- -----------------------------------------------------------------------------
-- admin_settings
-- -----------------------------------------------------------------------------
-- Anything that would otherwise become a number written into the code. Held as
-- a key and a JSON value so a setting can be a figure, a flag or a list without
-- a migration each time.
create table public.admin_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_by  uuid references public.people(id),
  updated_at  timestamptz not null default now()
);
create trigger admin_settings_updated before update on public.admin_settings
  for each row execute function app.set_updated_at();
create trigger admin_settings_audit
  after insert or update or delete on public.admin_settings
  for each row execute function app.audit_row();

comment on table public.admin_settings is
  'For values that would otherwise be written into code. Nothing is seeded here. '
  'A setting only exists once somebody sets it, and the code that reads one must '
  'therefore carry its own fallback and cope with the key being absent.';

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------
alter table public.grade_fees     enable row level security;
alter table public.grade_fees     force  row level security;
alter table public.admin_settings enable row level security;
alter table public.admin_settings force  row level security;

grant select, insert, update, delete on public.grade_fees to authenticated;
grant select, insert, update, delete on public.admin_settings to authenticated;

-- A member can see the fee for their own grade. Publishing the fee list is
-- normal for a membership body and it saves an email to the office.
create policy fees_select_all on public.grade_fees
  for select to authenticated using (true);
create policy fees_insert_staff on public.grade_fees
  for insert to authenticated with check ((select app.is_membership_staff()));
create policy fees_update_staff on public.grade_fees
  for update to authenticated
  using ((select app.is_membership_staff())) with check ((select app.is_membership_staff()));
create policy fees_delete_super on public.grade_fees
  for delete to authenticated using ((select app.is_super_user()));

create policy settings_select_staff on public.admin_settings
  for select to authenticated using ((select app.is_staff()));
create policy settings_insert_super on public.admin_settings
  for insert to authenticated with check ((select app.is_super_user()));
create policy settings_update_super on public.admin_settings
  for update to authenticated
  using ((select app.is_super_user())) with check ((select app.is_super_user()));
create policy settings_delete_super on public.admin_settings
  for delete to authenticated using ((select app.is_super_user()));

-- -----------------------------------------------------------------------------
-- What the backend has to be able to edit
-- -----------------------------------------------------------------------------
-- Recorded here so the admin screens are built against a list rather than
-- discovered one missing screen at a time. Every one of these is data, and none
-- of it is seeded by a migration.
--
--   membership_grades     name, post nominals, assessed, on register, requires CPD
--   grade_fees            the fee for each grade and year
--   cpd_requirements      core and non core points, per year and per grade
--   cpd_activity_types    what a member chooses from, and the core split
--   forum_categories      name, description, order, members only, locked
--   banned_words          the word, and whether it matches whole word or anywhere
--   hero_statements       the rotating headline on the home page
--   role_grants           who holds which role
--   bootstrap_super_users the way back in
--   admin_settings        anything else
