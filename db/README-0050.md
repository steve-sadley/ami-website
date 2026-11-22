# 0050: a Dynamics column name matches whatever its case

Database 37, admin 35. Found by Steve on 31 October: Columns found showed the
names in capitals (the tag style), and a key copied from there would not have
matched. `app.dyn_key` finds a column by its exact name, then by the same name
in any case; `dyn_text` and `dyn_date` use it, and the formatted words of a
lookup are found even when the view carries them without the id. Test 39 caught
the first version of this losing exactly that case. Admin 35 shows the names in
their real case and copies one on a click.

Run `supabase/migrations/0050_dynamics_column_case.sql`, then
`tests/43_dynamics_column_case_supabase.sql`: ALL 7 TESTS PASSED.

`name-the-dynamics-columns.sql` (sent separately, 31 October) set the staging
feeds from `seen_fields` by suffix: email `..._x002e_emailaddress1` and 2,
name `..._x002e_fullname`, meetings event `..._x002e_core_name` and date
`..._x002e_core_eventstart`, AGM date `..._x002e_core_eventend`, training course
`..._x002e_arca_qualificationname` and date `..._x002e_core_enddate`. The
attendance filter (`core_attended`) is in the training view itself.

Database total 776.
