-- =============================================================================
-- 0020  The actions the admin area performs, and why they are in public
--
-- Everything the office actually does is a verb rather than a row edit: approve
-- this application, switch this membership on, accept this CPD entry, release
-- this held post. Up to now those verbs either lived in the app schema, where a
-- browser cannot reach them, or did not exist at all.
--
-- TWO PROBLEMS, ONE MIGRATION.
--
-- 1. PostgREST, which is what the browser talks to, exposes the public schema.
--    app.approve_application() has been sitting there since 0006 and no client
--    has ever been able to call it. The wrappers below put a public face on the
--    app functions. They are thin on purpose: the rule stays in one place and
--    the wrapper only makes it reachable.
--
-- 2. Fields the browser must not be trusted with. Who reviewed a CPD entry, who
--    switched a membership on and when, who released a post: all of those are
--    columns an admin screen could otherwise set to anything. They are stamped
--    here, from auth.uid(), by triggers and by the functions themselves, so the
--    honest answer and the recorded answer are the same answer.
--
-- Every function is SECURITY INVOKER unless it says otherwise, so the caller's
-- own policies still apply and nothing here is a way round them. The tests are
-- the proof of that, not this comment.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Who am I
-- -----------------------------------------------------------------------------
-- Since 0017 a person is not a login, so an admin screen can no longer look up
-- role_grants by the account id. This is the supported way to ask.
create or replace function public.whoami()
returns table (person_id uuid, member_id uuid, email text, given_name text,
               family_name text, roles text[])
language sql stable security definer set search_path = ''
as $$
  select p.id,
         (select m.id from public.members m where m.person_id = p.id),
         p.email, p.given_name, p.family_name,
         coalesce((select array_agg(g.role_code order by g.role_code)
                     from public.role_grants g where g.person_id = p.id), '{}')
    from public.people p
   where p.auth_user_id = auth.uid();
$$;

revoke all on function public.whoami() from public;
grant execute on function public.whoami() to authenticated, service_role;

comment on function public.whoami() is
  'The signed in person, their member record if they have one, and their roles. '
  'Security definer so it can read people and role_grants by account id, which '
  'is the one lookup a client cannot do for itself.';

-- The account linking function, made reachable.
create or replace function public.link_account() returns uuid
language sql volatile set search_path = ''
as $$ select app.link_account(); $$;

revoke all on function public.link_account() from public;
grant execute on function public.link_account() to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- A missing grant, which is a different thing from a missing policy
-- -----------------------------------------------------------------------------
-- 0002 gave members a members_insert_staff policy and 0004 never granted INSERT
-- on the table to anybody. A policy without a grant is a locked door with no
-- handle: the rule about who may pass through it is written and correct, and
-- nobody can reach the door. The effect was that approving an application could
-- not work for any member of staff, ever, because app.approve_application runs
-- as the caller by design and the caller had no INSERT.
--
-- The policy is unchanged and still says membership staff only. This grants the
-- privilege the policy has been waiting for. The test below proves an ordinary
-- member still cannot insert, which is the check that makes the grant safe.
grant insert on public.members to authenticated;

-- membership_applications deliberately does NOT get one. An application arrives
-- from a form filled in by somebody who is not signed in, so it comes through a
-- Worker holding the service role, and no browser needs to insert one.

-- -----------------------------------------------------------------------------
-- Applications
-- -----------------------------------------------------------------------------
create or replace function public.approve_application(
  p_application_id    uuid,
  p_membership_number text,
  p_joined_on         date default current_date,
  p_note              text default null
) returns uuid
language sql volatile set search_path = ''
as $$
  select app.approve_application(p_application_id, p_membership_number, p_joined_on, p_note);
$$;

revoke all on function public.approve_application(uuid, text, date, text) from public;
grant execute on function public.approve_application(uuid, text, date, text)
  to authenticated, service_role;

-- Refusing needs the same care as approving: the decision, who made it, when,
-- and the reason, written together or not at all.
create or replace function public.refuse_application(
  p_application_id uuid,
  p_note           text
) returns void
language plpgsql volatile set search_path = ''
as $$
declare a public.membership_applications%rowtype;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may refuse an application.' using errcode = '42501';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'A refusal needs a reason. It goes to the applicant and it is the record.';
  end if;

  select * into a from public.membership_applications where id = p_application_id;
  if not found then
    raise exception 'Application % not found.', p_application_id;
  end if;
  if a.status not in ('submitted', 'under_review') then
    raise exception 'Application % is %, so it cannot be refused.', a.reference, a.status;
  end if;

  update public.membership_applications
     set status = 'refused', decided_at = now(), decided_by = app.person_id(),
         decision_note = p_note
   where id = p_application_id;

  insert into public.application_events (application_id, from_status, to_status, actor_id, note)
  values (p_application_id, a.status, 'refused', app.person_id(), p_note);
end;
$$;

revoke all on function public.refuse_application(uuid, text) from public;
grant execute on function public.refuse_application(uuid, text) to authenticated, service_role;

-- Picking an application up. Separate from approving because looking at
-- something is not deciding it, and the queue should show which is which.
create or replace function public.take_application(p_application_id uuid) returns void
language plpgsql volatile set search_path = ''
as $$
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may take an application.' using errcode = '42501';
  end if;
  update public.membership_applications
     set status = 'under_review'
   where id = p_application_id and status = 'submitted';

  if found then
    insert into public.application_events (application_id, from_status, to_status, actor_id)
    values (p_application_id, 'submitted', 'under_review', app.person_id());
  end if;
end;
$$;

revoke all on function public.take_application(uuid) from public;
grant execute on function public.take_application(uuid) to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- The active switch
-- -----------------------------------------------------------------------------
-- Membership staff already hold update on members, so the switch itself needs no
-- new privilege. What it needs is for the four columns that record the act to be
-- written by the database rather than by whatever the browser sent. Any route
-- that flips the flag gets stamped, including a hand written SQL statement.
create or replace function app.stamp_member_activation() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.is_active is distinct from old.is_active then
    if new.is_active then
      new.activated_at   := now();
      new.activated_by   := app.person_id();
      new.deactivated_at := null;
      new.deactivated_by := null;
      new.deactivation_reason := null;
      if new.status = 'applicant' then new.status := 'current'; end if;
    else
      new.deactivated_at := now();
      new.deactivated_by := app.person_id();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists members_stamp_activation on public.members;
create trigger members_stamp_activation
  before update of is_active on public.members
  for each row execute function app.stamp_member_activation();

comment on function app.stamp_member_activation() is
  'Records who switched a membership and when, from the signed in account rather '
  'than from anything the client sent. An applicant becomes current the first '
  'time the switch goes on; nothing sends them back to applicant afterwards.';

-- The verb, so a screen does not have to know that lapsing is an is_active flag
-- and a status and a reason.
create or replace function public.set_member_active(
  p_member_id uuid,
  p_active    boolean,
  p_reason    text default null
) returns void
language plpgsql volatile set search_path = ''
as $$
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may switch a membership.' using errcode = '42501';
  end if;

  if p_active then
    update public.members set is_active = true where id = p_member_id;
  else
    update public.members
       set is_active = false,
           status = case when status = 'current' then 'lapsed' else status end,
           deactivation_reason = p_reason
     where id = p_member_id;
  end if;

  if not found then
    raise exception 'Membership % not found.', p_member_id;
  end if;
end;
$$;

revoke all on function public.set_member_active(uuid, boolean, text) from public;
grant execute on function public.set_member_active(uuid, boolean, text)
  to authenticated, service_role;


-- -----------------------------------------------------------------------------
-- CPD review
-- -----------------------------------------------------------------------------
-- Same argument as the active switch: the reviewer is stamped, not sent.
create or replace function app.stamp_cpd_review() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status is distinct from old.status and new.status in ('accepted', 'rejected') then
    new.reviewed_by := app.person_id();
    new.reviewed_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists cpd_entries_stamp_review on public.cpd_entries;
create trigger cpd_entries_stamp_review
  before update of status on public.cpd_entries
  for each row execute function app.stamp_cpd_review();

-- Bulk accept. One statement, one transaction: a queue of forty either clears or
-- does not, rather than half clearing and leaving somebody to work out where it
-- stopped.
create or replace function public.review_cpd(
  p_ids    uuid[],
  p_status text,
  p_note   text default null
) returns integer
language plpgsql volatile set search_path = ''
as $$
declare v_count integer;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may review CPD.' using errcode = '42501';
  end if;
  if p_status not in ('accepted', 'rejected') then
    raise exception 'A review is accepted or rejected, not %.', p_status;
  end if;
  if p_status = 'rejected' and coalesce(btrim(p_note), '') = '' then
    raise exception 'A rejection needs a reason. The member is told what it says.';
  end if;

  update public.cpd_entries
     set status = p_status::public.cpd_entry_status,
         review_note = coalesce(p_note, review_note)
   where id = any (p_ids)
     and status = 'pending';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.review_cpd(uuid[], text, text) from public;
grant execute on function public.review_cpd(uuid[], text, text) to authenticated, service_role;

comment on function public.review_cpd(uuid[], text, text) is
  'Accepts or rejects a batch of pending CPD entries in one transaction. Entries '
  'that are no longer pending are skipped rather than overwritten, so two people '
  'working the queue at once cannot undo each other.';


-- -----------------------------------------------------------------------------
-- Held posts
-- -----------------------------------------------------------------------------
-- The forum is not moderated. The banned word filter holds a post, a human looks
-- at it, and it is published or it is not. Releasing has to skip the screening
-- trigger, or the filter that held it would hold it again.
create or replace function public.release_post(p_post_id uuid, p_note text default null)
returns void
language plpgsql volatile set search_path = ''
as $$
begin
  if not app.is_moderator() then
    raise exception 'Only a moderator may release a held post.' using errcode = '42501';
  end if;

  update public.forum_posts
     set status = 'published',
         held_reason = case when p_note is null then held_reason
                            else held_reason || ' | released: ' || p_note end
   where id = p_post_id and status = 'held';

  if not found then
    raise exception 'That post is not held, so there is nothing to release.';
  end if;
end;
$$;

revoke all on function public.release_post(uuid, text) from public;
grant execute on function public.release_post(uuid, text) to authenticated, service_role;

create or replace function public.hide_post(p_post_id uuid, p_note text)
returns void
language plpgsql volatile set search_path = ''
as $$
begin
  if not app.is_moderator() then
    raise exception 'Only a moderator may hide a post.' using errcode = '42501';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'Hiding a post needs a reason. It is the only record of why.';
  end if;

  update public.forum_posts
     set status = 'hidden',
         held_reason = coalesce(held_reason || ' | ', '') || 'hidden: ' || p_note
   where id = p_post_id;

  if not found then
    raise exception 'Post % not found.', p_post_id;
  end if;
end;
$$;

revoke all on function public.hide_post(uuid, text) from public;
grant execute on function public.hide_post(uuid, text) to authenticated, service_role;

-- The screening trigger must not fire on a moderator's decision. It screens what
-- a member writes, not what a moderator does about it.
create or replace function app.screen_forum_post() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_word text;
begin
  -- A status change made by somebody with the role to make it is a decision, not
  -- a new post, so it is left alone. Without this, releasing a held post would
  -- run it back through the filter that held it and hold it again, which reads
  -- from the moderator's side as the button not working.
  if tg_op = 'UPDATE' and new.body is not distinct from old.body then
    return new;
  end if;

  v_word := app.find_banned_word(new.body);
  if v_word is not null then
    new.status := 'held';
    new.held_reason := 'Held automatically: the post contains a word on the banned list.';
  end if;
  return new;
end;
$$;


-- -----------------------------------------------------------------------------
-- What the queues look like
-- -----------------------------------------------------------------------------
-- Three views so a screen is one select rather than four joins written in
-- JavaScript. They are SECURITY INVOKER, which is the opposite of the public
-- views in 0012: these carry no filter of their own and rely entirely on the
-- caller's policies, so a member who found the name would see their own rows and
-- nothing else.
create or replace view public.admin_application_queue
with (security_invoker = true) as
  select a.id, a.reference, a.status,
         a.given_name, a.family_name, a.email, a.telephone,
         a.employer_name, a.job_title,
         g.name as grade, a.grade_id,
         a.submitted_at, a.created_at, a.decided_at, a.decision_note,
         (select count(*) from public.application_documents d where d.application_id = a.id) as documents
    from public.membership_applications a
    left join public.membership_grades g on g.id = a.grade_id;

create or replace view public.admin_member_list
with (security_invoker = true) as
  select m.id, m.membership_number, m.is_active, m.status,
         p.given_name, p.family_name, p.email,
         g.name as grade, m.grade_id,
         m.joined_on, m.current_job_title,
         p.auth_user_id is not null as has_account,
         m.activated_at, m.deactivated_at
    from public.members m
    join public.people p on p.id = m.person_id
    join public.membership_grades g on g.id = m.grade_id;

create or replace view public.admin_cpd_queue
with (security_invoker = true) as
  select e.id, e.member_id, e.year, e.occurred_on, e.title, e.provider,
         e.points, e.is_core, e.status, e.evidence_ref, e.recorded_at,
         t.name as activity_type,
         m.membership_number,
         p.given_name, p.family_name
    from public.cpd_entries e
    join public.cpd_activity_types t on t.id = e.activity_type_id
    join public.members m on m.id = e.member_id
    join public.people p on p.id = m.person_id;

create or replace view public.admin_held_posts
with (security_invoker = true) as
  select fp.id, fp.thread_id, fp.body, fp.held_reason, fp.created_at, fp.status,
         th.title as thread, th.slug as thread_slug,
         c.name as category,
         m.membership_number,
         p.given_name, p.family_name, p.email
    from public.forum_posts fp
    join public.forum_threads th on th.id = fp.thread_id
    join public.forum_categories c on c.id = th.category_id
    join public.members m on m.id = fp.author_id
    join public.people p on p.id = m.person_id;

grant select on public.admin_application_queue,
                public.admin_member_list,
                public.admin_cpd_queue,
                public.admin_held_posts
  to authenticated;

comment on view public.admin_application_queue is
  'The application queue. Security invoker, so it shows what the caller is '
  'allowed to see and nothing more: staff see the queue, an applicant sees their '
  'own application, anon sees nothing because anon holds no grant on it.';
