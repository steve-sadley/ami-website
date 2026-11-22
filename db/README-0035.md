# 0035  The page copy becomes content

What to run, in what order, and what number to expect back.

## What this is

Every word on the eleven public pages becomes editable from the admin area.
Before this, four blocks existed: the About intro, the Membership intro, and the
office telephone number and address. Everything else was in the HTML.

135 blocks, seeded with the words that are on the pages today, so the first time
the Pages screen is opened it already says what the site says.

## Run it in this order

**1. Migration 0035**, in the Supabase SQL editor. Paste the whole file and run
it. It adds `page_blocks.items`, inserts the 135 blocks, and replaces
`public_page` so it carries `items`.

It can be run twice safely. Every insert is keyed on `(page_key, block_key)`
with `on conflict do nothing`, so a second run cannot overwrite copy somebody
has edited.

**2. Test 11.** `tests/11_page_blocks_supabase.sql`, Run without RLS. Expect

```
ALL 30 TESTS PASSED
```

**3. Test 03,** which touches `public_page` and must still pass. Expect `ALL 25
TESTS PASSED`.

**4. Site bundle 56.** Upload it to the `ami-site` project. It contains the
block renderer, the generated block map, and bundle 55's two changes.

**5. Admin bundle 16.** Upload it to `ami-admin`.

Order matters between 4 and 5 only in one direction: the admin app can publish a
block the site is not yet reading, and nothing happens. The site reading a block
the admin app cannot edit is also harmless. Neither can break a page, because
every page keeps the words in its markup as the fallback.

## Then check three things on the site

1. **Open any public page as a visitor, signed out.** The words must be there.
   This is the one that matters: if `public_page` ever stops answering an
   anonymous reader, every page falls back to its markup, which looks identical,
   and nothing tells you.
2. **Change a line on the Pages screen, press Save and publish, reload the
   page.** The new words should be there.
3. **Save one as a draft instead.** The site should NOT change. The field says
   `draft` until it is published.

## What is deliberately not in this

**The privacy notice.** 2,124 words of legal text going to a solicitor, where
the version that was approved matters. A deployment is a record of exactly what
changed and when; a `page_blocks` row is not.

**Creating a page.** A page here is a real file with a route, a page script and
an entry in the content security policy. Adding a twelfth page stays a job for
whoever has the bundle.

**The repeating blocks.** The six support cards, the three joining steps, the
six questions on Membership, the bullets and the cards on the CPD scheme page
are all seeded and all on the page, but the editor for them is the next release.
The Pages screen shows them read only and says so, rather than leaving somebody
to find out.

**The nine photographs.** Next release as well, and there is something to fix
first: the image upload that already exists on the news, guidance, events and
video screens uploads whatever file it is given, raw, with no conversion and no
size check. Nobody has noticed because there is no real content yet. That wants
doing before any more pictures become editable, not after.

## If something goes wrong

**The Pages screen is empty or a field opens blank.** The migration has not run,
or has run against a different project. `select count(*) from public.page_blocks`
should be at least 135.

**A page on the site does not change after publishing.** Check the field says
`live` rather than `draft`. If it says live, the site bundle is older than 56.

**Nothing on any public page, for a signed out visitor.** Check
`select relforcerowsecurity from pg_class where relname = 'page_blocks'`. It must
be `false`. The first draft of this migration turned it on, which makes
`public_page` return nothing to an anonymous reader; see the comment in 0035 and
test 11.

## The tests in this bundle

| File | What it is | Count |
|---|---|---|
| `tests/11_page_blocks_supabase.sql` | the column, the seed, the view, who may write | 30 |
| `tests/12_page_keys.js` | the site, the admin app and the seed agree on every key | 185 |
| `tests/13_blocks_browser.js` | every block reaches the right element, in a real browser | 202 |
| `tests/14_pages_browser.js` | the Pages screen saves what it says it saves | 28 |

The three JavaScript ones need the site and admin bundles unzipped beside this
one, and Playwright:

```
node tests/12_page_keys.js
node tests/13_blocks_browser.js
node tests/14_pages_browser.js
```

They take paths as arguments if the folders are somewhere else.


## Deployed, 30 October 2026

All of the above was done on staging and the five checks passed. Three things
came out of it and are recorded in `claude/ami-cms-piece-one-handover.md`: the
sidebar showed Content twice in admin 15 and is fixed in 16; test 03 asserted an
application reference by value and now asserts its shape; and the local and
Supabase copies of each test suite were one word apart in the same folder, which
sent ten minutes after a failure that was not there. The local ones now live in
`tests/local-mirror-only/` with a README saying why.
