# 0036  Repeating blocks and converted pictures

What to run, in what order, and what number to expect back.

## What this release is

**The repeating blocks are editable.** The cards, the joining steps, the
questions and the bullets on the Pages screen open as a Block List: each item
with its own fields, an icon picker for the cards, move up and move down, and
add and remove where the design allows it.

**Pictures are converted before they leave the browser.** Every picture chosen
on the news, guidance, events and video screens is checked by its first bytes,
turned the right way up, scaled so no side is over 2,000 pixels, re-encoded as
WebP (JPEG on Safari, which cannot encode WebP) and stripped of its metadata.
Under 800 pixels wide is refused. SVG and HEIC are refused with a reason.

0036 is the database half of both: a list must be a list of objects, and the
public pictures bucket takes WebP and JPEG only, two megabytes at most.

## Run it in this order

**1. Migration 0036**, in the Supabase SQL editor. Paste the whole file and run
it. If any block on staging holds items of the wrong shape, it stops and names
them rather than failing on "some row".

**2. Test 17.** `tests/17_lists_and_pictures_supabase.sql`, Run without RLS.
Expect `ALL 14 TESTS PASSED`. On Supabase the two bucket checks are real; on
the local mirror they say "n/a on the mirror".

**3. Test 11 again.** Expect `ALL 30 TESTS PASSED`. See below for why this one
matters more than it looks.

**4. Site bundle 57**, to `ami-site`.

**5. Admin bundle 17**, to `ami-admin`. The version tag top left says v17.

## Then check four things

1. **Open About on the Pages screen.** The purpose cards and the At a glance
   bullets open as editors with their words in them, not as a grey "next
   release" note.
2. **Swap two of the purpose cards with the arrows and Save and publish.**
   Reload /about. They are swapped.
3. **Put them back.**
4. **On News, press New and choose a large phone photograph.** The line under
   the picture says what it was converted from and to, and that the location
   was removed. Close without saving.

## TEST 11 COULD NOT FAIL, AND NOW IT CAN

Test 11 shipped on 30 October counting rows of `finish()` that contain
"not ok". `finish()` never returns one; it returns only the closing summary.
So 11 printed `ALL 30 TESTS PASSED` whatever happened, and `run_tests.sh`
agreed, because that is the line it reads.

Found because test 17 was written by copying 11's ending, and with its own
constraint deliberately dropped it still said all passed. Both now use
`num_failed()`, as files 01 to 10 always did, and both have been proved to go
red: 17 with its shape check dropped, 11 with its prose or list constraint
dropped. Before the change, 11 said all 30 passed in that state.

**The 30 checks in 11 do pass.** They were run again with a working count. What
was wrong was the file's ability to say otherwise.

## And the check it then caught

The first version of the shape check let a list inside a list through. A JSON
path in its default lax mode unwraps arrays as it walks, so `[[{...}]]` looked
like a list of objects. It is `strict` now. Test 17 found it once its count
worked.

## If something goes wrong

**The Pages screen refuses to save a list.** It names the item and the field.
Every item needs the parts every item on that page already has, a button needs
a label and an address, and a grid three across takes three, six or nine.

**A picture will not upload and the message mentions the bucket.** 0036 has run
and the admin app is still 16, which uploads the raw file: a PNG, or anything
over two megabytes, is now refused. Upload admin 17.

**A picture on the site disappears.** It will not: the limits apply to new
uploads, and nothing already stored is touched.
