/* The old ami.uk.com addresses (22 November 2026). At cutover the new site
   takes over the domain, so every old address with a home on the new site must
   answer with a permanent redirect to it, and that home must exist.

   Run:  node tests/73_old_site_redirects.mjs [path-to-site]                    */
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SITE = process.argv[2] || path.resolve(HERE, '../../site');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-old-'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'worker.mjs'));
globalThis.fetch = async () => new Response('the redirects never reach the network', { status: 599 });
const worker = (await import(pathToFileURL(path.join(TMP, 'worker.mjs')).href)).default;
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };
const go = p => worker.fetch(new Request('https://ami.uk.com' + p), { ASSETS: { fetch: () => new Response('page', { status: 200 }) } });

const src = fs.readFileSync(path.join(SITE, '_worker.js'), 'utf8');
const map = JSON.parse(src.slice(src.indexOf('const OLD_SITE = ') + 17, src.indexOf('\n};', src.indexOf('const OLD_SITE = ')) + 2));
ok(Object.keys(map).length >= 60, `every old address is listed, got ${Object.keys(map).length}`);

// Each target is a real page on the new site.
const pages = new Set(fs.readdirSync(SITE).filter(f => f.endsWith('.html')).map(f => '/' + f.replace(/\.html$/, '')));
const bad = Object.values(map).filter(t => !pages.has(t.split(/[?#]/)[0]));
ok(bad.length === 0, 'every redirect lands on a page that exists: ' + bad.join(', '));

for (const [from, want] of [
  ['/news/archive/ami-3rd-annual-general-meeting/', '/article?kind=news&slug=ami-3rd-annual-general-meeting'],
  ['/news/archive/new-blog-post-4/', '/article?kind=news&slug=free-expert-led-asbestos-management-seminar-for-asbestos-professionals'],
  ['/News/Archive/AMISEMINAR', '/article?kind=news&slug=free-asbestos-best-practice-seminar-for-asbestos-professionals'],
  ['/news/archive/asbestos-management-institute-celebrates-successful-fourth-annual-general-meeting/',
   '/article?kind=news&slug=asbestos-management-institute-celebrates-successful-fourth-annual-gene'],
  ['/support/amiagm2026/', '/videos'],
  ['/support/hse-publications/', '/resources'],
  ['/support/discussion-forum/', '/forum'],
  ['/events/', '/news?kind=event'],
  ['/about-us/', '/about'],
  ['/membership/categories/', '/membership#grades'],
  ['/membership/professional-conduct/', '/professional-conduct'],
]) {
  const r = await go(from);
  ok(r.status === 301 && r.headers.get('Location') === 'https://ami.uk.com' + want, `${from} goes to ${want}, got ${r.status} ${r.headers.get('Location')}`);
}
// The new site's own pages are not redirected away.
for (const p of ['/support', '/news', '/videos', '/resources'])
  ok((await go(p)).status !== 301, `${p} is a page of its own, not a redirect`);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
