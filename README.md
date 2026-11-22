# AMI website

The Asbestos Management Institute's new website: the public site and members
area, the office's admin app, and the database.

```
site/            the public site and members area, Cloudflare Pages project ami-site
                 site/_worker.js is the site's Worker and deploys with it
admin/           the admin app, one HTML file, Cloudflare Pages project ami-admin
db/              Supabase migrations, seeds, tools and every test suite
security/        the automated security check, run from Steve's Mac against staging
dynamics-sync/   the ami-dynamics-sync Worker, deployed with wrangler (schedule and secrets stay in the dashboard)
```

## Deploying

A push to `main` deploys whatever changed, by `.github/workflows/deploy.yml`:
site/ to ami-site, admin/ to ami-admin, dynamics-sync/ to the ami-dynamics-sync Worker. The Pages projects keep all their
settings and secrets; this uploads to them exactly as a zip did.

The database is not deployed by a push. Each migration in
`db/supabase/migrations/` is run on staging (ami-staging) in order, followed by
its test in `db/tests/`, and its `db/README-00NN.md` says what to expect.

Before changing an asset, bump its `?v=` stamp in every page that loads it,
or browsers keep the old copy for a year.

## Testing

From `db/`, with this repository's three folders side by side (the suites look
for `../site` and `../admin`):

```
./run_tests.sh                 every database suite on a mirror (Postgres 16 + pgTAP)
node tests/<n>_*.js            the browser suites (Playwright and Chromium)
node tests/<n>_*.mjs           the Worker suites
```

Nothing here holds a secret. Keys live in Cloudflare and nowhere else.
