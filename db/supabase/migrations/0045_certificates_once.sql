-- =============================================================================
-- 0045  A certificate counts once
--
-- Steve, 31 October 2026: a certificate is uploaded once; uploaded a second
-- time it is declined. And Claude reads every certificate now, not later.
--
-- THREE CHECKS, from the hardest to the softest:
--
--   1. THE SAME FILE IS REFUSED AT UPLOAD. Evidence now goes through the
--      site's Worker, which reads the bytes, checks they are really a PDF or a
--      picture, and takes their SHA-256. A file whose SHA-256 is already on
--      any CPD entry that was not rejected, anybody's, is refused with a
--      message, and nothing is stored. Members can no longer write to the
--      evidence bucket or the evidence table directly: the two policies that
--      let them are dropped, so the Worker is the only way in.
--
--   2. CLAUDE READS THE CERTIFICATE. On Ask Claude, each certificate on a
--      pending entry is read for the holder's name, the course, who issued
--      it, when, and its number. Claude is sent the file and the activity,
--      title, provider and date, and NOT the member's name: the comparison
--      with the member's name is done here, in the database. A certificate
--      number already on another entry, a holder who is not the member, or a
--      date far from the entry's are shown on the card for the office, who
--      decline it. Claude decides nothing, as in 0043.
--
--   3. A LIKELY REPEAT IS FLAGGED. A second entry by the same member for the
--      same activity on the same date, or with the same title, says so on the
--      card. A new scan of the same certificate has a different SHA-256; this
--      and the certificate number are what catch it.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Evidence carries its fingerprint
-- -----------------------------------------------------------------------------
alter table public.cpd_evidence add column if not exists sha256 text
  check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$');
alter table public.cpd_evidence add column if not exists ai_requested_by uuid references public.people(id);
alter table public.cpd_evidence add column if not exists ai_requested_at timestamptz;
create index if not exists cpd_evidence_sha256 on public.cpd_evidence (sha256) where sha256 is not null;

comment on column public.cpd_evidence.sha256 is
  'SHA-256 of the file, taken by the Worker from the bytes it stored. Identical '
  'files have identical values, so a certificate used once cannot be used again.';

-- Members no longer write evidence themselves. Reading and deleting their own
-- on a pending entry stay as they were.
drop policy if exists cpd_ev_insert_own on public.cpd_evidence;
drop policy if exists cpdev_insert_own on storage.objects;

-- An upload in progress: asked for by the member, finished by the Worker.
create table if not exists public.cpd_evidence_uploads (
  id            uuid primary key default gen_random_uuid(),
  entry_id      uuid not null references public.cpd_entries(id) on delete cascade,
  person_id     uuid not null references public.people(id),
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path  text not null,
  original_name text not null,
  content_type  text not null,
  byte_size     integer not null check (byte_size > 0 and byte_size <= 20971520),
  created_at    timestamptz not null default now()
);
alter table public.cpd_evidence_uploads enable row level security;
revoke all on public.cpd_evidence_uploads from anon, authenticated;

-- Used by an entry that counts: not rejected. A certificate on an entry the
-- office rejected for another reason (the wrong activity, say) may be used
-- again on a corrected one.
create or replace function app.cpd_sha256_used(p_sha256 text) returns uuid
language sql stable security definer set search_path = ''
as $$
  select v.cpd_entry_id from public.cpd_evidence v
    join public.cpd_entries e on e.id = v.cpd_entry_id
   where v.sha256 = p_sha256 and e.status <> 'rejected'
   limit 1;
$$;
revoke all on function app.cpd_sha256_used(text) from public;

-- A courtesy for the form: has this file been used? Asked BEFORE the entries
-- are logged, so a member is told before sending rather than after. Not the
-- rule: the rule is in cpd_evidence_record, on the bytes the Worker read.
create or replace function public.cpd_evidence_seen(p_sha256 text) returns boolean
language sql stable security definer set search_path = ''
as $$ select app.member_id() is not null and app.cpd_sha256_used(lower(p_sha256)) is not null; $$;
revoke all on function public.cpd_evidence_seen(text) from public;
grant execute on function public.cpd_evidence_seen(text) to authenticated;

-- As the member: may I attach this file to this entry? Returns where to put it.
create or replace function public.cpd_evidence_begin(
  p_entry uuid, p_sha256 text, p_name text, p_type text, p_size integer)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_person uuid := app.person_id();
  v_member uuid := app.member_id();
  e        public.cpd_entries;
  v_ext    text;
  v_path   text;
  v_id     uuid;
begin
  if v_member is null then
    raise exception 'There is no AMI membership for this account.' using errcode = '42501';
  end if;
  select * into e from public.cpd_entries where id = p_entry;
  if e.id is null or e.member_id <> v_member then
    raise exception 'That is not one of your entries.' using errcode = '42501';
  end if;
  if e.status <> 'pending' then
    raise exception 'Evidence can only be added while an entry is waiting for review.' using errcode = '22023';
  end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' then
    raise exception 'The file could not be read.' using errcode = '22023';
  end if;
  if app.cpd_sha256_used(lower(p_sha256)) is not null then
    raise exception 'This certificate has already been used for CPD. A certificate counts once.'
      using errcode = '23505';
  end if;
  v_ext := case p_type when 'application/pdf' then '.pdf' when 'image/jpeg' then '.jpg'
                       when 'image/png' then '.png' when 'image/webp' then '.webp' end;
  if v_ext is null then
    raise exception 'Evidence has to be a PDF, JPEG, PNG or WebP.' using errcode = '22023';
  end if;
  v_path := v_person::text || '/' || e.id::text || '-' || substr(md5(random()::text), 1, 10) || v_ext;
  insert into public.cpd_evidence_uploads
    (entry_id, person_id, sha256, storage_path, original_name, content_type, byte_size)
  values (e.id, v_person, lower(p_sha256), v_path, left(coalesce(nullif(btrim(p_name), ''), 'evidence'), 200),
          p_type, p_size)
  returning id into v_id;
  return jsonb_build_object('upload_id', v_id, 'path', v_path);
end;
$$;
revoke all on function public.cpd_evidence_begin(uuid, text, text, text, integer) from public;
grant execute on function public.cpd_evidence_begin(uuid, text, text, text, integer) to authenticated;

-- As the Worker, once the bytes are stored: record them. The fingerprint is
-- the one the Worker took, and must match what was asked for.
create or replace function public.cpd_evidence_record(p_upload uuid, p_sha256 text) returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  u    public.cpd_evidence_uploads;
  v_id uuid;
begin
  select * into u from public.cpd_evidence_uploads where id = p_upload for update;
  if u.id is null or u.created_at < now() - interval '10 minutes' then
    raise exception 'That upload was not asked for, or has expired.' using errcode = '42501';
  end if;
  if u.sha256 <> lower(coalesce(p_sha256, '')) then
    raise exception 'The file stored is not the file that was asked about.' using errcode = '42501';
  end if;
  -- Two uploads of one file at the same moment: one waits for the other.
  perform pg_advisory_xact_lock(hashtext('cpd_evidence:' || u.sha256));
  if app.cpd_sha256_used(u.sha256) is not null then
    delete from public.cpd_evidence_uploads where id = u.id;
    raise exception 'This certificate has already been used for CPD. A certificate counts once.'
      using errcode = '23505';
  end if;
  if not exists (select 1 from public.cpd_entries where id = u.entry_id and status = 'pending') then
    delete from public.cpd_evidence_uploads where id = u.id;
    raise exception 'Evidence can only be added while an entry is waiting for review.' using errcode = '22023';
  end if;
  insert into public.cpd_evidence
    (cpd_entry_id, storage_path, original_name, byte_size, content_type, signature_ok, sha256)
  values (u.entry_id, u.storage_path, u.original_name, u.byte_size, u.content_type, true, u.sha256)
  returning id into v_id;
  delete from public.cpd_evidence_uploads where id = u.id;
  return v_id;
end;
$$;
revoke all on function public.cpd_evidence_record(uuid, text) from public, anon, authenticated;
grant execute on function public.cpd_evidence_record(uuid, text) to service_role;


-- -----------------------------------------------------------------------------
-- 2. Claude reads the certificate
-- -----------------------------------------------------------------------------
create table if not exists public.cpd_certificate_readings (
  id                 uuid primary key default gen_random_uuid(),
  evidence_id        uuid not null references public.cpd_evidence(id) on delete cascade,
  entry_id           uuid not null references public.cpd_entries(id) on delete cascade,
  readable           boolean not null,
  is_certificate     boolean not null default true,
  holder_name        text,
  course             text,
  issuer             text,
  awarded_on         date,
  certificate_number text,
  -- Upper case letters and digits only, so "AB-123 / 4" and "ab1234" agree.
  number_key         text generated always as
                       (nullif(upper(regexp_replace(coalesce(certificate_number, ''), '[^A-Za-z0-9]', '', 'g')), '')) stored,
  concerns           text,
  model              text not null,
  asked_by           uuid references public.people(id),
  created_at         timestamptz not null default now()
);
create index if not exists cpd_certificate_readings_evidence on public.cpd_certificate_readings (evidence_id, created_at desc);
create index if not exists cpd_certificate_readings_number on public.cpd_certificate_readings (number_key) where number_key is not null;

alter table public.cpd_certificate_readings enable row level security;
revoke all on public.cpd_certificate_readings from anon, authenticated;
grant select on public.cpd_certificate_readings to authenticated;
drop policy if exists cert_readings_staff on public.cpd_certificate_readings;
create policy cert_readings_staff on public.cpd_certificate_readings
  for select to authenticated using ((select app.is_membership_staff()));
drop trigger if exists cpd_certificate_readings_audit on public.cpd_certificate_readings;
create trigger cpd_certificate_readings_audit after insert or update or delete on public.cpd_certificate_readings
  for each row execute function app.audit_row();

-- Claude reads PDFs up to 10MB and pictures up to 5MB. Anything larger is for
-- the office to read; the card says so.
create or replace function app.cpd_certificate_readable_size(p_type text, p_size integer) returns boolean
language sql immutable set search_path = ''
as $$ select case when p_type = 'application/pdf' then p_size <= 10485760
                  when p_type in ('image/jpeg', 'image/png', 'image/webp') then p_size <= 5242880
                  else false end; $$;

-- As staff: which certificates to read. Nothing about the person.
create or replace function public.ai_certificate_begin(p_limit integer default 2) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_by    uuid := app.person_id();
  v_items jsonb;
begin
  if not app.is_membership_staff() or v_by is null then
    raise exception 'Asking Claude about CPD is for membership staff.' using errcode = '42501';
  end if;
  with picked as (
    select v.id
      from public.cpd_evidence v
      join public.cpd_entries e on e.id = v.cpd_entry_id
     where e.status = 'pending'
       and app.cpd_certificate_readable_size(v.content_type, v.byte_size)
       and not exists (select 1 from public.cpd_certificate_readings r where r.evidence_id = v.id)
       and (v.ai_requested_at is null or v.ai_requested_at < now() - interval '10 minutes')
     order by v.uploaded_at
     limit greatest(1, least(coalesce(p_limit, 2), 3))
     for update of v skip locked
  ), stamped as (
    update public.cpd_evidence v set ai_requested_by = v_by, ai_requested_at = now()
      from picked where v.id = picked.id
    returning v.id, v.cpd_entry_id, v.storage_path, v.content_type, v.byte_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'path', s.storage_path, 'content_type', s.content_type, 'byte_size', s.byte_size,
           'activity', t.name, 'title', e.title, 'provider', e.provider, 'occurred_on', e.occurred_on)), '[]'::jsonb)
    into v_items
    from stamped s
    join public.cpd_entries e on e.id = s.cpd_entry_id
    join public.cpd_activity_types t on t.id = e.activity_type_id;

  return jsonb_build_object(
    'by', v_by,
    'model', coalesce(nullif(app.setting('ai_review_model'), ''), 'claude-sonnet-5-5'),
    'items', v_items,
    'remaining', (select count(*) from public.cpd_evidence v
                    join public.cpd_entries e on e.id = v.cpd_entry_id
                   where e.status = 'pending'
                     and app.cpd_certificate_readable_size(v.content_type, v.byte_size)
                     and not exists (select 1 from public.cpd_certificate_readings r where r.evidence_id = v.id)
                     and v.ai_requested_at is null));
end;
$$;
revoke all on function public.ai_certificate_begin(integer) from public;
grant execute on function public.ai_certificate_begin(integer) to authenticated;

-- As the Worker: what Claude read.
create or replace function public.ai_certificate_record(
  p_evidence uuid, p_by uuid, p_model text, p_readable boolean, p_is_certificate boolean,
  p_holder text, p_course text, p_issuer text, p_awarded_on text, p_number text, p_concerns text)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v    public.cpd_evidence;
  v_on date;
  v_id uuid;
begin
  select * into v from public.cpd_evidence where id = p_evidence for update;
  if v.id is null then
    raise exception 'There is no such evidence.' using errcode = '22023';
  end if;
  if p_by is null or v.ai_requested_by is distinct from p_by
     or v.ai_requested_at < now() - interval '10 minutes' then
    raise exception 'Nobody on the staff asked about this certificate just now.' using errcode = '42501';
  end if;
  -- A date Claude could not read cleanly is left empty rather than refused.
  begin
    v_on := nullif(btrim(coalesce(p_awarded_on, '')), '')::date;
  exception when others then
    v_on := null;
  end;
  insert into public.cpd_certificate_readings
    (evidence_id, entry_id, readable, is_certificate, holder_name, course, issuer, awarded_on,
     certificate_number, concerns, model, asked_by)
  values
    (v.id, v.cpd_entry_id, coalesce(p_readable, false), coalesce(p_is_certificate, false),
     left(nullif(btrim(coalesce(p_holder, '')), ''), 200), left(nullif(btrim(coalesce(p_course, '')), ''), 300),
     left(nullif(btrim(coalesce(p_issuer, '')), ''), 200), v_on,
     left(nullif(btrim(coalesce(p_number, '')), ''), 100), left(nullif(btrim(coalesce(p_concerns, '')), ''), 1000),
     left(coalesce(p_model, ''), 100), p_by)
  returning id into v_id;
  update public.cpd_evidence set ai_requested_by = null, ai_requested_at = null where id = v.id;
  return v_id;
end;
$$;
revoke all on function public.ai_certificate_record(uuid, uuid, text, boolean, boolean, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.ai_certificate_record(uuid, uuid, text, boolean, boolean, text, text, text, text, text, text)
  to service_role;

create or replace function public.ai_certificate_release(p_evidence uuid, p_by uuid) returns void
language sql volatile security definer set search_path = ''
as $$
  update public.cpd_evidence set ai_requested_by = null, ai_requested_at = null
   where id = p_evidence and ai_requested_by = p_by;
$$;
revoke all on function public.ai_certificate_release(uuid, uuid) from public, anon, authenticated;
grant execute on function public.ai_certificate_release(uuid, uuid) to service_role;


-- -----------------------------------------------------------------------------
-- 3. What the office sees on each entry
-- -----------------------------------------------------------------------------
-- One row per pending or decided entry, built here so the queue view stays
-- readable. The latest reading on any of the entry's files.
create or replace view public.admin_cpd_certificate_checks
with (security_invoker = true) as
  select e.id as entry_id,
         r.readable, r.is_certificate, r.holder_name, r.course, r.issuer, r.awarded_on,
         r.certificate_number, r.concerns,
         -- The same number on another entry that counts, anybody's.
         (select pp.given_name || ' ' || pp.family_name || ', ' || to_char(oe.occurred_on, 'DD Mon YYYY')
                 || ', ' || oe.status::text
            from public.cpd_certificate_readings o
            join public.cpd_entries oe on oe.id = o.entry_id
            join public.members om on om.id = oe.member_id
            join public.people pp on pp.id = om.person_id
           where o.number_key = r.number_key and o.entry_id <> e.id and oe.status <> 'rejected'
           order by o.created_at limit 1) as number_used_on,
         -- Does the name on the certificate look like the member's? Family name
         -- and the first letter of the given name, ignoring case and spacing.
         case when r.holder_name is null then null
              else position(lower(regexp_replace(p.family_name, '\s', '', 'g'))
                            in lower(regexp_replace(r.holder_name, '\s', '', 'g'))) > 0
                   and position(lower(left(p.given_name, 1)) in lower(r.holder_name)) > 0 end as holder_matches,
         case when r.awarded_on is null then null else abs(r.awarded_on - e.occurred_on) end as date_gap_days,
         -- Files on the entry that Claude cannot read, for the office to open.
         (select count(*)::int from public.cpd_evidence v
           where v.cpd_entry_id = e.id and not app.cpd_certificate_readable_size(v.content_type, v.byte_size))
           as files_too_large
    from public.cpd_entries e
    join public.members m on m.id = e.member_id
    join public.people p on p.id = m.person_id
    left join lateral (select x.* from public.cpd_certificate_readings x where x.entry_id = e.id
                        order by x.created_at desc limit 1) r on true;

grant select on public.admin_cpd_certificate_checks to authenticated;

-- 0044's queue view with the certificate checks and the repeat flag appended.
create or replace view public.admin_cpd_queue
with (security_invoker = true) as
  select e.id, e.member_id, e.year, e.occurred_on, e.title, e.provider,
         e.points, e.is_core, e.status, e.evidence_ref, e.recorded_at,
         t.name as activity_type,
         m.membership_number,
         p.given_name, p.family_name,
         e.reflection,
         app.word_count(e.reflection) as reflection_words,
         t.min_words,
         t.needs_evidence,
         (select count(*) from public.cpd_evidence v where v.cpd_entry_id = e.id) as evidence_count,
         r.recommendation as ai_recommendation,
         r.reason         as ai_reason,
         r.member_note    as ai_member_note,
         r.created_at     as ai_reviewed_at,
         r.model          as ai_model,
         g.version        as ai_guide_version,
         e.ai_assisted,
         pt.name          as paired_activity,
         pe.status::text  as paired_status,
         c.readable       as cert_readable,
         c.is_certificate as cert_is_certificate,
         c.holder_name    as cert_holder,
         c.course         as cert_course,
         c.issuer         as cert_issuer,
         c.awarded_on     as cert_awarded_on,
         c.certificate_number as cert_number,
         c.concerns       as cert_concerns,
         c.number_used_on as cert_number_used_on,
         c.holder_matches as cert_holder_matches,
         c.date_gap_days  as cert_date_gap_days,
         c.files_too_large as cert_files_too_large,
         -- A second entry by the same member for the same activity, on the
         -- same date or with the same title, that counts.
         (select x.title || ', ' || to_char(x.occurred_on, 'DD Mon YYYY') || ', ' || x.status::text
            from public.cpd_entries x
           where x.member_id = e.member_id and x.id <> e.id and x.activity_type_id = e.activity_type_id
             and x.status <> 'rejected'
             and (x.occurred_on = e.occurred_on or lower(btrim(x.title)) = lower(btrim(e.title)))
           order by x.recorded_at limit 1) as possible_repeat
    from public.cpd_entries e
    join public.cpd_activity_types t on t.id = e.activity_type_id
    join public.members m on m.id = e.member_id
    join public.people p on p.id = m.person_id
    left join lateral (select * from public.cpd_ai_reviews x where x.entry_id = e.id
                          and x.created_at > coalesce(e.reflection_changed_at, '-infinity'::timestamptz)
                        order by x.created_at desc, x.id limit 1) r on true
    left join public.cpd_review_guides g on g.id = r.guide_id
    left join public.cpd_entries pe on pe.id = e.paired_entry_id
    left join public.cpd_activity_types pt on pt.id = pe.activity_type_id
    left join public.admin_cpd_certificate_checks c on c.entry_id = e.id;

grant select on public.admin_cpd_queue to authenticated;

-- The office opens evidence files from the card. Staff could always read the
-- table; this is the list the card asks for.
create or replace view public.admin_cpd_evidence
with (security_invoker = true) as
  select v.id, v.cpd_entry_id, v.storage_path, v.original_name, v.byte_size, v.content_type,
         v.uploaded_at, v.signature_ok, v.sha256 is not null as fingerprinted
    from public.cpd_evidence v;
grant select on public.admin_cpd_evidence to authenticated;
