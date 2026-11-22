# 0051: a feed's last result is the whole run

Database 38, admin 36. Found on staging, 31 October: training showed "29 rows"
after reading 4,029, because the Worker sends 400 rows a batch and each batch
overwrote `last_result`. A trigger on `dynamics_feeds` adds each batch to the
running run's total (only one run is ever running) and a new run starts afresh.
`dynamics_record` is unchanged. Test 44 (4). Database 780.

Admin 36, from the same staging run: every row from ARCA's records was "to
match", because most people in ARCA's records are not AMI members (and staging
holds test members only). People to match now keeps To match for Zoom, and
lists ARCA's unmatched under their own tab, "ARCA records, no member found".
They are matched again on every sync, so a member whose second email is added
later is picked up on their own. Wording: "not matched to a member".
