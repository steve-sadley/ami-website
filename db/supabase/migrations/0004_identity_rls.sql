-- =============================================================================
-- 0004  Row level security for the identity tables
--
-- Every table is ENABLED. Almost every table is also FORCED, which extends the
-- policies to the table owner as well. The handful that are enabled and not
-- forced are the ones this schema's own trigger functions have to write to, and
-- the reasoning is set out in full at the end of 0005.
--
-- Policies are per command. Nothing uses FOR ALL, so a read policy can never
-- quietly confer a write.
-- =============================================================================

alter table public.people              enable row level security;
alter table public.people              force  row level security;
alter table public.organisations       enable row level security;
alter table public.organisations       force  row level security;
alter table public.organisation_slugs  enable row level security;
alter table public.organisation_slugs  force  row level security;
alter table public.membership_grades   enable row level security;
alter table public.membership_grades   force  row level security;
alter table public.members             enable row level security;
alter table public.members             force  row level security;
alter table public.membership_years    enable row level security;
alter table public.membership_years    force  row level security;
alter table public.member_preferences  enable row level security;
alter table public.member_preferences  force  row level security;
alter table public.register_slugs      enable row level security;
alter table public.register_slugs      force  row level security;
alter table public.app_roles           enable row level security;
alter table public.app_roles           force  row level security;
alter table public.role_grants         enable row level security;
-- the first super user is granted by app.apply_bootstrap_super_user(), so not forced
alter table public.role_grants         no force row level security;

-- Grants are the outer gate; policies are the inner one. Both are needed, and
-- anon is granted nothing at all here. The public reads three views, and only
-- three views. See 0012.
grant select, insert, update on public.people     to authenticated;
grant select          on public.members            to authenticated;
grant update          on public.members            to authenticated;
grant select          on public.membership_grades  to authenticated;
grant update          on public.membership_grades  to authenticated;
grant select, insert, update on public.organisations to authenticated;
grant delete          on public.organisations       to authenticated;
grant select, insert  on public.organisation_slugs  to authenticated;
grant select, insert, update on public.membership_years to authenticated;
grant select, insert, update on public.member_preferences to authenticated;
grant select, insert  on public.register_slugs      to authenticated;
grant select          on public.app_roles           to authenticated;
grant select, insert, delete on public.role_grants  to authenticated;

-- -----------------------------------------------------------------------------
-- people
-- -----------------------------------------------------------------------------
create policy people_select_own on public.people
  for select to authenticated
  using (id = (select app.person_id()));

create policy people_update_own on public.people
  for update to authenticated
  using (id = (select app.person_id()))
  with check (id = (select app.person_id()));

create policy people_select_staff on public.people
  for select to authenticated
  using ((select app.is_staff()));

create policy people_update_staff on public.people
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

-- Membership staff create a person when they approve an application. This is
-- what lets app.approve_application() run as the member of staff calling it
-- rather than escalating to the table owner, which is the safer of the two.
create policy people_insert_staff on public.people
  for insert to authenticated
  with check ((select app.is_membership_staff()));

-- Nobody deletes a person. There is no delete policy, and no policy means no access.

-- -----------------------------------------------------------------------------
-- members
-- -----------------------------------------------------------------------------
create policy members_select_own on public.members
  for select to authenticated
  using (person_id = (select app.person_id()));

create policy members_select_staff on public.members
  for select to authenticated
  using ((select app.is_staff()));

-- The active switch, and every other change to a membership record, is
-- membership staff only. A member cannot update their own membership row at all,
-- which is why there is no members_update_own policy: everything a member may
-- change about themselves lives on people or member_preferences.
create policy members_update_staff on public.members
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

create policy members_insert_staff on public.members
  for insert to authenticated
  with check ((select app.is_membership_staff()));

-- -----------------------------------------------------------------------------
-- membership_grades and app_roles: reference data, readable by any signed in user
-- -----------------------------------------------------------------------------
create policy grades_select_all on public.membership_grades
  for select to authenticated using (true);

create policy grades_update_super on public.membership_grades
  for update to authenticated
  using ((select app.is_super_user()))
  with check ((select app.is_super_user()));

create policy roles_select_all on public.app_roles
  for select to authenticated using (true);

-- -----------------------------------------------------------------------------
-- role_grants
-- -----------------------------------------------------------------------------
-- A person may see their own roles. Only a super user may grant or remove one,
-- and the trigger in 0002 stops a super user removing their own super user role.
create policy role_grants_select_own on public.role_grants
  for select to authenticated
  using (person_id = (select app.person_id()));

create policy role_grants_select_staff on public.role_grants
  for select to authenticated
  using ((select app.is_staff()));

create policy role_grants_insert_super on public.role_grants
  for insert to authenticated
  with check ((select app.is_super_user()));

create policy role_grants_delete_super on public.role_grants
  for delete to authenticated
  using ((select app.is_super_user()));

-- -----------------------------------------------------------------------------
-- membership_years
-- -----------------------------------------------------------------------------
create policy years_select_own on public.membership_years
  for select to authenticated
  using (member_id = (select app.member_id()));

create policy years_select_staff on public.membership_years
  for select to authenticated
  using ((select app.is_staff()));

create policy years_write_staff on public.membership_years
  for insert to authenticated
  with check ((select app.is_membership_staff()));

create policy years_update_staff on public.membership_years
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

-- -----------------------------------------------------------------------------
-- member_preferences
-- -----------------------------------------------------------------------------
create policy prefs_select_own on public.member_preferences
  for select to authenticated
  using (member_id = (select app.member_id()));

create policy prefs_update_own on public.member_preferences
  for update to authenticated
  using (member_id = (select app.member_id()))
  with check (member_id = (select app.member_id()));

create policy prefs_insert_own on public.member_preferences
  for insert to authenticated
  with check (member_id = (select app.member_id()) or (select app.is_membership_staff()));

create policy prefs_select_staff on public.member_preferences
  for select to authenticated
  using ((select app.is_staff()));

-- -----------------------------------------------------------------------------
-- register_slugs and organisations
-- -----------------------------------------------------------------------------
create policy slugs_select_own on public.register_slugs
  for select to authenticated
  using (member_id = (select app.member_id()));

create policy slugs_select_staff on public.register_slugs
  for select to authenticated
  using ((select app.is_staff()));

create policy slugs_insert_staff on public.register_slugs
  for insert to authenticated
  with check ((select app.is_membership_staff()));

create policy orgs_select_all on public.organisations
  for select to authenticated using (true);

create policy orgs_write_staff on public.organisations
  for insert to authenticated with check ((select app.is_membership_staff()));

create policy orgs_update_staff on public.organisations
  for update to authenticated
  using ((select app.is_membership_staff()))
  with check ((select app.is_membership_staff()));

create policy orgs_delete_staff on public.organisations
  for delete to authenticated using ((select app.is_membership_staff()));

create policy org_slugs_select_all on public.organisation_slugs
  for select to authenticated using (true);

create policy org_slugs_insert_staff on public.organisation_slugs
  for insert to authenticated with check ((select app.is_membership_staff()));
