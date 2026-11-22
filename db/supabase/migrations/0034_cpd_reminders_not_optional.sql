-- =============================================================================
-- 0034  A CPD reminder is a notice, not a mailing
--
-- Steve's decision, 23 August 2026.
--
-- 0029 made the CPD reminder a preference, switchable from the profile page and
-- from the unsubscribe page. It is now compulsory, on the same reasoning 0029
-- itself used for a decision about somebody's own record: CPD is a condition of
-- the grade, so a member who is short in October is told, whatever else they
-- have switched off.
--
-- THE PART THAT MATTERS MORE THAN THE RULE. Taking a switch off a page does not
-- take it out of the database. Every member who had already turned the reminder
-- off would have stayed off for ever, invisibly, with no control anywhere to put
-- it back and nothing on any screen to say why they were the only person not
-- being reminded. So this migration does three things and the first is the one
-- that would have been forgotten.
--
-- WHY A TRIGGER RATHER THAN A DROPPED COLUMN
--
-- Dropping the column would mean editing five things that read it: the reminder
-- query, `set_preferences_by_token` and its positional caller
-- `unsubscribe_all_by_token`, `my_preferences_by_token` and `my_profile`. Five
-- edits to remove one fact is five chances to get it wrong, and it would make
-- reversing this decision a second migration rather than one dropped trigger.
--
-- So the column stays, everything that reads it carries on reading it, and the
-- trigger guarantees what it says. The profile page writes to
-- `member_preferences` directly under `prefs_update_own`, so a member could
-- otherwise have set it false from the browser console exactly as 0028 found
-- with `post_nominals`. RLS decides rows, not columns; a trigger is the only
-- thing that decides a column.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Put back everybody who had turned it off
-- -----------------------------------------------------------------------------
update public.member_preferences
   set cpd_reminders = true
 where cpd_reminders is distinct from true;


-- -----------------------------------------------------------------------------
-- 2. A row created from now on starts on
-- -----------------------------------------------------------------------------
alter table public.member_preferences
  alter column cpd_reminders set default true;


-- -----------------------------------------------------------------------------
-- 3. And it cannot be turned off, by anybody, by any route
-- -----------------------------------------------------------------------------
-- Deliberately silent rather than raising. `unsubscribe_all_by_token` passes
-- false for every switch, and a member pressing "stop everything" should get a
-- page that says everything is off rather than an error telling them one of
-- their choices was refused. The page already says AMI still writes about their
-- own membership, which is exactly what this is.
create or replace function app.cpd_reminders_always_on() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.cpd_reminders := true;
  return new;
end;
$$;

drop trigger if exists member_preferences_cpd_reminders on public.member_preferences;

create trigger member_preferences_cpd_reminders
  before insert or update on public.member_preferences
  for each row execute function app.cpd_reminders_always_on();

comment on function app.cpd_reminders_always_on() is
  'Holds member_preferences.cpd_reminders true. A CPD reminder is a notice about '
  'the member''s own standing rather than a mailing they subscribe to, so it is '
  'not offered as a switch on any page. Silent rather than raising, because '
  'unsubscribe_all_by_token passes false for everything and that press should '
  'succeed. Drop this trigger to make the reminder optional again; nothing else '
  'needs changing, because every reader still reads the column.';

comment on column public.member_preferences.cpd_reminders is
  'Always true since 0034 and held there by a trigger. Kept as a column rather '
  'than dropped so that the five things which read it carry on reading one fact, '
  'and so that reversing the decision is one dropped trigger.';


-- -----------------------------------------------------------------------------
-- What is deliberately NOT changed
-- -----------------------------------------------------------------------------
-- `app.queue_cpd_reminders` still has `and pr.cpd_reminders` in its where
-- clause. It can no longer exclude anybody, and it stays: it means the column
-- remains the single thing that decides who is reminded, with the trigger
-- guaranteeing its value, rather than the rule being split between a column
-- nobody reads and a trigger nobody can see from the query. If the decision is
-- reversed, dropping the trigger is enough and the query is already right.
--
-- `cpd_receipts` is untouched and stays a preference. A note confirming an entry
-- has been received is a convenience; a note saying the year is not met is not.
