-- =============================================================================
-- 0054  AMI's members come from Dynamics
--
-- Steve, 31 October: Dynamics holds whether somebody is an AMI member, "and the
-- website should read from this so there is only one source of truth". Agreed
-- the same afternoon:
--
--   Dynamics owns, on the contact: AMI Member? (who is a member), AMI Category
--   (the grade), first and last name, Email and Email Address 2.
--   The website owns everything else: the membership number, CPD, the card,
--   photographs, preferences, the forum.
--   An application approved on the website makes the member here as before;
--   the office also adds them in Dynamics, and the next sync links the two.
--
-- HOW
--
--   A fourth view, "AMI Sync: Members", on the Contact table, filtered to AMI
--   Member? = Yes. The sync reads it first, every run, through
--   dynamics_members_record, which links each contact to a website person
--   (by the contact's id once linked, found the first time by email) and
--   copies the name, the emails and the grade onto them, and switches an
--   inactive membership back on. dynamics_members_close then switches off any
--   linked membership whose contact has left the view, unless the view came
--   back with under 80% of the linked members, which is a broken read and not
--   a mass lapse, as AuditFlow guards its members mirror.
--
--   Those fields are then the sync's to write. Staff editing them for a
--   linked person are told to change them in Dynamics (people_dynamics_guard,
--   members_dynamics_guard), so the two cannot drift.
--
--   AMI Category is mapped to a website grade by dynamics_grade_map: matched
--   by name the first time it is seen where that is unambiguous ("Fellow" to
--   Fellow, "Affiliate" to Affiliate Member), otherwise left for the office to
--   map in the admin app. Until a category is mapped, the grade is left alone.
--
--   Attendance: each attendance view can carry the delegate's contact
--   (contact_field). A row whose contact is a website person's is matched by
--   it, exactly, before any email. A row whose contact Dynamics says is an
--   AMI member, but who has no website record yet, is kept and shown as such.
--
--   The office's check list (admin_dynamics_member_check): AMI members in
--   Dynamics with no website membership, active website members with no
--   Dynamics contact, and categories not yet mapped.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The link, and the fourth feed
-- -----------------------------------------------------------------------------
alter table public.people add column if not exists dynamics_contact_id text;
create unique index if not exists people_dynamics_contact on public.people (dynamics_contact_id)
  where dynamics_contact_id is not null;
comment on column public.people.dynamics_contact_id is
  'The person''s contact in ARCA''s Dynamics. Set by the sync. While set, the name, '
  'emails, grade and whether they are a member come from Dynamics.';

alter table public.dynamics_feeds drop constraint if exists dynamics_feeds_code_check;
alter table public.dynamics_feeds add constraint dynamics_feeds_code_check
  check (code in ('ami_members', 'regional_meetings', 'arca_agm', 'arca_training'));
alter table public.dynamics_feeds add column if not exists given_field    text;
alter table public.dynamics_feeds add column if not exists family_field   text;
alter table public.dynamics_feeds add column if not exists category_field text;
alter table public.dynamics_feeds add column if not exists contact_field  text;
grant update (given_field, family_field, category_field, contact_field) on public.dynamics_feeds to authenticated;

insert into public.dynamics_feeds (code, title, view_name, activity_code) values
  ('ami_members', 'AMI members', 'AMI Sync: Members', 'none')
on conflict (code) do nothing;

create or replace function app.dynamics_feed_rules() returns trigger
language plpgsql security invoker set search_path = ''
as $$
declare
  f text;
begin
  foreach f in array array[new.email_field, new.email2_field, new.name_field, new.event_field,
                           new.code_field, new.date_field, new.given_field, new.family_field,
                           new.category_field, new.contact_field] loop
    if f is not null and btrim(f) <> '' and btrim(f) !~ '^[A-Za-z_][A-Za-z0-9_.]{0,99}$' then
      raise exception '"%" is not a Dynamics column name. Copy it exactly from the list the sync found.', f
        using errcode = '22023';
    end if;
  end loop;
  new.email_field    := nullif(btrim(coalesce(new.email_field, '')), '');
  new.email2_field   := nullif(btrim(coalesce(new.email2_field, '')), '');
  new.name_field     := nullif(btrim(coalesce(new.name_field, '')), '');
  new.event_field    := nullif(btrim(coalesce(new.event_field, '')), '');
  new.code_field     := nullif(btrim(coalesce(new.code_field, '')), '');
  new.date_field     := nullif(btrim(coalesce(new.date_field, '')), '');
  new.given_field    := nullif(btrim(coalesce(new.given_field, '')), '');
  new.family_field   := nullif(btrim(coalesce(new.family_field, '')), '');
  new.category_field := nullif(btrim(coalesce(new.category_field, '')), '');
  new.contact_field  := nullif(btrim(coalesce(new.contact_field, '')), '');
  new.view_name      := btrim(new.view_name);
  new.updated_at     := now();
  return new;
end;
$$;

drop trigger if exists dynamics_feeds_audit on public.dynamics_feeds;
create trigger dynamics_feeds_audit
  after insert or delete or update of view_name, email_field, email2_field, name_field, event_field,
                                      code_field, date_field, given_field, family_field,
                                      category_field, contact_field, active
  on public.dynamics_feeds
  for each row execute function app.audit_row();

create or replace function app.dynamics_feed_ready(f public.dynamics_feeds) returns boolean
language sql stable set search_path = ''
as $$
  select f.active and f.email_field is not null and case
    when f.code = 'ami_members' then f.family_field is not null and f.category_field is not null
    else f.date_field is not null and (f.code = 'arca_agm' or f.event_field is not null) end;
$$;

-- A lookup's id, which is the value itself and not the words beside it.
create or replace function app.dyn_raw(p_raw jsonb, p_field text) returns text
language sql immutable set search_path = ''
as $$ select nullif(btrim(coalesce(p_raw ->> app.dyn_key(p_raw, p_field), '')), ''); $$;


-- -----------------------------------------------------------------------------
-- 2. What Dynamics last said about each AMI member
-- -----------------------------------------------------------------------------
create table if not exists public.dynamics_members_seen (
  contact_id   text primary key,
  given_name   text,
  family_name  text,
  email        text,
  email2       text,
  category     text,
  person_id    uuid references public.people(id) on delete set null,
  problem      text,
  last_run     uuid,
  first_seen   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.dynamics_members_seen is
  'Every contact Dynamics lists as an AMI member, as the last sync read it. A row '
  'leaves when the contact leaves the view. problem says why one could not be '
  'linked or copied, in words for the office.';
alter table public.dynamics_members_seen enable row level security;
revoke all on public.dynamics_members_seen from anon, authenticated;
grant select on public.dynamics_members_seen to authenticated;
drop policy if exists dynamics_members_seen_read on public.dynamics_members_seen;
create policy dynamics_members_seen_read on public.dynamics_members_seen
  for select to authenticated using ((select app.is_membership_staff()));


-- -----------------------------------------------------------------------------
-- 3. AMI Category to grade
-- -----------------------------------------------------------------------------
create table if not exists public.dynamics_grade_map (
  category_key text primary key,
  category     text not null,
  grade_id     uuid references public.membership_grades(id),
  decided_by   uuid references public.people(id),
  decided_at   timestamptz,
  first_seen   timestamptz not null default now()
);
alter table public.dynamics_grade_map enable row level security;
revoke all on public.dynamics_grade_map from anon, authenticated;
grant select on public.dynamics_grade_map to authenticated;
drop policy if exists dynamics_grade_map_read on public.dynamics_grade_map;
create policy dynamics_grade_map_read on public.dynamics_grade_map
  for select to authenticated using ((select app.is_membership_staff()));
drop trigger if exists dynamics_grade_map_audit on public.dynamics_grade_map;
create trigger dynamics_grade_map_audit after insert or update or delete on public.dynamics_grade_map
  for each row execute function app.audit_row();

-- The first time a category is seen: the one grade whose name or code is it,
-- or starts with it ("Affiliate" and Affiliate Member), or none.
create or replace function app.dynamics_category_grade(p_category text) returns uuid
language sql stable security definer set search_path = ''
as $$
  with k as (select app.name_key(p_category) as k),
       hits as (
         select g.id from public.membership_grades g, k
          where k.k is not null
            and (app.name_key(g.name) = k.k or app.name_key(g.code) = k.k)
         union
         select g.id from public.membership_grades g, k
          where k.k is not null
            and not exists (select 1 from public.membership_grades g2
                             where app.name_key(g2.name) = k.k or app.name_key(g2.code) = k.k)
            and app.name_key(g.name) like k.k || '%')
  select case when (select count(*) from hits) = 1 then (select id from hits) end;
$$;
revoke all on function app.dynamics_category_grade(text) from public;

create or replace function public.dynamics_grade_map_set(p_category_key text, p_grade_code text) returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_grade uuid;
begin
  if not app.is_membership_staff() then
    raise exception 'Mapping AMI categories is for membership staff.' using errcode = '42501';
  end if;
  select id into v_grade from public.membership_grades where code = p_grade_code;
  if v_grade is null then
    raise exception 'There is no grade %.', p_grade_code using errcode = '22023';
  end if;
  update public.dynamics_grade_map set grade_id = v_grade, decided_by = app.person_id(), decided_at = now()
   where category_key = p_category_key;
  if not found then
    raise exception 'There is no such AMI category.' using errcode = '22023';
  end if;
end;
$$;
revoke all on function public.dynamics_grade_map_set(text, text) from public;
grant execute on function public.dynamics_grade_map_set(text, text) to authenticated;


-- -----------------------------------------------------------------------------
-- 4. The fields Dynamics owns cannot be changed here for a linked person
-- -----------------------------------------------------------------------------
-- INVOKER, so it sees who is really writing: the sync and every other definer
-- function run as the owner and pass; a signed in browser is 'authenticated'.
create or replace function app.people_dynamics_guard() returns trigger
language plpgsql security invoker set search_path = ''
as $$
begin
  if old.dynamics_contact_id is not null and current_user in ('authenticated', 'anon')
     and (new.given_name, new.family_name, new.email, new.alt_email, new.dynamics_contact_id)
         is distinct from (old.given_name, old.family_name, old.email, old.alt_email, old.dynamics_contact_id) then
    raise exception 'This person''s name and emails come from ARCA''s Dynamics. Change them there; the website follows on the next sync.'
      using errcode = '42501';
  end if;
  if old.dynamics_contact_id is null and new.dynamics_contact_id is not null
     and current_user in ('authenticated', 'anon') then
    raise exception 'The link to Dynamics is made by the sync.' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists people_dynamics_guard on public.people;
create trigger people_dynamics_guard before update on public.people
  for each row execute function app.people_dynamics_guard();

create or replace function app.members_dynamics_guard() returns trigger
language plpgsql security invoker set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.grade_id, new.is_active) is distinct from (old.grade_id, old.is_active)
     and exists (select 1 from public.people p where p.id = new.person_id and p.dynamics_contact_id is not null) then
    raise exception 'Whether this person is a member, and their grade, come from ARCA''s Dynamics (AMI Member? and AMI Category). Change them there; the website follows on the next sync.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists members_dynamics_guard on public.members;
create trigger members_dynamics_guard before update on public.members
  for each row execute function app.members_dynamics_guard();


-- -----------------------------------------------------------------------------
-- 5. Reading the members view: the Worker, as the service role
-- -----------------------------------------------------------------------------
create or replace function public.dynamics_members_record(p_run uuid, p_meta jsonb, p_rows jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  rn      public.dynamics_runs;
  f       public.dynamics_feeds;
  r       jsonb;
  v_id    text;
  v_given text;
  v_fam   text;
  v_e1    text;
  v_e2    text;
  v_cat   text;
  v_ck    text;
  v_pid   uuid;
  v_n     int;
  v_grade uuid;
  v_mem   public.members;
  v_prob  text;
  c_read int := 0; c_bad int := 0; c_linked int := 0; c_new_link int := 0;
  c_changed int := 0; c_unlinked int := 0; c_unmapped int := 0; c_on int := 0;
  p public.people;
begin
  select * into rn from public.dynamics_runs where id = p_run;
  if rn.id is null or rn.status <> 'running' or rn.started_at < now() - interval '20 minutes' then
    raise exception 'That sync is not running.' using errcode = '42501';
  end if;
  select * into f from public.dynamics_feeds where code = 'ami_members';
  if not f.active then
    raise exception 'The AMI members feed is paused.' using errcode = '22023';
  end if;

  update public.dynamics_feeds
     set seen_entity = left(p_meta ->> 'entity', 100),
         seen_fields = coalesce((select jsonb_agg(distinct x order by x)
                                   from jsonb_array_elements_text(coalesce(p_meta -> 'fields', '[]'::jsonb)) x
                                  where x ~ '^[A-Za-z_][A-Za-z0-9_.]{0,99}$'), '[]'::jsonb),
         last_run_at = now()
   where code = f.code;
  if not app.dynamics_feed_ready(f) then
    update public.dynamics_feeds
       set last_result = jsonb_build_object('read', jsonb_array_length(p_rows), 'waiting', 'the columns are not named yet')
     where code = f.code;
    return jsonb_build_object('feed', f.code, 'read', jsonb_array_length(p_rows), 'ready', false);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    c_read := c_read + 1;
    v_id    := lower(nullif(btrim(coalesce(r ->> '_ami_id', '')), ''));
    v_given := app.dyn_text(r, f.given_field);
    v_fam   := app.dyn_text(r, f.family_field);
    v_e1    := lower(btrim(coalesce(app.dyn_text(r, f.email_field), '')));
    v_e1    := case when v_e1 ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_e1 end;
    v_e2    := lower(btrim(coalesce(app.dyn_text(r, f.email2_field), '')));
    v_e2    := case when v_e2 ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and v_e2 is distinct from v_e1 then v_e2 end;
    if v_e1 is null then v_e1 := v_e2; v_e2 := null; end if;
    v_cat   := app.dyn_text(r, f.category_field);
    if v_id is null then c_bad := c_bad + 1; continue; end if;
    v_prob := null;

    -- The category, seen for the first time, is mapped by name if it can be.
    v_grade := null;
    v_ck := app.name_key(v_cat);
    if v_ck is not null then
      insert into public.dynamics_grade_map (category_key, category, grade_id)
      values (v_ck, v_cat, app.dynamics_category_grade(v_cat))
      on conflict (category_key) do nothing;
      select grade_id into v_grade from public.dynamics_grade_map where category_key = v_ck;
      if v_grade is null then c_unmapped := c_unmapped + 1; end if;
    end if;

    -- Who on the website: by the contact once linked, otherwise by email,
    -- once, and only if exactly one unlinked person holds it.
    select id into v_pid from public.people where dynamics_contact_id = v_id;
    if v_pid is null then
      select count(*), (array_agg(pp.id))[1] into v_n, v_pid
        from public.people pp
       where pp.dynamics_contact_id is null
         and (lower(btrim(pp.email)) in (v_e1, v_e2) or pp.alt_email in (v_e1, v_e2));
      if v_n = 1 then
        update public.people set dynamics_contact_id = v_id where id = v_pid;
        c_new_link := c_new_link + 1;
      else
        v_prob := case when v_n > 1 then 'More than one person on the website has one of these emails.'
                       else 'Nobody on the website has either email. Add them as a member, with the same email, and they are linked on the next sync.' end;
        v_pid := null;
      end if;
    end if;

    if v_pid is not null then
      c_linked := c_linked + 1;
      select * into p from public.people where id = v_pid;
      -- The name and the emails, where they differ and do not collide.
      begin
        update public.people
           set given_name  = coalesce(v_given, given_name),
               family_name = coalesce(v_fam, family_name),
               email       = coalesce(v_e1, email),
               alt_email   = v_e2
         where id = v_pid
           and (coalesce(v_given, given_name), coalesce(v_fam, family_name), lower(coalesce(v_e1, email)), v_e2)
               is distinct from (given_name, family_name, lower(email), alt_email);
        if found then c_changed := c_changed + 1; end if;
      exception when unique_violation then
        v_prob := 'One of the emails in Dynamics belongs to somebody else on the website, so the emails were not copied.';
        update public.people
           set given_name = coalesce(v_given, given_name), family_name = coalesce(v_fam, family_name)
         where id = v_pid;
      end;

      select * into v_mem from public.members where person_id = v_pid
       order by is_active desc, joined_on desc limit 1;
      if v_mem.id is null then
        v_prob := coalesce(v_prob, 'Linked to a person on the website with no membership. Add their membership on the website.');
      else
        if v_grade is not null and v_mem.grade_id is distinct from v_grade then
          update public.members set grade_id = v_grade where id = v_mem.id;
          c_changed := c_changed + 1;
        end if;
        if not v_mem.is_active then
          update public.members set is_active = true, status = 'current' where id = v_mem.id;
          c_on := c_on + 1;
        end if;
      end if;
    else
      c_unlinked := c_unlinked + 1;
    end if;

    insert into public.dynamics_members_seen (contact_id, given_name, family_name, email, email2, category,
                                             person_id, problem, last_run, updated_at)
    values (v_id, v_given, v_fam, v_e1, v_e2, v_cat, v_pid, v_prob, p_run, now())
    on conflict (contact_id) do update
       set given_name = excluded.given_name, family_name = excluded.family_name,
           email = excluded.email, email2 = excluded.email2, category = excluded.category,
           person_id = excluded.person_id, problem = excluded.problem,
           last_run = excluded.last_run, updated_at = now();
  end loop;

  update public.dynamics_feeds
     set last_result = jsonb_build_object('read', c_read, 'unreadable', c_bad,
           'decided', jsonb_build_object('linked', c_linked, 'newly_linked', c_new_link, 'changed', c_changed,
                                         'switched_on', c_on, 'not_on_website', c_unlinked,
                                         'category_unmapped', c_unmapped))
   where code = f.code;
  return jsonb_build_object('feed', f.code, 'ready', true, 'read', c_read, 'unreadable', c_bad,
    'decided', jsonb_build_object('linked', c_linked, 'newly_linked', c_new_link, 'changed', c_changed,
                                  'switched_on', c_on, 'not_on_website', c_unlinked,
                                  'category_unmapped', c_unmapped));
end;
$$;
revoke all on function public.dynamics_members_record(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.dynamics_members_record(uuid, jsonb, jsonb) to service_role;

-- After every batch of the members view: whoever has left it is no longer a
-- member. p_ids is every contact id the view held this run.
create or replace function public.dynamics_members_close(p_run uuid, p_ids text[]) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  rn     public.dynamics_runs;
  v_ids  text[];
  v_live int;
  v_off  int := 0;
  m      record;
begin
  select * into rn from public.dynamics_runs where id = p_run;
  if rn.id is null or rn.status <> 'running' then
    raise exception 'That sync is not running.' using errcode = '42501';
  end if;
  select coalesce(array_agg(lower(x)), '{}') into v_ids from unnest(coalesce(p_ids, '{}')) x;

  select count(*) into v_live from public.members mm join public.people pp on pp.id = mm.person_id
   where mm.is_active and pp.dynamics_contact_id is not null;
  -- A view that comes back much smaller than the members it accounts for is a
  -- broken read, not a mass lapse. Nobody is switched off; the run says so.
  if v_live >= 5 and cardinality(v_ids) < 0.8 * v_live then
    return jsonb_build_object('switched_off', 0,
      'refused', format('The members view held %s contacts against %s linked members, so nobody was switched off. Check the view.',
                        cardinality(v_ids), v_live));
  end if;

  for m in select mm.id from public.members mm join public.people pp on pp.id = mm.person_id
            where mm.is_active and pp.dynamics_contact_id is not null
              and not (pp.dynamics_contact_id = any(v_ids)) loop
    update public.members
       set is_active = false, status = 'lapsed',
           deactivation_reason = 'No longer an AMI member in ARCA''s Dynamics.'
     where id = m.id;
    v_off := v_off + 1;
  end loop;

  delete from public.dynamics_members_seen where not (contact_id = any(v_ids));
  return jsonb_build_object('switched_off', v_off);
end;
$$;
revoke all on function public.dynamics_members_close(uuid, text[]) from public, anon, authenticated;
grant execute on function public.dynamics_members_close(uuid, text[]) to service_role;


-- -----------------------------------------------------------------------------
-- 6. Attendance: matched by the delegate's contact first
-- -----------------------------------------------------------------------------
alter table public.dynamics_attendance add column if not exists contact_id text;
create index if not exists dynamics_attendance_contact on public.dynamics_attendance (contact_id) where contact_id is not null;
alter table public.dynamics_attendance drop constraint if exists dynamics_attendance_matched_by_check;
alter table public.dynamics_attendance add constraint dynamics_attendance_matched_by_check
  check (matched_by in ('email', 'link', 'office', 'contact'));

-- dynamics_decide, restated from 0049 with the contact first.
create or replace function app.dynamics_decide(p_row uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  a       public.dynamics_attendance;
  s       public.dynamics_sessions;
  c       public.dynamics_courses;
  w       record;
  v_mem   uuid;
  v_by    text;
  v_entry uuid;
  v_out   text;
begin
  select * into a from public.dynamics_attendance where id = p_row for update;
  select * into s from public.dynamics_sessions where id = a.session_id;

  if a.matched_by = 'office' then
    v_mem := a.member_id; v_by := 'office';
  elsif a.outcome = 'not_member' and a.decided_by is not null and a.email is null and a.email2 is null then
    return 'not_member';
  elsif a.contact_id is not null and exists (
          select 1 from public.people p join public.members m on m.person_id = p.id
           where p.dynamics_contact_id = a.contact_id) then
    -- 0054: the same contact in Dynamics as on the website. Exact, and first.
    select m.id into v_mem from public.people p join public.members m on m.person_id = p.id
     where p.dynamics_contact_id = a.contact_id order by m.is_active desc, m.joined_on desc limit 1;
    v_by := 'contact';
  else
    select * into w from app.feed_who(array[a.email, a.email2]);
    if w.outcome <> 'ok' then
      update public.dynamics_attendance
         set member_id = w.member_id, matched_by = w.matched_by, outcome = w.outcome
       where id = a.id;
      return w.outcome;
    end if;
    v_mem := w.member_id; v_by := w.matched_by;
  end if;

  if s.course_id is not null then
    select * into c from public.dynamics_courses where id = s.course_id;
  end if;
  if not exists (select 1 from public.members where id = v_mem and is_active) then
    v_out := 'not_current';
  elsif a.entry_id is not null and exists (
          select 1 from public.cpd_entries where id = a.entry_id and status <> 'rejected') then
    v_out := 'awarded';
  elsif s.held_on < app.cpd_feeds_from() then
    v_out := 'before_scheme';
  elsif c.id is not null and c.counts is null then
    v_out := 'course_waiting';
  elsif c.id is not null and not c.counts then
    v_out := 'course_not_counted';
  else
    v_entry := app.award_cpd(v_mem, s.activity_type_id, s.points, s.title, s.held_on,
                             s.id, a.id, s.event_key,
                             case when s.feed = 'arca_training'
                                  then 'ARCA''s training records show you completed it.'
                                  else 'ARCA''s records show you were there.' end);
    v_out := case when v_entry is null then 'already_counted' else 'awarded' end;
  end if;

  update public.dynamics_attendance
     set member_id = v_mem, matched_by = v_by, outcome = v_out,
         entry_id = coalesce(v_entry, entry_id)
   where id = a.id;
  return v_out;
end;
$$;
revoke all on function app.dynamics_decide(uuid) from public;

-- dynamics_record, restated from 0053: the contact is read and kept.
create or replace function public.dynamics_record(p_run uuid, p_feed text, p_meta jsonb, p_rows jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  rn       public.dynamics_runs;
  f        public.dynamics_feeds;
  t        public.cpd_activity_types;
  r        jsonb;
  v_id     text;
  v_email  text;
  v_email2 text;
  v_name   text;
  v_event  text;
  v_code   text;
  v_on     date;
  v_ref    text;
  v_title  text;
  v_key    text;
  v_course uuid;
  v_sess   uuid;
  v_row    uuid;
  v_old    public.dynamics_attendance;
  v_read   int := 0;
  v_bad    int := 0;
  v_touch  uuid[] := '{}';
  v_all    uuid[] := '{}';
  v_skip   int := 0;
  v_contact text;
  w        record;
  v_counts jsonb;
begin
  select * into rn from public.dynamics_runs where id = p_run;
  if rn.id is null or rn.status <> 'running' or rn.started_at < now() - interval '20 minutes' then
    raise exception 'That sync is not running.' using errcode = '42501';
  end if;
  select * into f from public.dynamics_feeds where code = p_feed;
  if f.code is null or not f.active then
    raise exception 'There is no such feed, or it is paused.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'The rows from Dynamics are not in the expected shape.' using errcode = '22023';
  end if;

  update public.dynamics_feeds
     set seen_entity = left(p_meta ->> 'entity', 100),
         seen_fields = coalesce((select jsonb_agg(distinct x order by x)
                                   from jsonb_array_elements_text(coalesce(p_meta -> 'fields', '[]'::jsonb)) x
                                  where x ~ '^[A-Za-z_][A-Za-z0-9_.]{0,99}$'), '[]'::jsonb),
         last_run_at = now()
   where code = f.code;

  if not app.dynamics_feed_ready(f) then
    update public.dynamics_feeds
       set last_result = jsonb_build_object('read', jsonb_array_length(p_rows), 'waiting', 'the columns are not named yet')
     where code = f.code;
    return jsonb_build_object('feed', f.code, 'read', jsonb_array_length(p_rows), 'ready', false);
  end if;

  select * into t from public.cpd_activity_types where code = f.activity_code;
  if t.id is null then
    raise exception 'The activity % is missing.', f.activity_code using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_read := v_read + 1;
    v_id     := nullif(btrim(coalesce(r ->> '_ami_id', '')), '');
    v_email  := lower(btrim(coalesce(app.dyn_text(r, f.email_field), '')));
    v_email  := case when v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email end;
    v_email2 := lower(btrim(coalesce(app.dyn_text(r, f.email2_field), '')));
    v_email2 := case when v_email2 ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email2 end;
    -- One address held twice is one address. And the first column empty with
    -- the second filled is the second, so the queue always shows an address.
    if v_email2 = v_email then v_email2 := null; end if;
    if v_email is null then v_email := v_email2; v_email2 := null; end if;
    v_contact := lower(nullif(btrim(coalesce(r ->> app.dyn_key(r, f.contact_field), '')), ''));
    v_name  := app.dyn_text(r, f.name_field);
    v_event := app.dyn_text(r, f.event_field);
    v_code  := app.dyn_text(r, f.code_field);
    v_on    := app.dyn_date(r, f.date_field);
    if v_id is null or v_on is null or (f.code <> 'arca_agm' and v_event is null) then
      v_bad := v_bad + 1;
      continue;
    end if;

    v_course := null;
    if f.code = 'arca_training' then
      insert into public.dynamics_courses (name) values (v_event)
      on conflict (name_key) do nothing;
      select id into v_course from public.dynamics_courses
       where name_key = lower(regexp_replace(btrim(v_event), '\s+', ' ', 'g'));
    end if;

    if f.code = 'arca_agm' then
      v_ref   := 'agm|' || v_on;
      v_title := 'ARCA AGM ' || extract(year from v_on);
      v_key   := 'arca-agm-' || v_on;
    else
      v_ref   := lower(coalesce(v_code, v_event)) || '|' || v_on;
      v_title := v_event;
      v_key   := case when f.code = 'arca_training' then 'arca-training-' else 'regional-meeting-' end
                 || v_on || '-' || app.dyn_slug(coalesce(v_code, v_event))
                 || '-' || left(md5(v_ref), 6);
    end if;

    insert into public.dynamics_sessions (feed, ref, title, held_on, activity_type_id, points, event_key, course_id)
    values (f.code, v_ref, v_title, v_on, t.id, coalesce(t.points, t.points_min), v_key, v_course)
    on conflict (feed, ref) do nothing;
    select id into v_sess from public.dynamics_sessions where feed = f.code and ref = v_ref;

    select * into v_old from public.dynamics_attendance where feed = f.code and dynamics_id = v_id;

    -- Kept only if it can be about a member: an email that matches, or a name
    -- like a current member's. Anybody else is not stored (0053). A row the
    -- office has already decided about is always kept.
    if v_old.id is null or (v_old.matched_by is distinct from 'office' and v_old.decided_by is null
                            and v_old.outcome <> 'awarded') then
      select * into w from app.feed_who(array[v_email, v_email2]);
      -- 0054: the delegate's contact, when the view carries it, decides first.
      -- A contact on the website, or one Dynamics says is an AMI member, is
      -- always kept.
      if w.outcome in ('unmatched', 'no_email') and cardinality(app.dyn_name_candidates(v_name)) = 0
         and not (v_contact is not null and (
               exists (select 1 from public.people p where p.dynamics_contact_id = v_contact)
            or exists (select 1 from public.dynamics_members_seen s where s.contact_id = v_contact))) then
        if v_old.id is not null then
          delete from public.dynamics_attendance where id = v_old.id;
        end if;
        v_skip := v_skip + 1;
        continue;
      end if;
    end if;
    if v_old.id is null then
      insert into public.dynamics_attendance (feed, dynamics_id, session_id, email, email2, name, raw, contact_id)
      values (f.code, v_id, v_sess, v_email, v_email2, v_name, r, v_contact)
      returning id into v_row;
      v_touch := v_touch || v_row;
      v_all := v_all || v_row;
    else
      v_all := v_all || v_old.id;
      if v_old.raw is distinct from r or v_old.email2 is distinct from v_email2
         or v_old.contact_id is distinct from v_contact then
        update public.dynamics_attendance
           set raw = r,
               email  = case when outcome = 'awarded' then email  else v_email  end,
               email2 = case when outcome = 'awarded' then email2 else v_email2 end,
               name = v_name,
               contact_id = case when outcome = 'awarded' then contact_id else v_contact end,
               session_id = case when outcome = 'awarded' then session_id else v_sess end
         where id = v_old.id;
      end if;
      if v_old.outcome <> 'awarded'
         and (v_old.email is distinct from v_email or v_old.email2 is distinct from v_email2
              or v_old.contact_id is distinct from v_contact
              or v_old.session_id <> v_sess
              or v_old.outcome in ('unmatched', 'not_current', 'course_waiting', 'before_scheme')) then
        v_touch := v_touch || v_old.id;
      end if;
    end if;
  end loop;

  perform app.dynamics_decide(x) from unnest(v_touch) x;

  select jsonb_object_agg(outcome, n) into v_counts
    from (select a.outcome, count(*) as n from public.dynamics_attendance a
           where a.id = any(v_all) group by a.outcome) c;

  update public.dynamics_feeds
     set last_result = jsonb_build_object('read', v_read, 'unreadable', v_bad,
                                          'decided', coalesce(v_counts, '{}'::jsonb) || jsonb_build_object('not_kept', v_skip))
   where code = f.code;

  return jsonb_build_object('feed', f.code, 'ready', true, 'read', v_read, 'unreadable', v_bad,
                            'decided', coalesce(v_counts, '{}'::jsonb) || jsonb_build_object('not_kept', v_skip));
end;
$$;
revoke all on function public.dynamics_record(uuid, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.dynamics_record(uuid, text, jsonb, jsonb) to service_role;

-- -----------------------------------------------------------------------------
-- 7. What the admin app reads
-- -----------------------------------------------------------------------------
create or replace view public.admin_cpd_feed_queue
with (security_invoker = true) as
  select a.id, 'Zoom'::text as source, a.session_id, s.title as session, s.held_on,
         s.min_percent, s.counted_minutes,
         a.email, a.name, a.minutes, a.percent, a.outcome, a.matched_by, a.decided_at,
         a.updated_at,
         m.membership_number, p.given_name, p.family_name,
         'zoom'::text as feed, null::text as email2, null::text as possible
    from public.zoom_attendance a
    join public.zoom_sessions s on s.id = a.session_id
    left join public.members m on m.id = a.member_id
    left join public.people p on p.id = m.person_id
  union all
  select a.id, 'ARCA records'::text, a.session_id, s.title, s.held_on,
         null::integer, null::integer,
         a.email, a.name, null::integer, null::integer, a.outcome, a.matched_by, a.decided_at,
         a.updated_at,
         m.membership_number, p.given_name, p.family_name,
         a.feed, a.email2,
         case when a.outcome in ('unmatched', 'no_email') then
           coalesce((select 'An AMI member in Dynamics with no website record yet: '
                            || coalesce(ds.given_name || ' ', '') || coalesce(ds.family_name, '')
                       from public.dynamics_members_seen ds
                      where ds.contact_id = a.contact_id and ds.person_id is null),
                    app.dyn_name_candidates_text(a.name)) end
    from public.dynamics_attendance a
    join public.dynamics_sessions s on s.id = a.session_id
    left join public.members m on m.id = a.member_id
    left join public.people p on p.id = m.person_id;
revoke all on public.admin_cpd_feed_queue from public, anon;
grant select on public.admin_cpd_feed_queue to authenticated;

create or replace view public.admin_dynamics_member_check
with (security_invoker = true) as
  select 'd:' || s.contact_id as id, 'dynamics_only'::text as kind,
         coalesce(s.given_name || ' ', '') || coalesce(s.family_name, '') as name,
         s.email, s.email2, s.category, null::text as membership_number,
         coalesce(s.problem, 'Not linked yet.') as note, s.updated_at
    from public.dynamics_members_seen s
   where s.person_id is null or s.problem is not null
  union all
  select 'w:' || mm.id, 'website_only',
         p.given_name || ' ' || p.family_name, p.email, p.alt_email, g.name, mm.membership_number,
         'An active member on the website who is not an AMI member in Dynamics, or whose emails there do not match.',
         mm.updated_at
    from public.members mm
    join public.people p on p.id = mm.person_id
    join public.membership_grades g on g.id = mm.grade_id
   where mm.is_active and p.dynamics_contact_id is null
  union all
  select 'c:' || c.category_key, 'category', c.category, null, null, c.category, null,
         case when c.grade_id is null then 'Not mapped to a website grade yet.'
              else 'Mapped to ' || g.name || '.' end,
         coalesce(c.decided_at, c.first_seen)
    from public.dynamics_grade_map c
    left join public.membership_grades g on g.id = c.grade_id;
revoke all on public.admin_dynamics_member_check from public, anon;
grant select on public.admin_dynamics_member_check to authenticated;
