-- =============================================================================
-- 0044  A reflection sent with its course certificate earns both
--
-- Steve, 31 October 2026: "there are points for certificates and points for
-- reflections, so a reflection submitted with a certificate should qualify for
-- the points for both."
--
-- So when a member logs a reflection following a training course AND attaches
-- the course certificate, two entries are logged in one transaction:
--
--   the reflection, 2 non core points, read by Claude and decided by a person
--   the course itself, as an External training course or seminar (1 point) or
--   a Formal asbestos qualification (2 points), with the certificate attached
--
-- Each is pending and each is decided on its own merits: a good certificate
-- with a thin reflection earns the course and not the reflection. They point
-- at each other, so the office sees they came together.
--
-- ONLY those two activities. They are the ones a course certificate proves.
-- An ARCA course is not one of them: ARCA's records award it automatically
-- (item 5 of the plan), and logging it here as well would count it twice. The
-- form says so.
--
-- Safe to run twice.
-- =============================================================================

alter table public.cpd_entries add column if not exists paired_entry_id uuid
  references public.cpd_entries(id) on delete set null;

comment on column public.cpd_entries.paired_entry_id is
  'The other half of a reflection logged together with its course certificate. '
  'Set only by log_reflection_with_certificate.';

-- -----------------------------------------------------------------------------
-- 1. The guard from 0043, now covering the pairing too
-- -----------------------------------------------------------------------------
-- A member may update their own pending entries, so without this a console
-- could point an entry at somebody else's.
create or replace function app.cpd_ai_columns_guard() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.ai_assisted := false;
    new.ai_review_id := null;
    new.ai_requested_by := null;
    new.ai_requested_at := null;
    new.reflection_changed_at := null;
    new.paired_entry_id := null;
    return new;
  end if;
  if new.paired_entry_id is distinct from old.paired_entry_id then
    raise exception 'Which entries were logged together is recorded by the database, not set by hand.'
      using errcode = '42501';
  end if;
  if new.reflection is not distinct from old.reflection
     and new.reflection_changed_at is distinct from old.reflection_changed_at then
    raise exception 'Whether AI assisted is recorded by the database, not set by hand.'
      using errcode = '42501';
  end if;
  if (new.ai_requested_by, new.ai_requested_at) is distinct from (old.ai_requested_by, old.ai_requested_at)
     or ((new.ai_assisted, new.ai_review_id) is distinct from (old.ai_assisted, old.ai_review_id)
         and not (new.status is distinct from old.status)) then
    raise exception 'Whether AI assisted is recorded by the database, not set by hand.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;


-- -----------------------------------------------------------------------------
-- 2. Logging both at once
-- -----------------------------------------------------------------------------
-- DEFINER so that it can write the pairing, which the guard refuses to a
-- browser. Every other rule is log_cpd's own, called twice as the member:
-- app.member_id() reads the member's token whoever runs the function, so each
-- entry is theirs, valued from its activity, dated, titled and word counted
-- exactly as if logged on its own.
create or replace function public.log_reflection_with_certificate(
  p_occurred_on       date,
  p_reflection_type   uuid,
  p_certificate_type  uuid,
  p_title             text,
  p_provider          text,
  p_reflection        text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  r      public.cpd_activity_types;
  c      public.cpd_activity_types;
  v_refl uuid;
  v_cert uuid;
begin
  if app.member_id() is null then
    raise exception 'There is no AMI membership for this account.' using errcode = '42501';
  end if;
  select * into r from public.cpd_activity_types where id = p_reflection_type;
  select * into c from public.cpd_activity_types where id = p_certificate_type;
  if r.id is null or r.min_words = 0 then
    raise exception 'The first entry has to be a reflection.' using errcode = '22023';
  end if;
  if c.id is null or c.code not in ('external_training', 'qualification') then
    raise exception 'A course certificate counts as an external training course or a formal qualification.'
      using errcode = '22023';
  end if;

  v_refl := public.log_cpd(p_occurred_on, r.id, p_title, p_provider, null, null, p_reflection);
  v_cert := public.log_cpd(p_occurred_on, c.id, p_title, p_provider, null, null, null);

  update public.cpd_entries set paired_entry_id = v_cert where id = v_refl;
  update public.cpd_entries set paired_entry_id = v_refl where id = v_cert;

  return jsonb_build_object('reflection_id', v_refl, 'certificate_id', v_cert);
end;
$$;
revoke all on function public.log_reflection_with_certificate(date, uuid, uuid, text, text, text) from public;
grant execute on function public.log_reflection_with_certificate(date, uuid, uuid, text, text, text) to authenticated;


-- -----------------------------------------------------------------------------
-- 3. The office sees the pair
-- -----------------------------------------------------------------------------
-- 0043's view with two columns appended at the end.
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
         pe.status::text  as paired_status
    from public.cpd_entries e
    join public.cpd_activity_types t on t.id = e.activity_type_id
    join public.members m on m.id = e.member_id
    join public.people p on p.id = m.person_id
    left join lateral (select * from public.cpd_ai_reviews x where x.entry_id = e.id
                          and x.created_at > coalesce(e.reflection_changed_at, '-infinity'::timestamptz)
                        order by x.created_at desc, x.id limit 1) r on true
    left join public.cpd_review_guides g on g.id = r.guide_id
    left join public.cpd_entries pe on pe.id = e.paired_entry_id
    left join public.cpd_activity_types pt on pt.id = pe.activity_type_id;

grant select on public.admin_cpd_queue to authenticated;
