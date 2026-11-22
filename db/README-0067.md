# 0067: public_article gives no storage address

Database 55, site 86. From security check 9, 22 November 2026.

public_article carried `storage_path`, a guidance document's address in the
private content-media bucket, readable by anybody. Nothing could be fetched
with it (the bucket is private and only open documents are listed there), but
the address is the Worker's business. It becomes `has_document`, true or
false. Site 86's article page reads `has_document`, and still understands
`storage_path`, so the site can go first.

Also in site 86: `/api/interview/office-cancel` answered a made up sign in
with a 500. The Worker now turns the database's refusal of a sign in (401,
PGRST301 to 303) into a 401 on every interview door. Test 65 has two new
checks (40), the first seen to fail without the fix.

Done on staging by Claude, 22 November: 0067 applied, test 67's six checks
right. Mirror: 1,035 tests, migration and staging order.

## The way back

Restore the 0046 definition of public_article (storage_path in place of
has_document), then `grant select on public.public_article to anon, authenticated;`.
