# 0063: every "my" view shows only the signed-in person's own rows, even to staff

Database 51. Found by Steve, 1 November: signed in to the site as himself, My
AMI said "Your record could not be loaded just now."

my_profile, my_card, my_cpd_summary and my_cpd relied on row level security to
keep a member to their own rows. Membership staff may read every member, so for
somebody who is both staff and a member these views returned the whole
membership: 118 profiles where the page wanted one. My CPD would also have
listed everybody's entries. Steve is the first person who is both.

Each view now filters to `app.member_id()` itself. The columns are unchanged.
my_posts, my_learning and my_recent already did this. Test 62 (7) checks every
my_ view there is, as someone who is both staff and a member. It failed
without 0063 ("more than one row") and passes with it. Database 946, clean in
staging order.

## Order

1. Run `supabase/migrations/0063_my_views_are_mine.sql`.
2. Run `tests/62_my_views_are_mine_supabase.sql`. Expect `ALL 7 TESTS PASSED`.
3. Reload My AMI on the site. Your own record shows.
