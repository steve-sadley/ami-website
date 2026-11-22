# 0059: a member's own row no longer shows who switched it, or why

Database 47, security check 7. Site 75 is unchanged. Database 48 adds 0060.

From the 31 October security check. A signed in member reads their own row on
`members`, and it carried three office columns: `activated_by` and
`deactivated_by` (the person id of whoever pressed the switch) and
`deactivation_reason` (the office's words). Nothing showed them, but a browser
console could read them.

Row level security decides rows, not columns, so 0059 takes away the table
grant and gives it back column by column, leaving those three out. It is an
allow list, as 0028's guard is: a column added to `members` later is hidden
until somebody adds it, and the failure is a loud "permission denied", not a
quiet leak.

Decisions taken, flag if wrong:

- `activated_at` and `deactivated_at` stay readable. `admin_member_list` uses
  both, and a member knowing when their own membership started or ended is no
  secret.
- Members and staff are the same database role, so staff lose a direct read of
  the three columns too. Nothing in the admin app reads them today. The office
  keeps a route through the new `public.member_activation(member_id)`:
  membership staff only, and it gives names rather than ids. It is not on a
  screen yet; say if you want it on the member card.
- Writes are untouched. Switching a membership off with a reason works as it
  did; test 53 proves it.

Test 53 (12) is new. It went red six ways with the table grant put back and two
with only `deactivation_reason` granted. Test 02 now reads `activated_by`
through `member_activation()` (still 30). Database 872, all passing, and clean
in staging order with `tools/replay-staging-order.sh 0058`.

## Order

1. Run `supabase/migrations/0059_hide_activation_columns.sql`.
2. Run `tests/53_hide_activation_columns_supabase.sql`. Expect `ALL 12 TESTS PASSED`.
3. Run `tests/02_admin_actions_supabase.sql`. Expect `ALL 30 TESTS PASSED`.
4. From the security check 7 folder, run `check-staging-is-up-to-date.sql`.
   Every 0059 row says yes. The 0060 rows say NO until 0060 is run.
5. Sign in on staging as a member and open `/login` and `/card`. Both draw as
   before.
6. Then 0060 (README-0060), and only after that security check 7, with
   `--compare` against the 22:51 report. Expect 492, all passes.

## The way back

```sql
grant select on public.members to authenticated;
```

That one line puts the table grant back and undoes 0059. `member_activation()`
can stay; it does no harm.
