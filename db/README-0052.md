# 0052: a sync reports where every row it read stands

Database 39, admin 37. Found on staging, 31 October: the AGM read 337 rows and
reported 307 not matched, which looked like 30 matches. The 30 had no email;
only rows decided afresh were counted. `dynamics_record` is restated from 0049
counting every row read by its outcome. Admin 37 shows "with no email" and "on
a lapsed membership" apart from "not matched to a member". Test 45 (2).
Database 782.

The same run matched one training row to a staging member (before 2027, so
nothing awarded): the first proof on real data that matching works.
