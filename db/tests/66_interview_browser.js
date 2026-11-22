/* Booking the professional interview (0064), in a real browser, under the
   site's real headers.

   The Worker is answered by the test, so what is proved is the page: it reads
   the token from after the #, never puts it in an address, shows the times in
   UK time grouped by day, books, recovers from a time somebody else has just
   taken, shows a booking with its Teams link, changes and cancels it, keeps
   the database's words as words, and is painted rather than left invisible.

   Run:  node tests/66_interview_browser.js [path-to-site]
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



const TOKEN = 'Abc_def-0123456789Abc_def-0123456789Abcdefg';
// 4 July 2030 is in British Summer Time, so 09:00 UTC must read 10:00.
const SLOTS = [
  { id: 's1', starts_at: '2030-07-04T09:00:00Z', ends_at: '2030-07-04T10:15:00Z', minutes: 75 },
  { id: 's2', starts_at: '2030-07-04T13:00:00Z', ends_at: '2030-07-04T14:15:00Z', minutes: 75 },
  { id: 's3', starts_at: '2030-07-05T09:00:00Z', ends_at: '2030-07-05T10:15:00Z', minutes: 75 },
];

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();

  const open = async (hash, answer) => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.__errors = []; page.__posts = []; page.__urls = [];
    page.on('pageerror', e => page.__errors.push(String(e)));
    page.on('request', r => page.__urls.push(r.url()));
    await page.addInitScript(() => {
      window.__csp = [];
      document.addEventListener('securitypolicyviolation', e => window.__csp.push(e.violatedDirective + ' ' + e.blockedURI));
    });
    await page.route('**/api/interview/**', async route => {
      const which = route.request().url().split('/api/interview/')[1];
      const body = JSON.parse(route.request().postData() || '{}');
      page.__posts.push({ which, body });
      const [status, out] = answer(which, body, page.__posts);
      await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(out) });
    });
    await page.goto(base + '/interview' + hash, { waitUntil: 'load' });
    await page.waitForTimeout(600);
    return page;
  };
  const text = page => page.evaluate(() => document.getElementById('panel').innerText);
  const painted = page => page.evaluate(async () => {
    const el = document.getElementById('panel');
    el.scrollIntoView(); await new Promise(r => setTimeout(r, 900));
    return Number(getComputedStyle(el).opacity);
  });
  const clean = async page => page.__errors.length === 0 && (await page.evaluate(() => window.__csp)).length === 0;

  // 1. no token
  let page = await open('', () => [500, {}]);
  ok(/not complete/.test(await text(page)) && page.__posts.length === 0, 'without a token it says the link is not complete and asks nothing');
  await page.close();

  // 2. the times, and booking one
  const fresh = (which) => which === 'slots'
    ? [200, { given_name: 'Ann', reference: 'AMI-2030-0001', notice_hours: 24, booking: null, slots: SLOTS }]
    : which === 'book'
    ? [200, { booked: true, starts_at: SLOTS[0].starts_at, ends_at: SLOTS[0].ends_at, join_url: 'https://teams.microsoft.com/l/meetup-join/abc' }]
    : [500, {}];
  page = await open('#t=' + TOKEN, fresh);
  ok(page.__posts[0] && page.__posts[0].which === 'slots' && page.__posts[0].body.token === TOKEN, 'the token goes to the Worker in the body');
  ok(!page.__urls.some(u => u.includes(TOKEN)), 'and never in an address');
  const t = await text(page);
  ok(/Thursday 4 July 2030/.test(t) && /Friday 5 July 2030/.test(t), 'times are grouped by day');
  const labels = await page.$$eval('[data-slot]', b => b.map(x => x.textContent.trim()));
  ok(labels.join(',') === '10:00,14:00,10:00', 'in UK time, summer time included: ' + labels.join(','));
  ok(/1 hour 15 minutes/.test(t), 'and says how long the interview lasts');
  ok(await painted(page) > 0.95, 'the panel is painted, not left at opacity 0');
  await page.click('[data-slot="s2"]');
  ok(/Thursday 4 July 2030 at 14:00/.test(await text(page)), 'choosing a time asks to confirm it');
  await page.click('#book'); await page.waitForTimeout(300);
  ok(page.__posts.some(p => p.which === 'book' && p.body.slot === 's2' && p.body.token === TOKEN), 'booking sends the slot and the token');
  const done = await text(page);
  ok(/Your interview is booked/.test(done) && /calendar invitation/.test(done), 'and says it is booked and an invitation is coming');
  ok(await page.$('a[href="https://teams.microsoft.com/l/meetup-join/abc"]'), 'with the Teams link');
  ok(await clean(page), 'no page error or policy violation');
  await page.close();

  // 3. a time taken by somebody else a moment ago
  page = await open('#t=' + TOKEN, (which, body, posts) => {
    if (which === 'book') return [409, { error: 'Somebody has just booked that time. Please choose another.' }];
    const n = posts.filter(p => p.which === 'slots').length;
    return [200, { given_name: 'Ann', reference: 'R', booking: null, slots: n > 1 ? SLOTS.slice(1) : SLOTS }];
  });
  await page.click('[data-slot="s1"]'); await page.click('#book'); await page.waitForTimeout(400);
  ok(/Somebody has just booked that time/.test(await text(page)), 'a taken time is explained in the database\'s words');
  ok(!(await page.$('[data-slot="s1"]')) && await page.$('[data-slot="s2"]'), 'and the list is drawn again without it');
  await page.close();

  // 4. already booked: change and cancel
  const booked = { starts_at: SLOTS[2].starts_at, ends_at: SLOTS[2].ends_at, minutes: 75,
                   join_url: 'https://teams.microsoft.com/l/x', can_change: true };
  page = await open('#t=' + TOKEN, (which, body, posts) => {
    if (which === 'cancel') return [200, { cancelled: true }];
    const cancelled = posts.some(p => p.which === 'cancel');
    return [200, { given_name: 'Ann', reference: 'R', booking: cancelled ? null : booked, slots: SLOTS.slice(0, 2) }];
  });
  ok(/Your interview/.test(await text(page)) && /Friday 5 July 2030 at 10:00/.test(await text(page)), 'a booking is shown, in UK time');
  await page.click('#change'); await page.waitForTimeout(300);
  ok(/Choose a new time/.test(await text(page)) && /stays booked until you confirm/.test(await text(page)),
     'changing offers the times and says the old one stands until a new one is confirmed');
  await page.click('#back'); await page.waitForTimeout(100);
  await page.click('#cancel');
  ok(!page.__posts.some(p => p.which === 'cancel'), 'the first press on Cancel only asks to be sure');
  await page.click('#cancel'); await page.waitForTimeout(400);
  ok(page.__posts.some(p => p.which === 'cancel' && p.body.token === TOKEN), 'the second cancels');
  ok(/has been cancelled/.test(await text(page)) && await page.$('[data-slot]'), 'and the times are offered again');
  await page.close();

  // 5. too close to change
  page = await open('#t=' + TOKEN, () => [200, { given_name: 'Ann', reference: 'R',
    booking: Object.assign({}, booked, { can_change: false }), slots: [] }]);
  ok(!(await page.$('#change')) && !(await page.$('#cancel')) && /too close to change online/.test(await text(page)),
     'inside the notice period there is no Change or Cancel, and it says why');
  await page.close();

  // 6. words stay words
  page = await open('#t=' + TOKEN, () => [200, { given_name: '<img src=x onerror="window.__pwned=1">Ann',
    reference: '<script>window.__pwned=2</script>', booking: null, slots: SLOTS }]);
  ok(!(await page.$('#panel img')) && !(await page.$('#panel script')) && !(await page.evaluate(() => window.__pwned)),
     'a name or reference carrying markup is not run');
  ok(/<img src=x/.test(await text(page)), 'and it survives as words');
  await page.close();

  // 7. the Worker refusing the link
  page = await open('#t=' + TOKEN, () => [404, { error: 'This booking link is not recognised. If you were sent a newer one, please use that.' }]);
  ok(/not recognised/.test(await text(page)) && /reply to your/.test(await text(page)), 'a link the database refuses says so, and what to do');
  ok(await clean(page), 'still no page error or policy violation');
  await page.close();

  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
