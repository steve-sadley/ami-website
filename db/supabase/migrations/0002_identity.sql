-- =============================================================================
-- 0002  Identity, membership and roles
--
-- These tables come before the helper functions in 0003, because the helpers
-- read them. Their policies are therefore in 0004 rather than here. Every other
-- migration carries its own policies alongside its tables.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- people
-- -----------------------------------------------------------------------------
-- One row per authenticated human. The id IS the Supabase auth user id, so there
-- is no second identity to keep in step. No password, no token, no card detail.
create table public.people (
  id                uuid primary key references auth.users(id) on delete cascade,
  given_name        text not null,
  family_name       text not null,
  post_nominals     text,
  email             text not null,
  mobile            text,
  home_address      jsonb,
  business_address  jsonb,
  photo_path        text,
  photo_consent     boolean not null default false,
  photo_consent_at  timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint people_photo_consent_dated
    check (photo_consent = false or photo_consent_at is not null)
);

create unique index people_email_lower_key on public.people (lower(email));
create trigger people_updated before update on public.people
  for each row execute function app.set_updated_at();

comment on table public.people is
  'One row per authenticated human. A person is not the same thing as a '
  'membership: somebody can apply and be refused, and a member can lapse and rejoin.';
comment on column public.people.photo_consent is
  'Consent for the photograph, held beside the photograph rather than on the '
  'membership row, so a person can never hold an unconsented image because their '
  'membership does not exist yet. Whether it appears on the PUBLIC verification '
  'page is a separate switch on member_preferences.';

-- -----------------------------------------------------------------------------
-- organisations
-- -----------------------------------------------------------------------------
-- A reference list in phase 1, so the register shows one spelling of a firm
-- rather than fourteen. No company accounts and no company sign in yet.
create table public.organisations (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null,
  companies_house_number text,
  address                jsonb,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create unique index organisations_name_lower_key on public.organisations (lower(name));
create trigger organisations_updated before update on public.organisations
  for each row execute function app.set_updated_at();

-- Same never reuse rule as register_slugs, so company pages can be added later
-- without an old link resolving to a different company.
create table public.organisation_slugs (
  slug            text primary key,
  organisation_id uuid not null references public.organisations(id),
  created_at      timestamptz not null default now(),
  retired_at      timestamptz
);
create index organisation_slugs_org on public.organisation_slugs (organisation_id);

-- -----------------------------------------------------------------------------
-- membership_grades
-- -----------------------------------------------------------------------------
create table public.membership_grades (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique,
  name                text not null,
  post_nominals       text,
  is_assessed         boolean not null default true,
  appears_on_register boolean not null default true,
  requires_cpd        boolean not null default true,
  sort_order          integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger membership_grades_updated before update on public.membership_grades
  for each row execute function app.set_updated_at();

comment on column public.membership_grades.is_assessed is
  'Whether the grade was awarded against assessed evidence. Every template that '
  'renders a grade reads THIS FLAG rather than testing the grade name, so that '
  'assessed and unassessed stay distinguishable at a glance when the CPD grade '
  'is introduced. That rule is what protects every claim on an assurance statement.';
comment on column public.membership_grades.requires_cpd is
  'Member and Fellow true, Associate false. Held as data rather than written '
  'into the code, so a change of policy is a change of data.';

-- -----------------------------------------------------------------------------
-- members
-- -----------------------------------------------------------------------------
create table public.members (
  id                  uuid primary key default gen_random_uuid(),
  person_id           uuid not null unique references public.people(id),
  membership_number   text not null unique,
  grade_id            uuid not null references public.membership_grades(id),
  employer_id         uuid references public.organisations(id),
  current_job_title   text,
  joined_on           date not null,
  is_active           boolean not null default false,
  status              public.member_status not null default 'applicant',
  activated_at        timestamptz,
  activated_by        uuid references public.people(id),
  deactivated_at      timestamptz,
  deactivated_by      uuid references public.people(id),
  deactivation_reason text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index members_person on public.members (person_id);
create index members_active on public.members (is_active) where is_active;
create index members_grade  on public.members (grade_id);
create trigger members_updated before update on public.members
  for each row execute function app.set_updated_at();

comment on column public.members.is_active is
  'The switch a member of staff presses. NOTHING in the system sets this except '
  'a person: there is no grace period job, no automatic lapse and no calculation '
  'anywhere that decides whether somebody is current. The register, the profile '
  'page and the membership card all read this one column.';
comment on column public.members.status is
  'Descriptive, and records WHY a membership is inactive. is_active is what '
  'everything actually reads.';
comment on column public.members.membership_number is
  'Unique, and never reissued to a different person.';

-- -----------------------------------------------------------------------------
-- membership_years
-- -----------------------------------------------------------------------------
-- The site takes no payments. This is a record written by office staff of what
-- was charged and what was received, kept so a question about 2024 can be
-- answered in 2027. If online payment is ever added it fills in the same row.
create table public.membership_years (
  id            uuid primary key default gen_random_uuid(),
  member_id     uuid not null references public.members(id),
  year          integer not null,
  fee_pence     integer check (fee_pence is null or fee_pence >= 0),
  invoiced_on   date,
  paid_on       date,
  payment_note  text,
  recorded_by   uuid references public.people(id),
  recorded_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (member_id, year)
);
create index membership_years_member on public.membership_years (member_id, year desc);
create trigger membership_years_updated before update on public.membership_years
  for each row execute function app.set_updated_at();

-- -----------------------------------------------------------------------------
-- member_preferences
-- -----------------------------------------------------------------------------
create table public.member_preferences (
  member_id            uuid primary key references public.members(id) on delete cascade,
  list_on_register     boolean not null default true,
  public_profile       boolean not null default true,
  photo_on_public_page boolean not null default false,
  forum_notifications  text not null default 'daily'
    check (forum_notifications in ('off', 'immediate', 'daily', 'weekly')),
  email_newsletter     boolean not null default true,
  email_events         boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create trigger member_preferences_updated before update on public.member_preferences
  for each row execute function app.set_updated_at();

comment on column public.member_preferences.photo_on_public_page is
  'OFF until the member turns it on. The photograph shows on the CARD by default, '
  'because that is why they uploaded it, but a card shown to one person at a site '
  'gate is not the same as a picture on the open web, so the two are separate '
  'choices made at the same moment.';
comment on table public.member_preferences is
  'Membership notices are not preferences. Switching off the newsletter must '
  'never switch off a notice about somebody''s own membership.';

-- -----------------------------------------------------------------------------
-- register_slugs
-- -----------------------------------------------------------------------------
-- Never reused and never deleted. A link in an email signature outlives the
-- membership behind it, and a reused slug would eventually point at a different
-- person with the same name.
create table public.register_slugs (
  slug       text primary key,
  member_id  uuid not null references public.members(id),
  created_at timestamptz not null default now(),
  retired_at timestamptz
);
create index register_slugs_member on public.register_slugs (member_id);

-- -----------------------------------------------------------------------------
-- Roles
-- -----------------------------------------------------------------------------
create table public.app_roles (
  code        text primary key,
  name        text not null,
  description text,
  sort_order  integer not null default 0
);

create table public.role_grants (
  id          uuid primary key default gen_random_uuid(),
  person_id   uuid not null references public.people(id) on delete cascade,
  role_code   text not null references public.app_roles(code),
  granted_by  uuid references public.people(id),
  granted_at  timestamptz not null default now(),
  unique (person_id, role_code)
);
create index role_grants_person on public.role_grants (person_id);

comment on table public.role_grants is
  'Granted and removed by a super user from an admin screen, never by editing the '
  'database, because a change made that way leaves no trace. Every grant and '
  'removal is written to the audit log with both people named.';

-- A super user cannot remove their own super user role. Without this, one
-- mistaken click leaves the organisation with no way to grant roles at all.
create or replace function app.protect_super_user() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role_code = 'super_user' and old.person_id = auth.uid() then
    raise exception 'A super user cannot remove their own super user role.'
      using errcode = '42501';
  end if;
  return old;
end;
$$;

create trigger role_grants_protect_self
  before delete on public.role_grants
  for each row execute function app.protect_super_user();
