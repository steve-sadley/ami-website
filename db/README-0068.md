# 0068: contact enquiries are kept for 12 months

Database 56, site 86 (privacy notice). Steve's decision, 22 November 2026.

Since 0046 an enquiry from the contact form and its acknowledgement are kept
in the communication log (email_outbox, `direct:contact_office` and
`direct:contact_ack`). The privacy notice said they were not stored. It now
says they are kept for 12 months and then deleted, and 0068 makes that true.

- Setting `contact_retention_months` = 12. Change it there, not in code. A
  missing, zero or non-number value falls back to 12, never to deleting
  everything.
- `app.purge_contact_enquiries()` deletes only those two kinds, once older
  than the setting. Nobody signed in can run it.
- pg_cron job `ami-contact-retention`, daily at 03:17, created by the
  migration (skipped quietly on the test mirror, which has no pg_cron).

Done on staging by Claude, 22 November: applied; test 68's seven checks
right in a rolled back transaction; the job is scheduled. Mirror: 1,042
tests, migration and staging order; test 68 fails when the fallback is taken
out.

At cutover: nothing extra. The job is in the database, so it moves with it.
