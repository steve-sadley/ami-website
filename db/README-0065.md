# 0065: documents in the media library, the guidance page, two new pages

Database 53, site 83, admin 48. Steve, 22 November 2026.

## What changed

1. **The picture chooser showed no pictures.** It borrowed the sign in box's
   style, capped at 430 pixels, and with the 33 pictures on staging every tile
   was squeezed to a sliver. It is now full width and the grid scrolls. Test 69
   uses 33 pictures and went red against the old style, twice over.
2. **The Image library is now the Media library**, with Pictures, Documents
   and Archived. Documents are PDF, Word, Excel, PowerPoint, OpenDocument, CSV
   or plain text, up to 20 MB, identified by their first bytes (a web page
   renamed .pdf is refused), kept in the private content-media bucket under
   documents/. Open, archive and delete work as for pictures; one in use cannot
   be deleted. The guidance document already uploaded is entered in the library.
3. **Guidance's document is chosen from the library**, like a picture.
4. **/guidance**, a page of every published guidance document, with search,
   category pills, type and size. Members only documents are listed and marked;
   the file is handed out only to a signed in current member.
5. **Downloads now work for visitors.** They never did: the old button signed
   a link with the browser's database client, which needs a session. The
   Worker serves files at /api/guidance/<slug>, typed from the extension, with
   nosniff and a sandbox.
6. **/professional-conduct** and **/committees**, words from the old site,
   every word editable on the Pages screen. Committees is a list the office can
   add to. The old addresses /membership/professional-conduct/ and
   /membership/committees/ redirect to them for good.
7. **Membership** gains a Standards and governance section linking to both.
   The footer links to all three and no longer says "Every entry on the register
   is checked against the AMI record".
8. **Grade cards**: "On application" sits on the bottom edge of every card so
   it lines up across a row, and no card is red at rest: each turns red under
   the pointer (or when reached with the keyboard).
9. The Support page's guidance card now goes to /guidance.

## Decisions taken, flag if wrong

- Committees: the old page's 2022 meeting dates are left out as out of date;
  the committee members are as the old page lists them. Check they are current.
- Professional conduct: the "Telling AMI" box and the "Need to raise a
  concern?" panel are new wording drawn from the code itself. Edit or remove on
  the Pages screen.
- Documents are kept private and served by the site, rather than put in the
  public bucket, so withdrawing a document takes it off the site within five
  minutes and a members only one never has a public address.

## What Steve has to do, in order

1. Supabase, ami-staging, SQL editor: run
   `supabase/migrations/0065_media_documents_and_pages.sql`.
   Expect "Success. No rows returned".
2. Run `tests/65_media_documents_supabase.sql`, Run without RLS.
   Expect `ALL 30 TESTS PASSED`.
3. Upload **site 83** to ami-site. No settings change.
4. Upload **admin 48** to ami-admin. It shows v48.
5. Check: open a news item in the admin app and choose a picture: the pictures
   show. Open Media library, Documents: the guidance document is there.
   Visit staging.ami.uk.com/guidance signed out and press Download: the PDF
   opens. Visit /professional-conduct and /committees.

## Tests

- 65 (30, database), red three ways.
- 69 (23, the library and chooser in a browser), red with each half of the
  chooser fix removed.
- 70 (21, the document door in the Worker), red with the member check removed
  and with the type taken from storage.
- 71 (19, the three pages in a browser).
- 11 and 18 count fourteen pages and sixteen photographs; 13 reads 0065's
  seeds; 14 lists fourteen pages; 19 expects v48; 36 opens Media library.
- Database 1,020, clean in staging order.
