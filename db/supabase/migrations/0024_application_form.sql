-- =============================================================================
-- 0024  The application form AMI actually uses
--
-- The form on the site asked for a name, an address, an employer and a couple of
-- paragraphs. The real AMI application form asks for a good deal more, and the
-- new site has to mirror it or the office ends up chasing every applicant for
-- the same four things.
--
-- What it adds, in the order the form asks for it:
--
--   Your details        date of birth, private address
--   Employment          date appointed  (employer and position already existed)
--   Documents           a CV, training certificates, qualification certificates
--                       and CSCS cards. The table for these has existed since
--                       0006 and nothing has ever written to it.
--   Invoice             a name and an address, which are often not the
--                       applicant's own: the employer usually pays.
--   Signature           drawn or typed, with the name and the date beside it.
--
-- THE GRADE IS NOT ASKED FOR, AND THAT IS DELIBERATE.
--
-- The paper form does not ask, because the applicant is not the one who decides.
-- The office assesses the application and confirms the grade, and then invoices
-- for that grade. Asking sets up an expectation the assessment then has to
-- disappoint. The column stays, because the office sets it on approval.
--
-- HOW AN ANONYMOUS APPLICANT UPLOADS A FILE
--
-- They do not, not directly. application-documents is private and its policies
-- are keyed to a person id, so somebody with no account cannot write to it and
-- should not be able to. The form posts everything, files included, to the
-- Worker, which holds the secret key, checks the sizes and the types, stores the
-- files under the application's own id, and records them. The browser still
-- holds nothing that can write.
-- =============================================================================

alter table public.membership_applications
  add column if not exists date_of_birth    date,
  add column if not exists private_address  text,
  add column if not exists date_appointed   date,
  add column if not exists invoice_name     text,
  add column if not exists invoice_address  text,
  add column if not exists signature_path   text,
  add column if not exists signed_name      text,
  add column if not exists signed_on        date;

comment on column public.membership_applications.private_address is
  'The applicant''s own address, which is what the Rules of Membership ask for. '
  'The invoice address is separate and is usually the employer.';
comment on column public.membership_applications.signature_path is
  'The signature image in the application-documents bucket. Drawn or typed, and '
  'either way it is a picture, so what was signed is what is kept.';

-- The four kinds of document the form accepts. Written down here rather than
-- left to whatever string the page happens to send, so a report can group by it
-- and the office can see at a glance what is missing.
alter table public.application_documents
  drop constraint if exists application_documents_kind_check;
alter table public.application_documents
  add constraint application_documents_kind_check
  check (kind in ('cv', 'training', 'qualification', 'cscs', 'signature', 'other'));

-- -----------------------------------------------------------------------------
-- Submitting
-- -----------------------------------------------------------------------------
drop function if exists public.submit_application(text,text,text,text,text,text,text,jsonb);

create or replace function public.submit_application(
  p_given_name      text,
  p_family_name     text,
  p_email           text,
  p_telephone       text default null,
  p_date_of_birth   date default null,
  p_private_address text default null,
  p_employer_name   text default null,
  p_job_title       text default null,
  p_date_appointed  date default null,
  p_invoice_name    text default null,
  p_invoice_address text default null,
  p_signed_name     text default null,
  p_signed_on       date default null,
  p_answers         jsonb default '{}'::jsonb
) returns table (id uuid, reference text)
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_ref  text;
  v_id   uuid;
  v_year text := to_char(now(), 'YYYY');
begin
  if coalesce(btrim(p_given_name), '') = '' or coalesce(btrim(p_family_name), '') = '' then
    raise exception 'A name is needed.' using errcode = '22023';
  end if;
  if p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'That does not look like an email address.' using errcode = '22023';
  end if;

  -- Somebody born in the future, or in 1890, has mistyped it, and a date of
  -- birth nobody checks is a date of birth nobody can rely on.
  if p_date_of_birth is not null
     and (p_date_of_birth > current_date - interval '16 years'
          or p_date_of_birth < current_date - interval '100 years') then
    raise exception 'Please check the date of birth.' using errcode = '22023';
  end if;

  if exists (select 1 from public.membership_applications a
              where lower(a.email) = lower(btrim(p_email))
                and a.status in ('draft','submitted','under_review')) then
    raise exception 'There is already an application in progress for that address. '
                    'The office will be in touch, and they can be reached in the meantime.'
      using errcode = '23505';
  end if;

  -- AMI-2026-0001, counted per year so the number says something. Serialised by
  -- the unique constraint: two arriving together means one retries, which is the
  -- whole reason this is not a counter held by the caller.
  select 'AMI-' || v_year || '-' ||
         lpad((coalesce(max(substring(a.reference from 10)::int), 0) + 1)::text, 4, '0')
    into v_ref
    from public.membership_applications a
   where a.reference like 'AMI-' || v_year || '-%';

  insert into public.membership_applications
    (reference, given_name, family_name, email, telephone, date_of_birth,
     private_address, employer_name, job_title, date_appointed,
     invoice_name, invoice_address, signed_name, signed_on,
     answers, status, submitted_at)
  values
    (v_ref, btrim(p_given_name), btrim(p_family_name), lower(btrim(p_email)),
     nullif(btrim(coalesce(p_telephone,'')), ''), p_date_of_birth,
     nullif(btrim(coalesce(p_private_address,'')), ''),
     nullif(btrim(coalesce(p_employer_name,'')), ''),
     nullif(btrim(coalesce(p_job_title,'')), ''), p_date_appointed,
     nullif(btrim(coalesce(p_invoice_name,'')), ''),
     nullif(btrim(coalesce(p_invoice_address,'')), ''),
     nullif(btrim(coalesce(p_signed_name,'')), ''), coalesce(p_signed_on, current_date),
     coalesce(p_answers, '{}'::jsonb), 'submitted', now())
  returning membership_applications.id into v_id;

  insert into public.application_events (application_id, from_status, to_status, note)
  values (v_id, 'draft', 'submitted', 'Submitted through the website.');

  return query select v_id, v_ref;
end;
$$;

revoke all on function public.submit_application(
  text,text,text,text,date,text,text,text,date,text,text,text,date,jsonb) from public;
grant execute on function public.submit_application(
  text,text,text,text,date,text,text,text,date,text,text,text,date,jsonb) to service_role;

comment on function public.submit_application(
  text,text,text,text,date,text,text,text,date,text,text,text,date,jsonb) is
  'Creates a submitted application from the public form. Granted to the service '
  'role only: the form posts to a Worker and the browser holds nothing that can '
  'write. No grade is taken, because the applicant does not choose it.';

-- -----------------------------------------------------------------------------
-- Recording an uploaded file
-- -----------------------------------------------------------------------------
-- The Worker has already put the file in the bucket by the time it calls this.
-- Keeping it as a function rather than a direct insert means the size and the
-- kind are checked in one place, and the application has to be one that is still
-- open, so a reference somebody kept from last year cannot be used to attach
-- files to a decided application.
create or replace function public.record_application_document(
  p_application_id uuid,
  p_kind           text,
  p_storage_path   text,
  p_original_name  text,
  p_byte_size      integer,
  p_content_type   text
) returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not exists (select 1 from public.membership_applications
                  where id = p_application_id
                    and status in ('draft','submitted','under_review')) then
    raise exception 'That application is not open.' using errcode = '42501';
  end if;
  if p_byte_size <= 0 or p_byte_size > 20971520 then
    raise exception 'A file has to be between one byte and twenty megabytes.' using errcode = '22023';
  end if;

  insert into public.application_documents
    (application_id, kind, storage_path, original_name, byte_size, content_type)
  values (p_application_id, p_kind, p_storage_path,
          left(p_original_name, 200), p_byte_size, p_content_type)
  returning id into v_id;

  -- The signature is the one document that is also a field on the application,
  -- because the office wants to see it beside the name rather than in a list.
  if p_kind = 'signature' then
    update public.membership_applications
       set signature_path = p_storage_path where id = p_application_id;
  end if;

  return v_id;
end;
$$;

revoke all on function public.record_application_document(uuid,text,text,text,integer,text) from public;
grant execute on function public.record_application_document(uuid,text,text,text,integer,text)
  to service_role;

-- -----------------------------------------------------------------------------
-- What the office sees
-- -----------------------------------------------------------------------------
drop view if exists public.admin_application_queue;
create view public.admin_application_queue
with (security_invoker = true) as
  select a.id, a.reference, a.status,
         a.given_name, a.family_name, a.email, a.telephone,
         a.date_of_birth, a.private_address,
         a.employer_name, a.job_title, a.date_appointed,
         a.invoice_name, a.invoice_address,
         a.signed_name, a.signed_on, a.signature_path,
         g.name as grade, a.grade_id,
         a.submitted_at, a.created_at, a.decided_at, a.decision_note,
         (select count(*) from public.application_documents d where d.application_id = a.id) as documents
    from public.membership_applications a
    left join public.membership_grades g on g.id = a.grade_id;

grant select on public.admin_application_queue to authenticated;

-- The documents themselves, so the office can open them from the queue. Staff
-- only, by the policy already on the table, and the file itself still needs a
-- signed link, which the admin asks for when somebody clicks.
create or replace view public.admin_application_documents
with (security_invoker = true) as
  select d.id, d.application_id, d.kind, d.storage_path, d.original_name,
         d.byte_size, d.content_type, d.uploaded_at
    from public.application_documents d;

grant select on public.admin_application_documents to authenticated;
