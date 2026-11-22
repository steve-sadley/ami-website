/* Does a published block actually reach the page it belongs to?

   WHY THIS IS A BROWSER AND NOT A READING OF THE CODE

   135 blocks across 11 pages, each addressed by a CSS selector that was written
   against the markup by a generator. A selector that matches the wrong element
   does not fail: it writes the right words into the wrong place, and the page
   still looks like a page. Nothing short of running it finds that.

   It also catches the one that has bitten this project twice: a page with no
   script of its own. The CPD scheme and the CSCS cards pages have none, which
   is exactly the shape the privacy notice was in when nothing called the reveal
   and the whole notice was invisible.

   HOW

   The bundle is served over a local HTTP server and the real page scripts run.
   Only `window.supabase.createClient` is replaced, so the real `sb` getter, the
   real applyBlocks and the real sanitiser all run. Every block body is served
   with a marker in front of it, so a word on the screen can only have come from
   the database and never from the markup it replaced.

   Run:  node tests/13_blocks_browser.js [path-to-site]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

// The site bundle, which is beside this bundle rather than under it.
const ROOT = process.argv[2] || require('path').resolve(__dirname, '../../site');
const TYPES = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css',
                '.webp':'image/webp', '.png':'image/png', '.woff2':'font/woff2',
                '.ico':'image/x-icon', '.json':'application/json' };

// The generated map, read the same way the browser reads it.
// Found by its own name and its own closing line. blocks.js now carries the
// icon drawings after the map, so "first brace to last brace" would swallow
// both and fail to parse.
const BLOCK_MAP = (() => {
  const src = fs.readFileSync(path.join(ROOT, 'assets/blocks.js'), 'utf8');
  const a = src.indexOf('const BLOCK_MAP = ') + 'const BLOCK_MAP = '.length;
  return JSON.parse(src.slice(a, src.indexOf('\n};', a) + 2));
})();

// The seeded items, so a list is served in the shape the database really holds,
// with a marker on the words that identify each item.
const SEED = (() => {
  // 0035 seeded the first eleven pages; 0065 seeded professional conduct,
  // committees, guidance and the membership page's standards cards.
  const mig = ['0035_page_copy_is_content.sql', '0065_media_documents_and_pages.sql']
    .map(f => fs.readFileSync(path.resolve(__dirname, '../supabase/migrations/' + f), 'utf8')).join('\n');
  const out = {};
  const re = /\('([^']+)', '([^']+)', null, '((?:[^']|'')*)'::jsonb/g;
  let m;
  while ((m = re.exec(mig))) out[m[1] + '.' + m[2]] = JSON.parse(m[3].replace(/''/g, "'"));
  return out;
})();
const KEYWORD = { card: 'title', step: 'title', faq: 'question', bullet: 'text' };

const MARK = 'ZQX';
let pass = 0, fail = 0;
const ok = (cond, what) => {
  if (cond) { pass++; }
  else { fail++; console.log('  FAIL  ' + what); }
};

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

// What the stub serves for a page: every key in the map, with a marker.
function rowsFor(pageKey){
  return Object.entries(BLOCK_MAP[pageKey]).map(([key, [sel, kind, type]]) => {
    if (kind === 'links')
      return { page_key: pageKey, block_key: key, body: null,
               items: [{ label: MARK + ' one', href: '/one' },
                       { label: MARK + ' two', href: 'https://example.org/two' }] };
    if (kind === 'list') {
      const word = KEYWORD[type];
      const items = (SEED[pageKey + '.' + key] || []).map((it, i) =>
        Object.assign({}, it, { [word]: `${MARK} ${key} ${i + 1}` }));
      return { page_key: pageKey, block_key: key, body: null, items };
    }
    if (kind === 'line')
      return { page_key: pageKey, block_key: key, body: MARK + ' ' + key, items: null };
    if (kind === 'image')
      return { page_key: pageKey, block_key: key, body: `pages/2026/zqx-${pageKey}-${key}.webp`, items: null };
    return { page_key: pageKey, block_key: key, items: null,
             body: `<p>${MARK} ${key} first</p><p>${MARK} ${key} second <a href="/register">a link</a></p>` };
  });
}

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();

  for (const [pageKey, map] of Object.entries(BLOCK_MAP)) {
    const url = base + (pageKey === 'home' ? '/' : '/' + pageKey);
    const page = await browser.newPage();
    // A photograph is loaded before it is swapped in, so the bucket has to
    // answer. Any picture from it gets a one pixel PNG.
    await page.route('**/storage/v1/object/public/**', r => r.fulfill({ contentType: 'image/png',
      body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64') }));
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));

    await page.addInitScript(rows => {
      // Only the client is a stand in. Everything else on the page is real.
      window.__rows = rows;
      /* The real client lets you chain select, eq, order, limit, range and in
         in any order and await the result at any point. The stub does the same
         by answering every method with itself and being a thenable, which is
         the only shape that does not have to know which pages chain what. */
      const result = table => {
        const data = table === 'public_page' ? window.__rows : [];
        const chain = new Proxy(function(){}, {
          get(_, prop){
            if (prop === 'then') return r => Promise.resolve({ data, error: null }).then(r);
            if (prop === 'catch' || prop === 'finally') return () => chain;
            return () => chain;
          },
          apply(){ return chain; },
        });
        return chain;
      };
      Object.defineProperty(window, 'supabase', {
        configurable: true,
        value: { createClient: () => ({
          from: table => result(table),
          auth: { getSession: () => Promise.resolve({ data: { session: null } }),
                  getUser: () => Promise.resolve({ data: { user: null } }),
                  onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }) },
          rpc: () => Promise.resolve({ data: null, error: null }),
        }) },
      });
    }, rowsFor(pageKey));

    await page.goto(url, { waitUntil: 'load' });
    await page.waitForTimeout(700);

    console.log('\n' + pageKey);
    ok(errors.length === 0, `${pageKey}: no page errors (${errors[0] || ''})`);

    for (const [key, [sel, kind, type]] of Object.entries(map)) {
      const got = await page.evaluate(([sel, kind]) => {
        // The browser's own pickBlocks, so the test cannot disagree with the
        // thing it is testing about what a selector means.
        const els = window.pickBlocks ? window.pickBlocks(sel) : [];
        if (!els.length) return { none: true };
        if (kind === 'links')
          return { links: els.map(a => ({ t: a.textContent.trim(), h: a.getAttribute('href'),
                                          tg: a.getAttribute('target') })) };
        if (kind === 'image')
          return { bg: (els[0].dataset.bg || '') + ' ' + (els[0].style.backgroundImage || '') };
        if (kind === 'list')
          return { list: els.map(e => {
            const k = e.querySelector('h3, h4, summary');
            return (k ? k.textContent : e.textContent).trim();
          }) };
        return { text: els[0].textContent, html: els[0].innerHTML,
                 tag: els[0].tagName, count: els.length,
                 near: els[0].parentElement ? els[0].parentElement.innerHTML : '' };
      }, [sel, kind]);

      if (kind === 'line') {
        ok(!got.none && got.text.trim() === MARK + ' ' + key,
           `${pageKey}.${key}: line shows the block, got "${(got.text||'').trim().slice(0,40)}"`);
      } else if (kind === 'rich') {
        ok(!got.none && got.html.includes(MARK), `${pageKey}.${key}: rich shows the block`);
        ok(!got.none && got.html.includes('href="/register"'),
           `${pageKey}.${key}: the internal link in the block survived`);
      } else if (kind === 'prose') {
        ok(!got.none && got.near.includes(MARK + ' ' + key + ' first')
                     && got.near.includes(MARK + ' ' + key + ' second'),
           `${pageKey}.${key}: prose replaced the run with both paragraphs`);
      } else if (kind === 'image') {
        ok(!got.none && got.bg.includes(`/storage/v1/object/public/public-media/pages/2026/zqx-${pageKey}-${key}.webp`),
           `${pageKey}.${key}: the photograph is the block's, got ${(got.bg || '').slice(-90)}`);
        ok(!got.none && /gradient/.test(got.bg) === /gradient/.test(
             fs.readFileSync(path.join(ROOT, pageKey === 'home' ? 'index.html' : pageKey + '.html'), 'utf8')
               .match(new RegExp('class="[^"]*' + (key === 'banner_photo' ? 'pbanner img' : key === 'band_photo' ? 'band ph' : 'pic ph') + '[\\s\\S]{0,400}'))[0]),
           `${pageKey}.${key}: and the wash over it is still there`);
      } else if (kind === 'list') {
        const want = (SEED[pageKey + '.' + key] || []).map((_, i) => `${MARK} ${key} ${i + 1}`);
        ok(!got.none && JSON.stringify(got.list) === JSON.stringify(want),
           `${pageKey}.${key}: the list shows every item from the block, in order, got ${
             got.none ? 'nothing' : JSON.stringify(got.list).slice(0, 80)}`);
      } else if (kind === 'links') {
        ok(!got.none && got.links.length === 2,
           `${pageKey}.${key}: two buttons, got ${got.none ? 0 : got.links.length}`);
        if (!got.none && got.links.length === 2) {
          ok(got.links[0].h === '/one' && got.links[0].tg === null,
             `${pageKey}.${key}: our own address, same tab`);
          ok(got.links[1].h === 'https://example.org/two' && got.links[1].tg === '_blank',
             `${pageKey}.${key}: an outside address, new tab`);
        }
      }
    }

    /* The action buttons must still be there. prose removes paragraphs, and a
       paragraph on these pages is sometimes nothing but a button: on Membership
       the whole of "Start your application" is one. Replacing the prose and
       taking the button with it would read as a design decision. */
    const file = pageKey === 'home' ? 'index.html' : pageKey + '.html';
    const written = (fs.readFileSync(path.join(ROOT, file), 'utf8')
                       .match(/class="btn[^"]*"/g) || []).length;
    const btns = await page.evaluate(() => document.querySelectorAll('main .btn').length);
    ok(btns >= written,
       `${pageKey}: every button written in the markup is still on the page (${btns} of ${written})`);

    await page.close();
  }

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
