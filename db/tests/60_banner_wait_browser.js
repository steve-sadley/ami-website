/* The banner wait (site 76), in a real browser, under the site's real headers.

   Found by Steve, 1 November 2026: the office changed the About page's banner
   picture, and every visit showed the bundle's old picture for a moment before
   the new one replaced it. The banner now shows only its dark wash until the
   right picture has loaded, and the bundle's picture after 1.5 seconds if the
   database never answers.

   The banner's computed background is sampled every 25ms from the first
   moment, so a flash of the old picture lasting a single frame would be seen.

   Run:  node tests/60_banner_wait_browser.js [path-to-site]
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


const STUB = (mode) => `
const res = (data, error) => Promise.resolve({ data, error: error || null });
const NEW = { page_key:'about', block_key:'banner_photo', kind:'image', body:'pages/2026/new-banner.webp', items:null };
function q(name){
  const chain = new Proxy({}, { get(_, p){
    if (p === 'then') return r => {
      if (name !== 'public_page') return res([]).then(r);
      if ('${mode}' === 'never') return new Promise(() => {});
      if ('${mode}' === 'same') return new Promise(ok => setTimeout(() => ok({ data: [], error: null }), 300)).then(r);
      return new Promise(ok => setTimeout(() => ok({ data: [NEW], error: null }), 400)).then(r);
    };
    return () => chain;
  } });
  return chain;
}
window.__client = { from: q, rpc: () => res(null),
  auth: { getSession: () => res({ session: null }), getUser: () => res({ user: null }),
          onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }) },
  storage: { from: () => ({ getPublicUrl: p => ({ data: { publicUrl: p } }) }) },
  channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel: () => {} };
window.__seen = [];
const sample = () => {
  const b = document.querySelector('.pbanner.img');
  if (b) { const m = getComputedStyle(b).backgroundImage.match(/url\\("?([^")]*)/); window.__seen.push(m ? m[1] : 'wash'); }
  if (window.__seen.length < 160) setTimeout(sample, 25);
};
document.addEventListener('DOMContentLoaded', sample);
Object.defineProperty(window, 'supabase', { configurable: true, value: { createClient: () => window.__client } });
`;

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();
  const run = async (mode, wait = 2600) => {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    // the uploaded picture, slow to arrive, as a real one may be
    await page.route('**/storage/v1/object/public/**', async r => {
      await new Promise(ok => setTimeout(ok, 250));
      r.fulfill({ contentType: 'image/png', body: Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64') });
    });
    await page.addInitScript(STUB(mode));
    await page.goto(base + '/about', { waitUntil: 'load' });
    await page.waitForTimeout(wait);
    const seen = await page.evaluate(() => window.__seen);
    await page.close();
    return { seen, errors };
  };
  const firstPhoto = seen => seen.find(x => x !== 'wash') || '';

  // a new picture chosen by the office
  let r = await run('new');
  const old = r.seen.filter(x => /photo-team/.test(x)).length;
  ok(r.seen[0] === 'wash', 'the banner starts as the dark wash, not the bundle\'s picture: ' + r.seen[0]);
  ok(old === 0, 'the old picture is never drawn, not for a single frame: seen ' + old + ' times');
  ok(/new-banner\.webp/.test(firstPhoto(r.seen)) && /new-banner\.webp/.test(r.seen[r.seen.length - 1]),
     'the first picture drawn is the office\'s one, and it stays: ' + firstPhoto(r.seen));
  ok(r.errors.length === 0, 'no page error: ' + (r.errors[0] || ''));

  // the office has not changed it: the bundle's picture, promptly
  r = await run('same');
  const at = r.seen.findIndex(x => /photo-team/.test(x));
  ok(at > 0 && at * 25 < 1200, 'when nothing was changed the bundle\'s picture shows as soon as the read answers: after about ' + at * 25 + 'ms');

  // the database never answers: the bundle's picture after the wait, never an empty banner
  r = await run('never');
  const at2 = r.seen.findIndex(x => /photo-team/.test(x));
  ok(at2 * 25 >= 1300 && at2 * 25 <= 2200 && /photo-team/.test(r.seen[r.seen.length - 1]),
     'if the database never answers, the bundle\'s picture shows after about 1.5 seconds: ' + at2 * 25 + 'ms');

  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
