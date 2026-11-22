-- =============================================================================
-- 0015  The policies the configuration screens need
--
-- Unseeding the reference data left three tables that can be read and changed
-- but never added to, which on an empty project means they can never be filled
-- in at all. Nobody could create the first membership grade.
--
-- This is the cost of "no policy means no access" and it is the right cost: the
-- gap was silent until something tried to use it, rather than being a hole
-- somebody found later.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- membership_grades
-- -----------------------------------------------------------------------------
-- A grade is close to structural. It carries is_assessed, which every public
-- surface reads to distinguish an assessed member from an unassessed one, and
-- requires_cpd, which decides whether somebody is measured at all. Creating one
-- is therefore a super user act rather than an ordinary office one.
grant insert, delete on public.membership_grades to authenticated;

create policy grades_insert_super on public.membership_grades
  for insert to authenticated
  with check ((select app.is_super_user()));

create policy grades_delete_super on public.membership_grades
  for delete to authenticated
  using ((select app.is_super_user()));

comment on policy grades_delete_super on public.membership_grades is
  'A grade with members on it cannot be deleted anyway, because members.grade_id '
  'references it. That refusal is the database protecting a member record, and '
  'it is the right answer: retire a grade by removing it from the register '
  'rather than by deleting it.';

-- -----------------------------------------------------------------------------
-- cpd_requirements
-- -----------------------------------------------------------------------------
-- One row per year per grade, and a new one is needed every January. Membership
-- staff, not just a super user, or the year turns and nobody can set it.
grant insert, delete on public.cpd_requirements to authenticated;

create policy cpd_req_insert_staff on public.cpd_requirements
  for insert to authenticated
  with check ((select app.is_membership_staff()));

create policy cpd_req_delete_staff on public.cpd_requirements
  for delete to authenticated
  using ((select app.is_membership_staff()));

-- -----------------------------------------------------------------------------
-- cpd_activity_types
-- -----------------------------------------------------------------------------
-- Deleting one is possible only while nothing has been logged against it, which
-- the foreign key enforces. After that the honest route is to set active false,
-- so the type stops appearing on the form and every entry already recorded
-- against it still says what it was.
grant delete on public.cpd_activity_types to authenticated;

create policy cpd_types_delete_super on public.cpd_activity_types
  for delete to authenticated
  using ((select app.is_super_user()));

-- -----------------------------------------------------------------------------
-- forum_categories
-- -----------------------------------------------------------------------------
-- Same shape. A category holding discussions cannot be deleted, and should not
-- be: set active false and the discussions survive.
grant delete on public.forum_categories to authenticated;

create policy forum_cat_delete_super on public.forum_categories
  for delete to authenticated
  using ((select app.is_super_user()));

-- -----------------------------------------------------------------------------
-- What is deliberately still missing
-- -----------------------------------------------------------------------------
-- app_roles has no insert, update or delete policy, and gets none. The six role
-- codes are named inside app.is_staff(), app.is_membership_staff(),
-- app.is_editor() and app.is_moderator(), so a seventh added from a screen would
-- be a role that grants nothing and looks like it should. Adding a role is a
-- migration, on purpose.
