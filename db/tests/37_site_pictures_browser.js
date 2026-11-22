/* The public pages' photographs since 0046, in a browser.

   Each home page headline carries its own photograph and label, so headline n
   shows photograph n whatever the count; and an article, event, guidance or
   video with no picture of its own shows the default the database chose from
   the library, the same one every time.

   Only window.supabase is replaced.

   Run:  node tests/37_site_pictures_browser.js [path-to-site]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const ROOT = process.argv[2] || path.resolve(__dirname, '../../site');
const TYPES = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css',
                '.webp':'image/webp', '.png':'image/png', '.woff2':'font/woff2',
                '.ico':'image/x-icon', '.json':'application/json' };
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };
function serve(){
  return new Promise(resolve => {
    const srv = http.createServer((req, res) => {
      let p = decodeURIComponent(req.url.split('?')[0]);
      if (p === '/') p = '/index.html';
      if (!path.extname(p)) p += '.html';
      const file = path.join(ROOT, p);
      if (!file.startsWith(ROOT) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
      res.end(fs.readFileSync(file));
    });
    srv.listen(0, () => resolve(srv));
  });
}


const DATA = {
  public_hero: [
    { statement: 'ZQX first', sort_order: 1, image_path: 'library/2026/zqx-one.webp', badge: 'ZQX label one' },
    { statement: 'ZQX second', sort_order: 2, image_path: '/assets/photo-site.webp', badge: 'ZQX label two' },
    { statement: 'ZQX third', sort_order: 3, image_path: 'library/2026/zqx-three.webp', badge: 'ZQX label three' },
    { statement: 'ZQX fourth', sort_order: 4, image_path: 'library/2026/zqx-four.webp', badge: 'ZQX label four' },
    { statement: 'ZQX fifth', sort_order: 5, image_path: 'library/2026/zqx-five.webp', badge: 'ZQX label five' } ],
  public_content: [
    { kind: 'news', slug: 'zqx-a', title: 'ZQX with its own', summary: 's', published_at: new Date().toISOString(),
      category: 'News', image_path: 'news/2026/zqx-own.webp', fallback_path: 'library/2026/zqx-default.webp' },
    { kind: 'news', slug: 'zqx-b', title: 'ZQX default', summary: 's', published_at: new Date(Date.now() - 864e5).toISOString(),
      category: 'News', image_path: null, fallback_path: 'library/2026/zqx-default.webp' },
    { kind: 'news', slug: 'zqx-c', title: 'ZQX built in default', summary: 's', published_at: new Date(Date.now() - 2 * 864e5).toISOString(),
      category: 'News', image_path: null, fallback_path: '/assets/photo-team.webp' },
    { kind: 'news', slug: 'zqx-d', title: 'ZQX hostile', summary: 's', published_at: new Date(Date.now() - 3 * 864e5).toISOString(),
      category: 'News', image_path: null, fallback_path: "x');background:url(evil" } ],
};

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();
  const open = async p => {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/storage/v1/object/public/**', r => r.fulfill({ contentType: 'image/png',
      body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64') }));
    await page.addInitScript(data => {
      // Returns only the columns asked for, as the real database does, so a
      // page that forgets to ask for a column does not get it anyway.
      const result = table => {
        let cols = null;
        const chain = new Proxy(function(){}, { get(_, prop){
          if (prop === 'then') return r => {
            const d = (data[table] || []).map(row => !cols ? row
              : Object.fromEntries(Object.entries(row).filter(([k]) => cols.includes(k))));
            return Promise.resolve({ data: d, error: null }).then(r);
          };
          if (prop === 'select') return c => { if (c && c !== '*') cols = c.split(',').map(x => x.trim()); return chain; };
          return () => chain; }, apply(){ return chain; } });
        return chain;
      };
      Object.defineProperty(window, 'supabase', { configurable: true, value: { createClient: () => ({
        from: t => result(t),
        auth: { getSession: () => Promise.resolve({ data: { session: null } }),
                getUser: () => Promise.resolve({ data: { user: null } }),
                onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }) },
        rpc: () => Promise.resolve({ data: null, error: null }) }) } });
    }, DATA);
    await page.goto(base + p, { waitUntil: 'load' });
    await page.waitForTimeout(1200);
    return { page, errors };
  };

  // ---- the home page headline -----------------------------------------------
  {
    const { page, errors } = await open('/');
    const h = await page.evaluate(() => ({
      shots: [...document.querySelectorAll('#heroPic .shot')].map(s => s.style.backgroundImage),
      badge: document.getElementById('heroBadge').textContent,
      words: [...document.querySelectorAll('.hrot-item')].map(w => w.textContent) }));
    ok(h.words.length === 5 && h.shots.length === 5,
       'five headlines get five photographs, one each, where there used to be four whatever the count: ' + h.shots.length);
    ok(/public-media\/library\/2026\/zqx-one\.webp/.test(h.shots[0]) && h.badge === 'ZQX label one',
       'the first headline shows its own photograph and label at once');
    ok(/\/assets\/photo-site\.webp\?v=/.test(h.shots[1]) && /zqx-five\.webp/.test(h.shots[4]),
       'and each later headline its own, built in or uploaded');
    ok(errors.length === 0, 'with no errors: ' + (errors[0] || ''));
    await page.close();
  }

  // ---- an item with no picture of its own --------------------------------------
  {
    const { page, errors } = await open('/news');
    const pics = await page.evaluate(() => [...document.querySelectorAll('.news-feature .pic, .nrow .th')]
      .map(x => x.style.backgroundImage));
    ok(/news\/2026\/zqx-own\.webp/.test(pics[0]), 'an item with its own picture shows it');
    ok(/library\/2026\/zqx-default\.webp/.test(pics[1]), 'an item with none shows the default the database chose');
    ok(/\/assets\/photo-team\.webp\?v=/.test(pics[2]), 'a built in photograph as a default is found on the site');
    ok(pics[3] && !/evil/.test(pics[3]) && /\/assets\/photo-/.test(pics[3]),
       'and an address that could break out of the CSS is refused for the site\'s own: ' + pics[3]);
    ok(errors.length === 0, 'with no errors: ' + (errors[0] || ''));
    await page.close();
  }

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
