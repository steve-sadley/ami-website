/* Eight to a page (site 90): news and events, the video library and the
   guidance documents, in a real browser under the site's real headers.

   Run:  node tests/74_pagination_browser.js [path-to-site]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = process.argv[2] || path.resolve(__dirname, '../../site');
const TYPES = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.webp':'image/webp',
                '.png':'image/png', '.woff2':'font/woff2', '.ico':'image/x-icon', '.json':'application/json',
                '.webmanifest':'application/manifest+json' };
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

// The headers for /*, as Pages applies them.
const HEADERS = (() => {
  const out = {}; let on = false;
  for (const line of fs.readFileSync(path.join(ROOT, '_headers'), 'utf8').split('\n')) {
    if (/^\/\*\s*$/.test(line)) { on = true; continue; }
    if (!line.trim() || /^\s*#/.test(line)) continue;
    if (!/^\s/.test(line)) { on = false; continue; }
    const m = on && line.match(/^\s+([A-Za-z-]+):\s*(.*)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
})();

function serve(){
  return new Promise(resolve => {
    const srv = http.createServer((req, res) => {
      let p = decodeURIComponent(req.url.split('?')[0]);
      // The Worker's two rewrites, which have no query string to carry.
      if (/^\/t\/[^/]+\/?$/.test(p)) p = '/thread.html';
      else if (/^\/m\/[^/]+\/?$/.test(p)) p = '/member.html';
      else if (p === '/') p = '/index.html';
      else if (!path.extname(p)) p += '.html';
      const file = path.join(ROOT, p);
      if (!file.startsWith(ROOT) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, Object.assign({ 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' },
                                       HEADERS));
      res.end(fs.readFileSync(file));
    });
    srv.listen(0, () => resolve(srv));
  });
}





const DAY = 864e5, NOW = Date.now();
const item = (i, extra) => Object.assign({ slug: 'p-' + i, title: 'Item ' + i, kind: 'news', summary: 's',
  published_at: new Date(NOW - i * DAY).toISOString() }, extra);
const NEWS = Array.from({ length: 20 }, (_, i) => item(i + 1));
// Ten upcoming, six past: the Previous events line falls on the second page.
const EVENTS = Array.from({ length: 16 }, (_, i) => item(100 + i, { kind: 'event',
  starts_at: new Date(NOW + (i < 10 ? (i + 1) : -(i - 9)) * DAY).toISOString() }));
const VIDEOS = Array.from({ length: 9 }, (_, i) => item(200 + i, { kind: 'video', vimeo_id: '1234567' + i }));
const GUIDES = Array.from({ length: 17 }, (_, i) => ({ slug: 'g' + i, title: (i === 16 ? 'Needle ' : 'Guide ') + i,
  category: i % 2 ? 'Removal' : 'Surveying', summary: 's', published_at: new Date(NOW - i * DAY).toISOString(),
  members_only: false, has_document: true, file_type: 'pdf', file_size: 1000 }));
const MANY = Array.from({ length: 80 }, (_, i) => item(300 + i));

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();
  const open = async (p, pick) => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.__errors = [];
    page.on('pageerror', e => page.__errors.push(String(e)));
    await page.addInitScript(() => { window.__csp = [];
      document.addEventListener('securitypolicyviolation', e => window.__csp.push(e.violatedDirective + ' ' + e.blockedURI)); });
    await page.route('**/rest/v1/**', r => r.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify(pick(r.request().url())) }));
    await page.route('**/auth/v1/**', r => r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }));
    await page.goto(base + p, { waitUntil: 'load' });
    await page.waitForTimeout(900);
    return page;
  };
  const clean = async page => page.__errors.length === 0 && (await page.evaluate(() => window.__csp)).length === 0;
  const pager = page => page.$$eval('#pager button', b => b.map(x => x.textContent.trim() + (x.classList.contains('on') ? '*' : '')).join(' '));
  const go = async (page, n) => { await page.click(`#pager [data-p="${n}"]`); await page.waitForTimeout(400); };
  const news = page => page.evaluate(() => ({ feat: !!document.querySelector('#feature .news-feature'),
    rows: document.querySelectorAll('#out > a').length, head: [...document.querySelectorAll('#out > *')].findIndex(e => /Previous events/.test(e.textContent) && e.tagName !== 'A'),
    titles: [...document.querySelectorAll('#out > a h3, #out > a h4')].map(h => h.textContent), n: document.getElementById('n').textContent }));
  const SEARCH = u => u.includes('public_content') ? (u.includes('kind=eq.video') ? VIDEOS : NEWS.concat(EVENTS)) : [];

  // news: 36 items, five pages
  let page = await open('/news', SEARCH);
  let s = await news(page);
  ok(s.feat && s.rows === 7, 'news page one is the feature and seven rows: ' + s.feat + ' ' + s.rows);
  ok(await pager(page) === '1* 2 3 4 5', 'with numbered pages under it: ' + await pager(page));
  ok(/1–8 of 36/.test(s.n), 'and the count says which part is showing: ' + s.n);
  await go(page, 2); s = await news(page);
  ok(!s.feat && s.rows === 8, 'page two is eight rows and no feature');
  ok(/[?&]page=2/.test(page.url()), 'the page is kept in the address');
  await go(page, 5); s = await news(page);
  ok(s.rows === 4 && /33–36 of 36/.test(s.n), 'the last page holds what is left: ' + s.rows);
  await page.click('[data-k="event"]'); await page.waitForTimeout(250); s = await news(page);
  ok(s.feat && s.rows === 7 && await pager(page) === '1* 2' && !/page=/.test(page.url()), 'changing the filter goes back to page one');
  ok(s.head === -1, 'ten upcoming events: no Previous events line on page one');
  await go(page, 2); s = await news(page);
  ok(s.head === 2 && s.rows === 8, 'on page two the line sits before the first past event: ' + s.head);
  ok(await clean(page), 'news raises no error and no policy violation');
  await page.close();

  page = await open('/news?page=3', SEARCH); s = await news(page);
  ok(!s.feat && s.rows === 8 && await pager(page) === '1 2 3* 4 5', 'a link to page three opens on page three');
  await page.close();
  page = await open('/news?page=99', SEARCH);
  ok(await pager(page) === '1 2 3 4 5*', 'a page past the end shows the last page');
  await page.close();

  page = await open('/news', u => u.includes('public_content') ? MANY : []);
  ok(await pager(page) === '1* 2 3 4 10' && (await page.$$('#pager .gap')).length === 1, 'ten pages: the ends stay reachable with a gap between');
  await go(page, 4); await go(page, 5);
  ok(await pager(page) === '1 4 5* 6 10' && (await page.$$('#pager .gap')).length === 2, 'and in the middle, a gap either side: ' + await pager(page));
  await page.close();

  page = await open('/news', u => u.includes('public_content') ? NEWS.slice(0, 6) : []);
  s = await news(page);
  ok(s.feat && s.rows === 5 && (await page.$$('#pager button')).length === 0, 'six items: one page and no numbers');
  await page.close();

  // videos: nine, two pages
  page = await open('/videos', SEARCH);
  const v = () => page.evaluate(() => ({ hero: !!document.querySelector('#hero .vhero'), cards: document.querySelectorAll('#out .vcard').length }));
  let vv = await v();
  ok(vv.hero && vv.cards === 7 && await pager(page) === '1* 2', 'videos page one is the featured recording and seven cards: ' + JSON.stringify(vv));
  await go(page, 2); vv = await v();
  ok(!vv.hero && vv.cards === 1, 'page two is the ninth, with no feature');
  await page.click('#out .vcard'); await page.waitForTimeout(250);
  ok(await page.evaluate(() => /player\.vimeo\.com\/video\/12345678/.test((document.querySelector('iframe') || {}).src || '')), 'a card on page two still plays');
  ok(await clean(page), 'videos raise no error and no policy violation');
  await page.close();

  // guidance: seventeen, three pages
  page = await open('/guidance', u => u.includes('public_guidance') ? GUIDES : []);
  const docs = () => page.$$eval('.doc h3', h => h.length);
  ok(await docs() === 8 && await pager(page) === '1* 2 3', 'guidance shows eight documents a page');
  await go(page, 3);
  ok(await docs() === 1, 'and the last page the seventeenth');
  await page.fill('#q', 'needle'); await page.waitForTimeout(250);
  ok(await docs() === 1 && await pager(page) === '', 'a search goes back to page one and finds what was on page three');
  await page.fill('#q', ''); await page.waitForTimeout(250); await go(page, 2);
  await page.click('[data-cat="Surveying"]'); await page.waitForTimeout(250);
  ok(await docs() === 8 && await pager(page) === '1* 2', 'a category pill goes back to page one: ' + await pager(page));
  ok(await clean(page), 'guidance raises no error and no policy violation');
  await page.close();

  // the register keeps 25 a page, through the same numbers
  const REG = Array.from({ length: 60 }, (_, i) => ({ given_name: 'A', family_name: 'Name' + String(i).padStart(2, '0'),
    membership_number: 'AMI' + i, grade: 'Full Member', employer: 'E', joined_year: 2020 }));
  page = await open('/register', u => u.includes('public_register') ? REG : []);
  ok(await page.$$eval('#out tr', r => r.length) >= 25 && await pager(page) === '1* 2 3', 'the register keeps 25 a page: ' + await pager(page));
  await go(page, 3);
  ok(await pager(page) === '1 2 3*' && await clean(page), 'and moves through its pages with no error');
  await page.close();

  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
