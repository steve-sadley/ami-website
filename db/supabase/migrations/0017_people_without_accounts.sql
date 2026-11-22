-- =============================================================================
-- 0017  A person is not a login
--
-- people.id WAS the Supabase auth user id, which quietly made an account a
-- condition of existing. That is wrong in two ways that both matter.
--
-- The office approves an application and creates a member. That member has no
-- account yet, and under the old shape could not be created at all. And most of
-- the 214 people on the register will never sign in: they are members of an
-- institute, not users of a website, and the register has to be able to say so.
--
-- So people.id is now its own identifier, and the account is a nullable link
-- beside it. Everything a policy does still reads the same, because the helper
-- functions absorb the change.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The change
-- -----------------------------------------------------------------------------
alter table public.people
  drop constraint people_id_fkey;

alter table public.people
  alter column id set default gen_random_uuid(),
  add column auth_user_id uuid unique references auth.users(id) on delete set null,
  add column invited_at    timestamptz,
  add column first_seen_at timestamptz;

-- Everyone who exists today got here by signing in, so their id IS their account.
update public.people set auth_user_id = id where auth_user_id is null;

create index people_auth_user on public.people (auth_user_id) where auth_user_id is not null;

comment on column public.people.auth_user_id is
  'The sign in account, if they have one. Null is normal and is not a problem to '
  'be fixed: a member who never uses the website is still a member, and the '
  'register, the card and every document work without it.';
comment on column public.people.invited_at is
  'When the office sent them an invitation to create an account. Null means they '
  'have never been asked.';

-- -----------------------------------------------------------------------------
-- people joins the not forced list, and it has to
-- -----------------------------------------------------------------------------
-- app.person_id() now READS people to map an account to a person. It is security
-- definer, so it runs as the table owner, and forcing binds the owner. The policies
-- on people call app.person_id(), which reads people, which invokes the policies:
-- Postgres stops that with "stack depth limit exceeded" and nothing works at all.
--
-- Lifting forcing on people breaks the loop and changes nothing for a client. anon
-- holds no privileges here, and a signed in member still sees only their own row,
-- because the policies are unchanged and forcing never applied to them. It is the
-- ninth table on the list in 0005 and it is there for the same reason as the rest:
-- this schema has to be able to read its own tables.
alter table public.people no force row level security;

-- -----------------------------------------------------------------------------
-- The helpers absorb it
-- -----------------------------------------------------------------------------
-- Every policy says things like "id = app.person_id()" and none of them change.
create or replace function app.person_id() returns uuid
language sql stable security definer set search_path = ''
as $$
  select p.id from public.people p where p.auth_user_id = auth.uid();
$$;

create or replace function app.member_id() returns uuid
language sql stable security definer set search_path = ''
as $$
  select m.id from public.members m
    join public.people p on p.id = m.person_id
   where p.auth_user_id = auth.uid();
$$;

create or replace function app.is_active_member() returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select m.is_active from public.members m
                     join public.people p on p.id = m.person_id
                    where p.auth_user_id = auth.uid()), false);
$$;

-- The role helpers looked up role_grants by auth.uid(), which worked only while
-- the two identifiers happened to be the same value.
create or replace function app.has_role(p_role text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_grants g
                   join public.people p on p.id = g.person_id
                  where p.auth_user_id = auth.uid() and g.role_code = p_role);
$$;

create or replace function app.is_staff() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_grants g
                   join public.people p on p.id = g.person_id
                  where p.auth_user_id = auth.uid()
                    and g.role_code in ('super_user','administrator','editor','membership','moderator'));
$$;

create or replace function app.is_super_user() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_grants g
                   join public.people p on p.id = g.person_id
                  where p.auth_user_id = auth.uid() and g.role_code = 'super_user');
$$;

create or replace function app.is_membership_staff() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_grants g
                   join public.people p on p.id = g.person_id
                  where p.auth_user_id = auth.uid()
                    and g.role_code in ('super_user','administrator','membership'));
$$;

create or replace function app.is_editor() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_grants g
                   join public.people p on p.id = g.person_id
                  where p.auth_user_id = auth.uid()
                    and g.role_code in ('super_user','administrator','editor'));
$$;

create or replace function app.is_moderator() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_grants g
                   join public.people p on p.id = g.person_id
                  where p.auth_user_id = auth.uid()
                    and g.role_code in ('super_user','administrator','moderator'));
$$;

-- A super user removing their own super user role: same rule, new lookup.
create or replace function app.protect_super_user() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.role_code = 'super_user' and old.person_id = app.person_id() then
    raise exception 'A super user cannot remove their own super user role.'
      using errcode = '42501';
  end if;
  return old;
end;
$$;

-- -----------------------------------------------------------------------------
-- Linking an account to a person
-- -----------------------------------------------------------------------------
-- Somebody the office created months ago signs in for the first time. This joins
-- the account to the record already waiting for them.
--
-- It matches on email, which is safe because Supabase has verified that the
-- person controls that address before this can be called. It refuses to touch a
-- person who is already linked to a different account, so an address changing
-- hands cannot inherit a membership.
create or replace function app.link_account() returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_email text;
  v_person uuid;
begin
  select email into v_email from auth.users where id = auth.uid();
  if v_email is null then
    raise exception 'Not signed in.' using errcode = '42501';
  end if;

  -- already linked
  select id into v_person from public.people where auth_user_id = auth.uid();
  if v_person is not null then
    return v_person;
  end if;

  select id into v_person
    from public.people
   where lower(email) = lower(v_email) and auth_user_id is null
   limit 1;

  if v_person is null then
    return null;   -- no record waiting: the caller decides what that means
  end if;

  update public.people
     set auth_user_id = auth.uid(),
         first_seen_at = coalesce(first_seen_at, now())
   where id = v_person;

  return v_person;
end;
$$;

revoke all on function app.link_account() from public;
grant execute on function app.link_account() to authenticated, service_role;

comment on function app.link_account() is
  'Joins a newly signed in account to the person record already waiting for it, '
  'matching on the email address Supabase has verified. Returns null when there '
  'is no record, which is not an error: it is somebody who has signed up without '
  'being a member.';

-- The bootstrap trigger fires on a people row appearing, which now happens when
-- the office creates somebody rather than when they sign in. Grant on link too,
-- or the first super user of a fresh project can never get in.
create or replace function app.apply_bootstrap_super_user() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.auth_user_id is not null
     and exists (select 1 from public.bootstrap_super_users b
                  where lower(b.email) = lower(new.email)) then

    insert into public.role_grants (person_id, role_code, granted_by)
    values (new.id, 'super_user', new.id) on conflict do nothing;
    insert into public.role_grants (person_id, role_code, granted_by)
    values (new.id, 'administrator', new.id) on conflict do nothing;

    update public.bootstrap_super_users
       set applied_at = now()
     where lower(email) = lower(new.email) and applied_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists people_bootstrap_super_user on public.people;
create trigger people_bootstrap_super_user
  after insert or update of auth_user_id on public.people
  for each row execute function app.apply_bootstrap_super_user();

-- -----------------------------------------------------------------------------
-- Approval no longer needs an account
-- -----------------------------------------------------------------------------
drop function if exists app.approve_application(uuid, uuid, text, date, text);

create or replace function app.approve_application(
  p_application_id    uuid,
  p_membership_number text,
  p_joined_on         date default current_date,
  p_note              text default null
) returns uuid
language plpgsql
-- SECURITY INVOKER on purpose: it runs as the member of staff who called it, so
-- every row it writes is written under their own policies and appears in the
-- audit log under their name.
set search_path = ''
as $$
declare
  a public.membership_applications%rowtype;
  v_person_id uuid;
  v_member_id uuid;
begin
  if not app.is_membership_staff() then
    raise exception 'Only membership staff may approve an application.' using errcode = '42501';
  end if;

  select * into a from public.membership_applications where id = p_application_id;
  if not found then
    raise exception 'Application % not found.', p_application_id;
  end if;
  if a.status not in ('submitted', 'under_review') then
    raise exception 'Application % is %, so it cannot be approved.', a.reference, a.status;
  end if;

  -- reuse a person record if this address is already known, otherwise create one.
  -- No account is created and none is needed.
  select id into v_person_id from public.people where lower(email) = lower(a.email) limit 1;
  if v_person_id is null then
    insert into public.people (given_name, family_name, email, mobile)
    values (a.given_name, a.family_name, a.email, a.telephone)
    returning id into v_person_id;
  end if;

  insert into public.members
    (person_id, membership_number, grade_id, employer_id, current_job_title,
     joined_on, is_active, status)
  values
    (v_person_id, p_membership_number, a.grade_id, a.employer_id, a.job_title,
     p_joined_on, false, 'applicant')
  returning id into v_member_id;

  insert into public.member_preferences (member_id) values (v_member_id);

  update public.membership_applications
     set status = 'approved', decided_at = now(), decided_by = app.person_id(),
         decision_note = p_note, member_id = v_member_id, person_id = v_person_id
   where id = p_application_id;

  insert into public.application_events (application_id, from_status, to_status, actor_id, note)
  values (p_application_id, a.status, 'approved', app.person_id(), p_note);

  return v_member_id;
end;
$$;

revoke all on function app.approve_application(uuid, text, date, text) from public;
grant execute on function app.approve_application(uuid, text, date, text)
  to authenticated, service_role;

comment on function app.approve_application(uuid, text, date, text) is
  'Creates the person and member records from an approved application. No account '
  'is created: the member is created INACTIVE and somebody still presses the '
  'switch, and they may never sign in at all.';
