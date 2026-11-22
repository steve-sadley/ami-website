-- =============================================================================
-- 0006  The membership application
--
-- The form is online. Everything after submission is a person's job. No payment
-- link is sent and no fee is taken: the office invoices in the usual way and
-- records the result against the membership year when it arrives.
-- =============================================================================

create table public.membership_applications (
  id             uuid primary key default gen_random_uuid(),
  reference      text not null unique,
  grade_id       uuid references public.membership_grades(id),
  given_name     text not null,
  family_name    text not null,
  email          text not null,
  telephone      text,
  employer_name  text,
  employer_id    uuid references public.organisations(id),
  job_title      text,
  answers        jsonb not null default '{}'::jsonb,
  status         public.application_status not null default 'draft',
  submitted_at   timestamptz,
  decided_at     timestamptz,
  decided_by     uuid references public.people(id),
  decision_note  text,
  member_id      uuid references public.members(id),
  person_id      uuid references public.people(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index applications_status on public.membership_applications (status, submitted_at);
create unique index applications_email_open
  on public.membership_applications (lower(email))
  where status in ('draft', 'submitted', 'under_review');
create trigger applications_updated before update on public.membership_applications
  for each row execute function app.set_updated_at();

comment on index public.applications_email_open is
  'One open application per email address. A refused or withdrawn application '
  'does not block a later one, which is deliberate: people reapply.';

create table public.application_documents (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.membership_applications(id) on delete cascade,
  kind           text not null,
  storage_path   text not null,
  original_name  text not null,
  byte_size      integer not null check (byte_size > 0),
  content_type   text not null,
  signature_ok   boolean not null default false,
  uploaded_at    timestamptz not null default now()
);
create index application_documents_app on public.application_documents (application_id);

comment on column public.application_documents.signature_ok is
  'Set by the Worker after reading the file signature. The extension is never '
  'trusted, and a file that fails this check is not stored.';
comment on column public.application_documents.original_name is
  'Kept as data. The stored path uses a generated name, so an uploaded filename '
  'can never influence where a file lands.';

-- Save and return by magic link. Stored hashed, single use, time limited, and
-- readable by NOBODY through the database. A Worker holding the service role
-- compares the hash and never returns the row.
create table public.application_tokens (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.membership_applications(id) on delete cascade,
  token_hash     text not null unique,
  expires_at     timestamptz not null,
  used_at        timestamptz,
  created_at     timestamptz not null default now()
);
create index application_tokens_app on public.application_tokens (application_id);

create table public.application_events (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.membership_applications(id) on delete cascade,
  from_status    public.application_status,
  to_status      public.application_status not null,
  actor_id       uuid references public.people(id),
  note           text,
  occurred_at    timestamptz not null default now()
);
create index application_events_app on public.application_events (application_id, occurred_at);

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------
alter table public.membership_applications enable row level security;
alter table public.membership_applications force  row level security;
alter table public.application_documents   enable row level security;
alter table public.application_documents   force  row level security;
alter table public.application_tokens      enable row level security;
alter table public.application_tokens      force  row level security;
alter table public.application_events      enable row level security;
alter table public.application_events      force  row level security;

grant select, update on public.membership_applications to authenticated;
grant select, insert, delete on public.application_documents to authenticated;
grant select, insert on public.application_events to authenticated;
-- application_tokens: no grant to anyone. Not even select.

-- An applicant who has since become a member can see their own application.
-- Everybody else reaches it through a Worker holding the token.
create policy applications_select_own on public.membership_applications
  for select to authenticated
  using (person_id = (select app.person_id()));

create policy applications_select_staff on public.membership_applications
  for select to authenticated
  using ((select app.is_staff()));

create policy applications_update_staff on public.membership_applications
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

create policy app_docs_select_own on public.application_documents
  for select to authenticated
  using (exists (select 1 from public.membership_applications a
                 where a.id = application_id and a.person_id = (select app.person_id())));

create policy app_docs_select_staff on public.application_documents
  for select to authenticated
  using ((select app.is_staff()));

create policy app_docs_insert_own on public.application_documents
  for insert to authenticated
  with check (exists (select 1 from public.membership_applications a
                      where a.id = application_id
                        and a.person_id = (select app.person_id())
                        and a.status = 'draft'));

create policy app_docs_delete_own_draft on public.application_documents
  for delete to authenticated
  using (exists (select 1 from public.membership_applications a
                 where a.id = application_id
                   and a.person_id = (select app.person_id())
                   and a.status = 'draft'));

create policy app_events_select_own on public.application_events
  for select to authenticated
  using (exists (select 1 from public.membership_applications a
                 where a.id = application_id and a.person_id = (select app.person_id())));

create policy app_events_select_staff on public.application_events
  for select to authenticated
  using ((select app.is_staff()));

create policy app_events_insert_staff on public.application_events
  for insert to authenticated
  with check ((select app.is_membership_staff()));

create trigger applications_audit
  after insert or update or delete on public.membership_applications
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Approval carries the data across
-- -----------------------------------------------------------------------------
-- The decision stays entirely manual. Only the typing is removed: approving
-- creates the people and members rows from what the applicant already typed,
-- so nobody rekeys 20 fields and there is no chance of a transcription error.
--
-- The new member is created INACTIVE. Somebody still has to press the switch,
-- which is the point of the switch.
create or replace function app.approve_application(
  p_application_id   uuid,
  p_auth_user_id     uuid,
  p_membership_number text,
  p_joined_on        date default current_date,
  p_note             text default null
) returns uuid
language plpgsql
-- SECURITY INVOKER on purpose. It runs as the member of staff who called it, so
-- every row it writes is written under their own policies and appears in the
-- audit log under their name. A function that escalates to the table owner would
-- work too, and would quietly become a way round the policies it sits behind.
set search_path = ''
as $$
declare
  a public.membership_applications%rowtype;
  v_person_id uuid;
  v_member_id uuid;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may approve an application.'
      using errcode = '42501';
  end if;

  select * into a from public.membership_applications where id = p_application_id;
  if not found then
    raise exception 'Application % not found.', p_application_id;
  end if;
  if a.status not in ('submitted', 'under_review') then
    raise exception 'Application % is %, so it cannot be approved.', a.reference, a.status;
  end if;

  insert into public.people (id, given_name, family_name, email, mobile)
  values (p_auth_user_id, a.given_name, a.family_name, a.email, a.telephone)
  on conflict (id) do update set
    given_name = excluded.given_name,
    family_name = excluded.family_name
  returning id into v_person_id;

  insert into public.members
    (person_id, membership_number, grade_id, employer_id, current_job_title,
     joined_on, is_active, status)
  values
    (v_person_id, p_membership_number, a.grade_id, a.employer_id, a.job_title,
     p_joined_on, false, 'applicant')
  returning id into v_member_id;

  insert into public.member_preferences (member_id) values (v_member_id);

  update public.membership_applications
     set status = 'approved', decided_at = now(), decided_by = auth.uid(),
         decision_note = p_note, member_id = v_member_id, person_id = v_person_id
   where id = p_application_id;

  insert into public.application_events (application_id, from_status, to_status, actor_id, note)
  values (p_application_id, a.status, 'approved', auth.uid(), p_note);

  return v_member_id;
end;
$$;

revoke all on function app.approve_application(uuid, uuid, text, date, text) from public;
grant execute on function app.approve_application(uuid, uuid, text, date, text)
  to authenticated, service_role;

comment on function app.approve_application(uuid, uuid, text, date, text) is
  'Creates the person and member rows from an approved application. The member '
  'is created INACTIVE: a person still has to press the switch.';
