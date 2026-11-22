-- =============================================================================
-- 0013  Bootstrap
--
-- The ONLY things seeded by a migration are the six role codes, because the
-- helper functions in 0003 name them, and one email address so that somebody can
-- get into the system in the first place.
--
-- Everything else is configuration and is set from the backend: membership
-- grades, the CPD requirement, CPD activity types, forum categories, the banned
-- word list, the fee for each grade, and the rotating hero statements. None of
-- it is written into a migration, because a value in a migration can only be
-- changed by a developer, and none of these should ever need one.
--
-- A suggested starting set for each list is in seeds/optional_starting_lists.sql.
-- It is optional, it is not run automatically, and it is a convenience rather
-- than a decision.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The role vocabulary
-- -----------------------------------------------------------------------------
-- These six codes appear inside app.is_staff(), app.is_membership_staff(),
-- app.is_editor() and app.is_moderator(), so they are structural rather than
-- configuration. Adding a seventh role means changing a function as well as a
-- row, which is why the list is here and everything else is not.
-- FORCE row level security binds the table OWNER as well, and only a superuser
-- or a role holding BYPASSRLS escapes it. The role running a migration on a
-- hosted Supabase project is neither, so a plain insert here is refused by the
-- protection this schema depends on. Forcing is lifted for the length of the
-- insert and put back immediately.
alter table public.app_roles no force row level security;

insert into public.app_roles (code, name, description, sort_order) values
  ('super_user',    'Super user',
   'Grants and removes roles, and holds every other right. The only role that can create another super user.', 1),
  ('administrator', 'Administrator',
   'Everything except granting roles.', 2),
  ('membership',    'Membership staff',
   'Member records, the active switch, membership years, CPD review and awards.', 3),
  ('editor',        'Editor',
   'Creates and publishes content. No member records and no system settings.', 4),
  ('moderator',     'Moderator',
   'Forum moderation, held posts and the banned word list.', 5),
  ('member',        'Member',
   'Own profile, own CPD record, own card, forum participation.', 6)
on conflict (code) do nothing;

alter table public.app_roles force row level security;

-- -----------------------------------------------------------------------------
-- Getting the first super user in
-- -----------------------------------------------------------------------------
-- A role can only be granted by a super user, so the first one cannot be granted
-- by anybody. This table is the way in, and it is also the way BACK in if the
-- only super user ever loses their account.
--
-- An email listed here is granted super_user automatically the first time a
-- person row is created for it. Nothing else happens: the row is not created for
-- them, and listing an address grants nothing until that person actually signs in.
create table public.bootstrap_super_users (
  email      text primary key,
  note       text,
  added_at   timestamptz not null default now(),
  applied_at timestamptz
);

-- The first super user goes in here BEFORE the table is protected, so there is
-- nothing to lift and put back.
insert into public.bootstrap_super_users (email, note) values
  ('steve.sadley@arca.org.uk', 'First super user. Sets up everything else from the backend.')
on conflict (email) do nothing;

alter table public.bootstrap_super_users enable row level security;
-- applied_at is stamped by app.apply_bootstrap_super_user(), so not forced
alter table public.bootstrap_super_users no force row level security;
grant select, insert, delete on public.bootstrap_super_users to authenticated;

-- Readable and writable by a super user only. If it were readable by anybody
-- else it would be a published list of the accounts worth attacking.
create policy bootstrap_select_super on public.bootstrap_super_users
  for select to authenticated using ((select app.is_super_user()));
create policy bootstrap_insert_super on public.bootstrap_super_users
  for insert to authenticated with check ((select app.is_super_user()));
create policy bootstrap_delete_super on public.bootstrap_super_users
  for delete to authenticated using ((select app.is_super_user()));

comment on table public.bootstrap_super_users is
  'The way the first super user gets in, and the way back in if the only super '
  'user loses their account. Listing an address grants nothing on its own: the '
  'grant happens when that person first signs in and a people row is created.';

create or replace function app.apply_bootstrap_super_user() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.bootstrap_super_users b
              where lower(b.email) = lower(new.email)) then

    insert into public.role_grants (person_id, role_code, granted_by)
    values (new.id, 'super_user', new.id)
    on conflict (person_id, role_code) do nothing;

    insert into public.role_grants (person_id, role_code, granted_by)
    values (new.id, 'administrator', new.id)
    on conflict (person_id, role_code) do nothing;

    update public.bootstrap_super_users
       set applied_at = now()
     where lower(email) = lower(new.email) and applied_at is null;
  end if;
  return new;
end;
$$;

create trigger people_bootstrap_super_user
  after insert on public.people
  for each row execute function app.apply_bootstrap_super_user();

comment on function app.apply_bootstrap_super_user() is
  'Grants super_user and administrator to a person whose email is listed in '
  'bootstrap_super_users, the first time their people row is created. This is '
  'the only route by which a role is granted without a super user doing it, and '
  'it is written to the audit log like any other grant.';

-- -----------------------------------------------------------------------------
-- A NOTE ON HAVING ONLY ONE. One super user means one person who can grant
-- roles, and one person whose lost phone or absence stops anybody being granted
-- anything. The trigger in 0002 stops a super user removing their own role, so
-- the common accident is covered, and this table is the recovery route for the
-- uncommon one: add an address here, have that person sign in, and they come
-- back with super_user. Adding a second named super user is still the safer
-- position and remains a decision for Steve rather than a default in the schema.
