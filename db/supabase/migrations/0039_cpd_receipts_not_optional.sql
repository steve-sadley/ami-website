-- =============================================================================
-- 0039  A CPD receipt is a notice, not a mailing
--
-- Steve, 30 October 2026: an email every time a CPD point is earned, and
-- members cannot switch it off. The same decision 0034 made for the CPD
-- reminder, and built the same way, for the same reasons:
--
--   the switch is taken off /profile and /preferences (site 61)
--   every existing row is switched on (0038 already did; said again here)
--   a BEFORE trigger holds the column true, because the profile page writes to
--   member_preferences directly and RLS decides rows, not columns (0028)
--   SILENT rather than raising, because unsubscribe_all_by_token passes false
--   for every switch and "stop everything" must still succeed for the rest
--
-- Kept as a column rather than dropped: the receipt functions in 0029 read it,
-- and reversing the decision is then one dropped trigger and nothing else.
--
-- Safe to run twice.
-- =============================================================================
update public.member_preferences set cpd_receipts = true where not cpd_receipts;
alter table public.member_preferences alter column cpd_receipts set default true;

create or replace function app.cpd_receipts_always_on() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.cpd_receipts := true;
  return new;
end;
$$;

drop trigger if exists member_preferences_cpd_receipts on public.member_preferences;
create trigger member_preferences_cpd_receipts
  before insert or update on public.member_preferences
  for each row execute function app.cpd_receipts_always_on();

comment on function app.cpd_receipts_always_on() is
  'Holds member_preferences.cpd_receipts true. Every CPD point earned is emailed '
  'and a member cannot refuse it (Steve, 30 October 2026). Silent rather than '
  'raising, so unsubscribe_all_by_token still succeeds for everything else. Drop '
  'this trigger to make the receipt optional again.';

comment on column public.member_preferences.cpd_receipts is
  'Always true since 0039 and held there by a trigger, like cpd_reminders since '
  '0034. Kept as a column because the receipt functions read it.';
