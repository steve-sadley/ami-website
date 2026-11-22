# The JavaScript suites

Run from the `db` folder with the bundles unzipped beside it as `site`,
`admin` and `db`. Every file takes the path to its bundle as an argument if it
is somewhere else. Playwright and Chromium are what they need; in Claude's
container both are already installed.

| File | What it proves | Checks |
|---|---|---|
| `12_page_keys.js` | The site, the admin app and the seed agree about every block, list, icon and photograph; no two scripts on a page declare one name; no inline event handler the policy would refuse | 405 |
| `13_blocks_browser.js` | Every block on every public page reaches its element | 238 |
| `14_pages_browser.js` | The Pages screen: fields, lists, photographs, draft and publish, choosing a photograph from the library | 80 |
| `15_lists_browser.js` | Repeating blocks and photographs drawn from awkward rows | 51 |
| `16_upload_browser.js` | Pictures are converted before upload, including as Safari | 21 |
| `19_admin_csp_browser.js` | The admin app's policy is current and every screen runs under it | 11 |
| `20_worker.mjs` | Every Worker route answers; the contact form; the wallet pass signed and verified with openssl | 47 |
| `21_members_browser.js` | The members area under the real headers: the guard, every page, the public record, member text as words, an entry reviewed with AI help, the CPD form including a reflection sent with its certificate and a certificate used before | 99 |
| `26_zoom_worker.mjs` | Zoom attendance in the Worker against a stub Zoom: the database is asked as the staff member first, the right occurrence by its London date, every page, registrant emails, only five fields per line passed on, and Zoom's refusals in its own words | 36 |
| `27_zoom_admin_browser.js` | The Zoom sessions and People to match screens in a browser under the admin app's real policy, and that the policy lets the app reach the site at all | 20 |
| `29_ai_review_worker.mjs` | The AI review in the Worker against a stub Claude: asked as the staff member, the key on the right header, the answer only through the one tool, nothing about the person sent, a closing tag cannot escape the reflection, a bad key tried once | 31 |
| `30_ai_review_admin_browser.js` | CPD to review with Claude's recommendations in a browser under the real policy: shown as words, Ask Claude loops, Accept the ones Claude recommends goes through review_cpd only, reject starts from Claude's note, the guide screen, the certificate checks, a likely repeat and the evidence files | 26 |
| `33_evidence_worker.mjs` | Evidence through the Worker: the type from the bytes, the fingerprint taken from what is stored, a used certificate refused and nothing left in storage; and Claude reading a certificate without the member's name | 29 |
| `35_comms_log_worker.mjs` | The four emails the Worker sends itself are logged after sending, sent or failed, exactly as sent; a log that cannot be written never fails the visitor; the drain logs nothing twice | 11 |
| `36_library_and_log_admin_browser.js` | The image library screen, the chooser on a news item with real clicks, the headline's photograph, the communication log and reading one safely, Emails on a member, the monthly CPD email preview, Bank holidays | 23 |
| `37_site_pictures_browser.js` | The public pages: one photograph per headline whatever the count, an item's default picture from the library, a hostile address refused | 9 |
| `40_dynamics_sync_worker.mjs` | The ami-dynamics-sync Worker against pretend Microsoft, Dynamics and database: client credentials, a view by its exact name, every page, each record's id added, names never values as columns, only reads from Dynamics, the run logged whatever fails, Sync now refused for a member; and the site's Sync now door passing the sign in and nothing else. Takes the dynamics-sync folder, then the site | 26 |
| `41_dynamics_admin_browser.js` | ARCA records feeds, ARCA courses and ARCA meetings in a browser under the real policy: no New, Columns found as words, only the office's columns saved by code, Sync now, Recent syncs, a course decided, ARCA's rows in People to match | 15 |
| `61_password_reset_browser.js` | Set a new password from the reset link, to site 80's rules: 12 characters, capital, small letter and number, the same password and a leaked one explained in words | 14 |
| `65_interview_worker.mjs` | The interview doors (0064) against pretend Microsoft and database: Outlook clashes hidden and refused, the Teams event with the applicant invited and a transactionId, clean up when the database fails, the old event cancelled on a change, the office door as the staff member | 38 |
| `66_interview_browser.js` | The booking page: token after the # and never in an address, UK time, booking, a time just taken, change, cancel, the notice period, markup kept as words | 24 |
| `68_nav_one_line_browser.js` | The menu bar on one line at every width from 1,000 to 1,700 pixels, with the burger below 1,240 (site 82) | 72 |
| `69_media_library_admin_browser.js` | The picture chooser with 33 pictures (every tile visible), the document chooser, a renamed web page refused, documents stored privately, the Media library's three tabs | 23 |
| `70_guidance_worker.mjs` | /api/guidance/<slug>: open documents to anybody, members only to a current member asked as themselves, type from the extension, nosniff and sandbox, old addresses redirected | 21 |
| `71_new_pages_browser.js` | /guidance, /professional-conduct and /committees: listing, filters, members only marking, words kept as words, the footer and membership links | 19 |
| `67_interview_admin_browser.js` | Invite to interview, the application card, Interviews and Cancel with a reason, under the admin app's real policy | 16 |

## 20 and 21 replace the lost member area test bundle

`AMI-member-area-tests_7.zip` held `members.spec.js` (125 checks),
`pass.spec.js` and `worker.spec.js`. Steve did not know where it was on 30
October and it had been asked for in four sessions, so these two were written
again from what the code does. They are not copies.

**What 21 does not yet cover that 125 checks did, as far as can be told:** the
CPD entry form actually submitting, posting and replying in the forum,
reporting a post, the photograph crop and save, issuing and reissuing the card,
and the profile save. 21 proves each page draws, is guarded, runs under the
policy and treats member text as words. The interactions are the next thing
to add.

**One thing 21 found.** The card page's logo fallback was `onerror=""` in the
markup, which the site's policy refuses to run, so it had never worked on a
deployed page. It is a listener in `page-card.js` now, and 12 refuses any inline
handler from here on.

**The guard has two layers and the test needs both gone to fail.** With the
session check removed, `whoami` answering nothing still sends a visitor to the
sign in page. Proved by removing both.
