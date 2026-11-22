# 0049: two email addresses, matched every time

Database 36, admin 31. Steve, 31 October: many people use a personal address
as well as the company one, so every email match checks both.

- `people.alt_email`: a member's second address. Set by the office on the
  People screen (Second email), never by the member: the 0028 guard is
  restated with it added. Lower case, a real address, and never another
  person's main or second address.
- `dynamics_feeds.email2_field`: a second email column, such as the contact's
  `emailaddress2`. A booking keeps both as `email` and `email2`.
- `app.feed_who(text[])`: every address the attendee came with against both of
  every member's addresses. A remembered link on any address wins; links to two
  different members, or addresses held by two members, are left unmatched for
  the office. `zoom_decide` now asks it too, so Zoom matches second addresses.
- `feed_link` remembers every address on the row; `feed_dismiss` marks every one
  as not a member. `admin_cpd_feed_queue` gains `email2`.

## Order

1. 0048 and test 39 first, if not already run.
2. Run `supabase/migrations/0049_second_email.sql`.
3. Run `tests/42_second_email_supabase.sql`: `ALL 20 TESTS PASSED`.
4. Upload admin 31 (after 0049: its People screen reads `alt_email`).

Database total 769. Tests 25 and 39 unchanged and passing.
