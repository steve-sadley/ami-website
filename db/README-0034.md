# 0034, the CPD reminder is not a preference

Two minutes in the SQL editor, and it goes with public site bundle 54.

## What changed and why

The CPD reminder was a switch on `/profile` and on `/preferences`. It is now
compulsory, on the reasoning 0029 already used for a decision about somebody's
own record: CPD is a condition of the grade, so a member who is short in October
is told, whatever else they have switched off.

**The half of this that would have been forgotten.** Taking a control off a page
does not take the setting out of the database. Every member who had already
turned the reminder off would have stayed off for ever, invisibly, with no
control anywhere to put it back and nothing on any screen to say why they were
the only person not being reminded. So 0034 does three things and the backfill is
the first.

1. Every row with the reminder off is switched back on.
2. The column default becomes true, so a new row starts on.
3. A BEFORE INSERT OR UPDATE trigger holds it true, by every route.

## Why a trigger and not a dropped column

Dropping the column means editing five things that read it: the reminder query,
`set_preferences_by_token`, its positional caller `unsubscribe_all_by_token`,
`my_preferences_by_token` and `my_profile`. Five edits to remove one fact is five
chances to get it wrong, and it would make reversing the decision a second
migration rather than one dropped trigger.

**And the profile page is the reason a trigger is needed at all.** It writes to
`member_preferences` directly under `prefs_update_own` rather than calling a
function, so a member could otherwise have set the column false from the browser
console, exactly as 0028 found with `post_nominals`. Row level security decides
rows, not columns. A trigger is the only thing that decides a column.

**The trigger is silent rather than raising.** `unsubscribe_all_by_token` passes
false for every switch, and a member pressing "stop everything" should get a page
saying everything is off rather than an error telling them one of their choices
was refused. That page already says AMI still writes about their own membership,
which is exactly what this is.

## What to run

**1. The migration.** Paste
`supabase/migrations/0034_cpd_reminders_not_optional.sql` and run it.

**2. The new suite.** Paste `tests/10_cpd_reminders_compulsory_supabase.sql` and
choose **Run without RLS**. Expect:

```
ALL 16 TESTS PASSED
```

**3. Test 06 again, and note the number has moved.** It is **50** now, not 49.
Two assertions in it were inverted in place rather than deleted, so the file
records that a decision moved:

- Dee, who had switched reminders off, is now reminded anyway.
- "All five are off afterwards" became the four a member may refuse, plus a new
  check that the reminder stays on.

The whole set is now **382**: 75, 30, 25, 51, 46, 50, 42, 28, 19 and 16.

## Proved rather than assumed

The mirror was rebuilt from scratch by a non superuser owner and all ten suites
pass. The trigger was then dropped on purpose: **eight of the sixteen checks in
test 10 went red, and two in test 06**. A suite that does not bite when the rule
is removed is not protecting anything.

## What is deliberately unchanged

`app.queue_cpd_reminders` still has `and pr.cpd_reminders` in its where clause.
It can no longer exclude anybody and it stays, so the column remains the single
thing that decides who is reminded with the trigger guaranteeing its value,
rather than the rule being split between a column nobody reads and a trigger
nobody can see from the query. Reversing the decision is then one dropped
trigger and nothing else.

`cpd_receipts` is untouched and stays a preference. A note confirming an entry
has been received is a convenience; a note saying the year is not met is not.
Test 10 checks that the trigger has not taken the whole row hostage.
