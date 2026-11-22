-- =============================================================================
-- 0028  A member may change their own contact details and nothing else
--
-- The profile page already offers a member exactly three fields: telephone, home
-- address and business address. Everything about the membership itself, the
-- grade, the number, the joining date and the employer, is shown and disabled,
-- and there is no members_update_own policy at all, so a member cannot write to
-- their membership row even if they try.
--
-- WHAT WAS WRONG. The `people` row was a different matter. `people_update_own`
-- from 0004 says a member may update their own row, without saying which parts
-- of it. The page only offers three fields and `update_my_profile` only writes
-- three columns, but neither of those is a rule. Any signed in member could have
-- opened the browser console and run
--
--   sb.from('people').update({ post_nominals: 'FAMI' }).eq('id', <their id>)
--
-- and it would have succeeded, because the policy allowed it. `public_register`
-- reads `p.post_nominals` straight from that row, so the change would have shown
-- on the public register within a page load: a member awarding themselves the
-- letters of a grade they do not hold, on the very page a duty holder checks.
-- The same route reached their own name.
--
-- WHY A TRIGGER RATHER THAN A POLICY. Row level security decides whether a row
-- may be written, not which of its columns. The usual answer, a column level
-- GRANT, does not work here because members and staff are the same database
-- role: narrowing the grant to three columns would stop the office correcting a
-- misspelled name. So the rule goes in a BEFORE UPDATE trigger, which can see
-- both the old row and the new one and can ask who is doing the writing.
--
-- The list is an ALLOW list rather than a list of protected columns. A column
-- added to `people` in a year's time is then locked by default and somebody has
-- to come here and think about it, which is the right way round: the failure of
-- a deny list is silent and the failure of an allow list is a member ringing the
-- office to say a field will not save.
-- =============================================================================

create or replace function app.people_own_row_column_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Staff editing somebody's record, and the office correcting a name, are the
  -- normal case and are governed by people_update_staff instead.
  if (select app.is_staff()) then
    return new;
  end if;

  -- Anything that is not a member editing their own row: the service role during
  -- a card issue, a trigger, a migration. There is no member here to restrain,
  -- and the policies already decided this write was allowed.
  if (select app.person_id()) is distinct from new.id then
    return new;
  end if;

  -- From here down: a member, editing their own row, through whatever route.
  --
  -- The three the profile page offers.
  -- The four photograph columns, which set_my_photo and clear_my_photo write on
  -- the member's behalf and which are already fenced by those functions: a
  -- photograph path must sit inside the member's own folder.
  if new.given_name    is distinct from old.given_name
  or new.family_name   is distinct from old.family_name
  or new.post_nominals is distinct from old.post_nominals
  or new.email         is distinct from old.email
  or new.id            is distinct from old.id
  or new.created_at    is distinct from old.created_at then
    raise exception
      'A member may change their telephone number, their addresses and their photograph. '
      'Everything else on this record is changed by the AMI office.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function app.people_own_row_column_guard() is
  'Holds a member to the columns they own on their own people row. people_update_own '
  'allows the row; this decides which parts of it. Named columns are refused rather '
  'than silently ignored, because a field that appears to save and does not is worse '
  'than one that says no.';

revoke all on function app.people_own_row_column_guard() from public;

drop trigger if exists people_own_row_column_guard on public.people;
create trigger people_own_row_column_guard
  before update on public.people
  for each row execute function app.people_own_row_column_guard();


-- -----------------------------------------------------------------------------
-- The three the member owns, said out loud
-- -----------------------------------------------------------------------------
comment on column public.people.mobile is
  'Changed by the member from the profile page, or by the office. One of three '
  'columns on this table a member may write.';
comment on column public.people.home_address is
  'Changed by the member from the profile page, or by the office.';
comment on column public.people.business_address is
  'Changed by the member from the profile page, or by the office.';
comment on column public.people.post_nominals is
  'The letters after the name, shown on the public register. NOT changeable by '
  'the member: these follow the grade, and a member who can set them can award '
  'themselves one. See the trigger above.';


-- =============================================================================
-- CHECKING IT
-- =============================================================================
-- Signed in as an ordinary member. Note `app.person_id()` rather than
-- `auth.uid()`: since 0017 a person and an account are two different things and
-- people.id is not the account id.
--
-- The first three should succeed and the last three should fail with 42501.
--
--   select public.update_my_profile('07700 900000', null, null);              -- ok
--   update public.people set mobile = '07700 900001'
--    where id = app.person_id();                                             -- ok
--   update public.people set home_address = '{"lines":["1 High Street"]}'
--    where id = app.person_id();                                             -- ok
--
--   update public.people set post_nominals = 'FAMI'
--    where id = app.person_id();                                        -- refused
--   update public.people set family_name = 'Other'
--    where id = app.person_id();                                        -- refused
--   update public.people set email = 'someone@else.com'
--    where id = app.person_id();                                        -- refused
--
-- And as a member of the office, all six should succeed.
-- =============================================================================


-- =============================================================================
-- STILL OPEN, and not fixed here
-- =============================================================================
-- A member changing the address they sign in with changes it on their ACCOUNT,
-- through auth.updateUser, with a confirmation to both addresses. Nothing then
-- updates people.email, so the office record keeps the old address and every
-- letter and invoice still goes there. The member sees no sign of this.
--
-- It is not fixed in this migration because the fix is a decision rather than a
-- line of SQL: either the confirmed new address should flow through to the
-- record automatically, or the office should be told to change it, or the field
-- should stop being offered on the profile page. All three are defensible and
-- only the office can choose. Worth settling before the first member changes an
-- email address, because after that the two records are quietly apart.
-- =============================================================================
