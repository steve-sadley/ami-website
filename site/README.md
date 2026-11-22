# AMI public site

The pages anybody can see, with no sign in. Static files plus one Cloudflare
Function. No build step, no framework, no CDN at runtime.

## Deploying

A Cloudflare Pages project, uploaded as this folder. Nothing needs compiling.

Before the first deploy, two things:

1. In `assets/site.js`, paste the project's **publishable** key into
   `SUPABASE_KEY`. That key is public by design. It authenticates as `anon`,
   which holds no privilege on a single table in this database: everything it
   can see comes through seven views that filter themselves.

2. In the Pages project, under Settings and then Environment variables, set

   ```
   SUPABASE_URL      https://xxxx.supabase.co
   SUPABASE_SECRET   the SECRET key            (mark it encrypted)
   SMTP2GO_KEY       the SMTP2GO API key       (mark it encrypted)
   CONTACT_TO        info@ami.uk.com
   CONTACT_FROM      no-reply@ami.uk.com
   ```

   The secret key bypasses every access rule in the database. It exists here for
   one purpose, the application form, and it must never appear in `assets/`, in
   the repository, or in anything a browser downloads. If it is ever pasted into
   a page, rotate it in Supabase the same day.

   The last three are the contact form. `CONTACT_FROM` has to be on a domain
   SMTP2GO is verified to send for. The enquiry is sent FROM AMI with the
   visitor's address in Reply-To, because sending as the visitor would be forged
   mail and would be filed as junk. Until all three are set the contact form says
   plainly that it is unavailable rather than pretending to send.

## The pages

| File | Address | What it does |
|---|---|---|
| `index.html` | `/` | Home. Rotating headline, three counts, the latest three items. |
| `register.html` | `/register` | The public register, searchable. |
| `member.html` | `/m/<slug>` | One member's public record. What a card's QR code points at. |
| `news.html` | `/news` | News, guidance, events and video. |
| `article.html` | `/article?kind=&slug=` | One item, with its body. |
| `videos.html` | `/videos` | The video library, with a Vimeo player overlay. |
| `apply.html` | `/apply` | The application form. |
| `about.html` | `/about` | What AMI is, what it does and what it stands for. |
| `membership.html` | `/membership` | The grades, the fees, the three steps and the questions. |
| `support.html` | `/support` | Guidance, resources and the members forum. |
| `contact.html` | `/contact` | The contact form and the office details. |
| `login.html` | `/login` | Member sign in. |
| `404.html` | anything else | Not found. |

`_worker.js` turns `/m/jane-smith` into the profile page. A QR code that reads
`/member.html?slug=jane-smith` looks like a tracking link; one that reads
`/m/jane-smith` can be repeated over the telephone.

## Why `_worker.js` and not a `functions/` directory

Cloudflare Pages compiles a `functions/` directory into a Worker when you deploy
with Wrangler or from a git repository. It does **not** compile it when you drag
a folder or a zip into the dashboard: a direct upload treats `functions/` as
ordinary static files, so nothing runs and a POST to `/api/apply` falls through
to the site's 404. The browser then gets an HTML page where it expected JSON and
the form says the application could not be sent.

A single `_worker.js` at the root works with a direct upload. It runs in front of
everything, handles `/api/apply`, `/api/contact` and `/m/<slug>`, and hands the rest to
the static files through the ASSETS binding.

If this ever moves to a git based deploy, either form works and `_worker.js` can
stay as it is.

## What the browser can and cannot do

Read only, through seven views:

```
public_register  public_profile  public_content
public_article   public_hero     public_page      public_numbers  public_grades
```

It holds no privilege on any table. The one thing a visitor can cause to be
written, an application, is posted to `/api/apply`, which runs on Cloudflare,
holds the secret key in a binding, rate limits by address, drops honeypot
submissions and then calls `submit_application` in the database. The browser
never holds anything that can write.

## Where the words come from

The headline, the grades, the About page text and every article are read from
the database and set in the admin area. The text written into the HTML is a
fallback, and it is real text rather than a placeholder, so a page whose content
has not been set yet still reads properly.

## Things worth knowing before changing it

The register is fetched once and searched in the browser. That is the right
trade at a few hundred members: a small download, an instant search, no round
trip per keystroke. Past a few thousand it should become a server side query,
and the place to change it is `register.html`.

Article bodies may be markup written in the admin editor. It is checked against
an allow list on the way in AND checked again here on the way out, in
`bodyHtml()` in `site.js`. Twice, because once is a policy and twice is a
guarantee: the database could be written to by something other than the admin
app, and this is the last thing between it and a browser. A body written before
the editor existed is plain text, and the same function splits it into
paragraphs.

Every inner page is the agreed prototype's composition in the graphite and red
scheme. The rule that governs the colour is that red appears on things, never on
a background: a button, a badge, an icon tile, the featured grade card, the call
to action. Where the prototype put a near black red behind a photograph, this
puts the same near black graphite, which is the `.wash` class in the stylesheet.
Changing that one rule is how every banner on the site changes together.

Photographs stay in a private bucket. A storage policy re-checks on every request
that the membership is active, the profile is public and the member has switched
the photograph on, so turning any of those off takes the photograph down at once.
A public bucket could not do that.
