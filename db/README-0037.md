# 0037  The page photographs, and a security policy for the admin app

Site 58, admin 18, database 20.

## What this release is

**The page photographs are editable.** Thirteen of them: the banner on eight
pages, the photograph band on the home page, and the picture beside the split
panels on About, Membership, CPD scheme and Support. Each is a field on the
Pages screen showing the current picture, the site's own five photographs to
choose from, and an upload, which goes through the same converter as the news
pictures. The dark wash over a banner stays; only the picture changes.

The hero on the home page is not included. Its four pictures rotate in step
with the hero statements and belong with them.

**The admin app has a content security policy.** Its two inline scripts are
allowed by their fingerprint and nothing else inline can run. This is the
second lock behind the sanitiser fix in admin 17.

## Run it in this order

1. **Migration 0037** in the SQL editor. It adds the address check and seeds
   the thirteen photographs as the pictures the pages show today.
2. **Test 18**, `tests/18_page_photographs_supabase.sql`, Run without RLS.
   Expect `ALL 16 TESTS PASSED`.
3. **Site bundle 58** to `ami-site`.
4. **Admin bundle 18** to `ami-admin`. The tag top left says V18.

## Then check

1. **The admin app opens and works.** This is the one that matters for the
   policy. Click through a few screens. If the page is blank, see below.
2. **Pages, About AMI.** The first field is Banner photograph, showing the
   team photograph, with five small pictures beside it and one outlined.
3. **Click a different one of the five, Save and publish, reload /about.** The
   banner has changed and the wash is still over it.
4. **Put it back.**

## IF THE ADMIN APP OPENS BLANK

That is the policy refusing the app. The way back takes two minutes: open
`_headers` in the admin bundle, delete the line beginning
`  Content-Security-Policy:`, zip the contents again and upload. Or upload
admin 17, which has no policy. Then tell me what you saw.

It should not happen. Test 19 runs every screen under the real header and
fails if the policy is stale or refuses anything.

## Two things found

**A second `photoUrl`.** The new photograph code first used that name, which
the members area already uses for a member's own photograph. Every page shares
one global scope, so the second would have replaced the first without a word,
and every member's photograph would have vanished. Caught before it shipped.
Test 12 now checks every page script against `site.js` for a name declared
twice, and on its first run found a real one: the sign in page had its own
`signOut`, silently replacing the shared one. Renamed.

**A missing address passed the database check.** A CHECK constraint passes on
null, so a photograph block with no address went in. `body is not null` is now
stated. Test 18 found it on its first run.
