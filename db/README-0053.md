# 0053: keep only what can be about a member

Database 40, admin 39. Steve, 31 October: a row from ARCA's records that cannot
match by email, and whose name is not like an existing member's, is ignored.

- Kept: either email matches either of a member's (0049), or a CURRENT member
  has the same surname and first initial (`app.name_parts`, `app.name_key`:
  letters only, a title left out; `app.dyn_name_candidates`). The second kind
  waits in People to match, tab "ARCA records, possible members", with the
  member named (`admin_cpd_feed_queue.possible`).
- Not kept: everybody else, counted as `not_kept` and never stored. A stored row
  that later fits neither rule is deleted on the next read, unless the office
  has decided about it or it was awarded.
- The change history records updates and deletions of `dynamics_attendance`
  only, never what the sync reads in.
- Clean up: rows already held that fit neither rule are deleted, and so are
  their entries in the history. `audit_log` is append only; its guard trigger
  is switched off for that one delete and on again in the same script.

Tests 39, 42, 44 and 45 had people who are now not kept; their fixtures give
those people a member's name. New test 46 (12). Database 794.
