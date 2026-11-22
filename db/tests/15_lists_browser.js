/* The repeating blocks, drawn by a real browser from rows that are awkward on
   purpose.

   Test 13 walks every block on every page with well formed rows and asserts the
   words arrive. This file asks the harder questions about lists, the ones where
   a renderer can put the right words on the screen and still be wrong:

     an item ADDED beyond what the markup has, which is a copy made after the
     reveal observer was handed the page, and so can be in the page and
     invisible (the privacy notice fault in a new place)
     a list with a hole in it, which must leave the markup alone rather than
     draw half a list with a heading repeated from the card it was copied from
     positions: the number on a step and which question starts open
     an icon by name, and a name the bundle does not know
     a card that loses its button, gains one, gains bullets or loses its words
     markup inside a bullet or an answer, which is allowed to be bold and a link
     and nothing else

   Only window.supabase is replaced. The real sb getter, applyBlocks, paintList,
   the sanitiser and the reveal all run.

   Run:  node tests/15_lists_browser.js [path-to-site]
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

const ICONS = (() => {
  const src = fs.readFileSync(path.join(ROOT, 'assets/blocks.js'), 'utf8');
  const a = src.indexOf('const BLOCK_ICONS = ') + 'const BLOCK_ICONS = '.length;
  return JSON.parse(src.slice(a, src.indexOf('\n};', a) + 2));
})();

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

async function open(browser, base, pagePath, rows, height, extra){
  const page = await browser.newPage({ viewport: { width: 1440, height: height || 900 } });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  // A photograph is loaded before it is swapped in, so the bucket has to
  // answer, and it has to be answering before the page starts.
  await page.route('**/storage/v1/object/public/**', r => r.fulfill({ contentType: 'image/png',
    body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64') }));
  await page.addInitScript(([rows, extra]) => {
    window.__rows = rows;
    window.__extra = extra || {};
    const result = table => {
      const data = table === 'public_page' ? window.__rows : (window.__extra[table] || []);
      const chain = new Proxy(function(){}, {
        get(_, prop){
          if (prop === 'then') return r => Promise.resolve({ data, error: null }).then(r);
          return () => chain;
        },
        apply(){ return chain; },
      });
      return chain;
    };
    Object.defineProperty(window, 'supabase', {
      configurable: true,
      value: { createClient: () => ({
        from: t => result(t),
        auth: { getSession: () => Promise.resolve({ data: { session: null } }),
                getUser: () => Promise.resolve({ data: { user: null } }),
                onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }) },
        rpc: () => Promise.resolve({ data: null, error: null }),
      }) },
    });
  }, [rows, extra]);
  await page.goto(base + pagePath, { waitUntil: 'load' });
  await page.waitForTimeout(600);
  page.__errors = errors;
  return page;
}

const row = (page_key, block_key, items) => ({ page_key, block_key, body: null, items });

// Is it PAINTED: on screen, and neither it nor anything above it at opacity 0.
// Text content would pass for an invisible card, which is the whole point.
async function painted(page, sel, n){
  return page.evaluate(async ([sel, n]) => {
    document.documentElement.style.scrollBehavior = 'auto';
    const el = document.querySelectorAll(sel)[n];
    if (!el) return { none: true };
    el.scrollIntoView({ block: 'center' });
    await new Promise(r => setTimeout(r, 1200));
    let o = 1;
    for (let x = el; x && x.nodeType === 1; x = x.parentElement)
      o = Math.min(o, Number(getComputedStyle(x).opacity));
    const b = el.getBoundingClientRect();
    return { opacity: o, h: b.height };
  }, [sel, n]);
}

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();

  // ---- 1. Nine resource cards where the markup has six ---------------------
  console.log('\nsupport: nine cards where the markup has six');
  {
    const items = Array.from({ length: 9 }, (_, i) => ({
      icon: i === 7 ? 'not-an-icon' : 'clock', title: `Card ${i + 1}`,
      body: `Words ${i + 1}`, href: i === 8 ? 'javascript:alert(1)' : (i % 2 ? '/news' : 'https://example.org/' + i),
    }));
    const page = await open(browser, base, '/support', [row('support', 'resources', items)]);
    ok(!page.__errors.length, `no page errors (${page.__errors[0] || ''})`);
    const got = await page.evaluate(() => [...document.querySelectorAll('.support-grid .scard')].map(c => ({
      t: c.querySelector('h4').textContent, p: c.querySelector('p') && c.querySelector('p').textContent,
      h: c.getAttribute('href'), tg: c.getAttribute('target'), svg: c.querySelector('.sicon').innerHTML,
    })));
    ok(got.length === 9, `nine cards on the page, got ${got.length}`);
    ok(got.map(g => g.t).join() === items.map(i => i.title).join(), 'in the order they were given');
    ok(got.every((g, i) => g.p === items[i].body), 'each with its own words');
    ok(got[0].svg === ICONS.clock.replace(/^<svg[^>]*>|<\/svg>$/g, '') || got[0].svg.includes(ICONS.clock.slice(-60, -6)),
       'a named icon is the bundle\'s drawing');
    ok(got[7].svg.length > 20 && !got[7].svg.includes('not-an-icon'),
       'a name the bundle does not know leaves the drawing that was there');
    ok(got[1].h === '/news' && got[1].tg === null, 'our own page opens in the same tab');
    ok(got[0].h === 'https://example.org/0' && got[0].tg === '_blank', 'an outside page opens in a new one');
    ok(got[8].h === null, 'a javascript: address is refused and the card is not a link');
    const last = await painted(page, '.support-grid .scard', 8);
    ok(!last.none && last.opacity > 0.95 && last.h > 40,
       `the ninth card, a copy made after the page started, is painted (opacity ${last.opacity})`);
    await page.close();
  }

  // ---- 2. A list with a hole in it is not drawn ----------------------------
  console.log('\nmembership: a question with no answer');
  {
    const page = await open(browser, base, '/membership', [row('membership', 'faq', [
      { question: 'One', answer: 'First' }, { question: 'Two' }])]);
    const qs = await page.evaluate(() => [...document.querySelectorAll('.faq summary')].map(s => s.textContent.trim()));
    ok(qs.length === 6 && qs[0] === 'Who can join AMI?',
       `the markup's six questions stay, not half a list (got ${qs.length}, "${qs[0]}")`);
    await page.close();
  }
  {
    const page = await open(browser, base, '/membership', [row('membership', 'faq', 'not a list')]);
    const qs = await page.evaluate(() => document.querySelectorAll('.faq details').length);
    ok(qs === 6, 'items that are not a list leave the markup alone');
    ok(!page.__errors.length, 'and raise nothing');
    await page.close();
  }

  // ---- 3. Positions ---------------------------------------------------------
  console.log('\nmembership: positions are positions');
  {
    const faq = Array.from({ length: 8 }, (_, i) => ({
      question: `Q${i + 1}`,
      answer: i === 0
        ? 'See <a href="/register">the register</a>, <b>bold</b> <img src=x onerror="window.__xss=1"><script>window.__xss=2</script><p>para</p>'
        : `A${i + 1}`,
    }));
    const steps = [{ title: 'Third', body: 'c' }, { title: 'First', body: 'a' }, { title: 'Second', body: 'b' }];
    // Steps arrive carrying numbers of their own, which must be ignored.
    steps.forEach((s, i) => { s.n = 9 - i; });
    const page = await open(browser, base, '/membership', [
      row('membership', 'faq', faq), row('membership', 'steps', steps)]);
    const got = await page.evaluate(() => ({
      open: [...document.querySelectorAll('.faq details')].map(d => d.open),
      a0: document.querySelector('.faq details p').innerHTML,
      n: [...document.querySelectorAll('.steprow .step .n')].map(n => n.textContent),
      t: [...document.querySelectorAll('.steprow .step h4')].map(n => n.textContent),
      xss: window.__xss || 0,
    }));
    ok(got.open.length === 8, `eight questions, got ${got.open.length}`);
    ok(got.open[0] === true && got.open.slice(1).every(o => !o),
       'only the first starts open, including the two that were copies');
    ok(got.a0.includes('<a href="/register">the register</a>'), 'a link to our own page survives in an answer');
    ok(got.a0.includes('<b>bold</b>'), 'bold survives');
    ok(!/<img|<script|<p>|onerror/i.test(got.a0) && got.xss === 0,
       'an image, a script and a paragraph do not, and nothing ran');
    ok(got.a0.includes('para'), 'the words of the paragraph do');
    ok(got.n.join() === '1,2,3', `step numbers come from the order, got ${got.n.join()}`);
    ok(got.t.join() === 'Third,First,Second', 'and the steps are in the order given');
    await page.close();
  }

  // ---- 4. Cards changing shape ---------------------------------------------
  console.log('\ncscs-cards: cards gaining and losing parts');
  {
    const items = [
      // was body plus button: now bullets, no body, no button
      { icon: 'people', title: 'A', bullets: ['<b>Term</b><br>Words', 'Plain <script>x()</script>'] },
      // was bullets plus button: now body only, button kept
      { icon: 'shield', title: 'B', body: 'Just words', href: '/contact', link_label: 'Ask us' },
      // was bullets plus button: now both, and an outside link
      { icon: 'search', title: 'C', body: 'Lead in', bullets: ['One'], href: 'https://www.atac.org.uk/', link_label: 'Go' },
    ];
    const page = await open(browser, base, '/cscs-cards', [row('cscs-cards', 'cards', items)]);
    const got = await page.evaluate(() => [...document.querySelectorAll('.support-grid .scard')].map(c => ({
      p: [...c.children].filter(x => x.tagName === 'P' && !x.querySelector('a')).map(x => x.textContent),
      li: [...c.querySelectorAll('ul li')].map(l => l.innerHTML),
      a: [...c.querySelectorAll('a.btn')].map(a => [a.textContent.trim(), a.getAttribute('href'), a.getAttribute('target')]),
      empty: [...c.children].filter(x => x.tagName === 'P' && !x.textContent.trim()).length,
      order: [...c.children].map(x => x.tagName).join(','),
    })));
    if (process.env.SHOT) {
      await page.evaluate(() => { document.documentElement.style.scrollBehavior = 'auto';
        document.querySelector('.support-grid').scrollIntoView({ block: 'start' }); });
      await page.waitForTimeout(1200);
      await page.screenshot({ path: path.join(process.env.SHOT, 'cscs-cards.png') });
    }
    ok(got.length === 3, 'three cards');
    ok(got[0].p.length === 0 && got[0].a.length === 0 && got[0].empty === 0,
       'card A lost its words and its button, and left no empty paragraph behind');
    ok(got[0].li.length === 2 && got[0].li[0] === '<b>Term</b><br>Words', 'card A gained bullets, bold and break intact');
    ok(!got[0].li[1].includes('script'), 'a script in a bullet is gone');
    ok(got[1].li.length === 0 && got[1].p.join() === 'Just words', 'card B lost its bullets and gained words');
    ok(JSON.stringify(got[1].a) === JSON.stringify([['Ask us', '/contact', null]]), 'card B\'s button points at our own page');
    ok(got[2].order.indexOf('P') < got[2].order.indexOf('UL'), `card C has its words above its bullets (${got[2].order})`);
    ok(got[2].a.length === 1 && got[2].a[0][2] === '_blank', 'and its outside button opens a new tab');
    await page.close();
  }

  // ---- 5. Bullets ----------------------------------------------------------
  console.log('\nabout: bullets');
  {
    const page = await open(browser, base, '/about', [row('about', 'glance', [
      { text: '<strong>One</strong> thing' }, { text: '<ul><li>nested</li></ul>' }, { text: 'Three' }])]);
    const li = await page.evaluate(() => [...document.querySelectorAll('.aside ul li')].map(l => l.innerHTML));
    ok(li.length === 3, `three bullets, got ${li.length}`);
    ok(li[0] === '<strong>One</strong> thing', 'bold survives in a bullet');
    ok(li[1] === 'nested', 'a list inside a bullet is unwrapped to its words');
    ok(!page.__errors.length, 'no page errors');
    await page.close();
  }

  // ---- 6. The home page's three cards keep their own link ------------------
  console.log('\nhome: the quick cards');
  {
    const page = await open(browser, base, '/', [row('home', 'quick_cards', [
      { icon: 'award', title: 'X', body: 'x', href: '/apply', link_label: 'Go X' },
      { icon: 'award', title: 'Y', body: 'y' },
      { icon: 'award', title: 'Z', body: 'z', href: '/about', link_label: 'Go Z' }])]);
    const got = await page.evaluate(() => [...document.querySelectorAll('.cards3 .qcard')].map(c => {
      const a = c.querySelector('a.more');
      return a ? a.textContent + '|' + a.getAttribute('href') : null;
    }));
    ok(got.join() === 'Go X|/apply,,Go Z|/about', `each card's link is its own, and one without has none (${got.join()})`);
    const p = await painted(page, '.cards3 .qcard', 2);
    ok(!p.none && p.opacity > 0.95, 'the third card is painted');
    await page.close();
  }
  /* The one place a copied item carries .reveal of its own is a home card, and
     the editor holds that list at three. The renderer does not, and should not
     have to, so a fourth is served here to exercise the path: the copy is made
     before the original has scrolled into view, so it carries no `in`, and only
     a second pass of the observer will ever paint it.

     HONESTY NOTE. Taking applyBlocks' own second pass out does NOT make this
     fail, because page-index.js calls revealSoon after it draws the news and
     that pass picks the copy up too. So on the home page the copy is covered
     twice. The pass in applyBlocks is for a page with no script of its own,
     and no such page has a .reveal on a list item today. Kept because that is
     a property of today's markup rather than a rule. */
  {
    const four = ['A', 'B', 'C', 'D'].map(t => ({ icon: 'award', title: t, body: t }));
    // A short window, so the cards are below the fold when the copy is made.
    const page = await open(browser, base, '/', [row('home', 'quick_cards', four)], 360);
    const p = await painted(page, '.cards3 .qcard', 3);
    ok(!p.none && p.opacity > 0.95,
       `a copied card that carries .reveal is painted, not left at opacity 0 (${p.opacity})`);
    await page.close();
  }

  // ---- 7. Photographs ------------------------------------------------------
  console.log('\nabout: photographs');
  const PX = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64');
  for (const [addr, want, what] of [
    ["x') ; background:url('https://evil.example/a.png", null, 'an address that would close the url() is refused'],
    ['https://evil.example/a.webp', null, 'an address on another host is refused'],
    ['../secret.webp', null, 'an address climbing out of the bucket is refused'],
    ['pages/2026/a.png', null, 'a PNG, which the bucket no longer takes, is refused'],
    ['/assets/photo-site.webp', '/assets/photo-site.webp?v=', 'one of the bundle\'s photographs carries the bundle\'s cache stamp'],
    ['pages/2026/new-pic.webp', 'public-media/pages/2026/new-pic.webp', 'an upload comes from the bucket'],
  ]) {
    const pg = await open(browser, base, '/about', [
      { page_key: 'about', block_key: 'banner_photo', body: addr, items: null },
      { page_key: 'about', block_key: 'practice_photo', body: addr, items: null }]);
    // The banner is painted; the practice photograph is below the fold and is
    // still waiting in data-bg. Both must change, or neither.
    await pg.evaluate(() => { const b = document.querySelector('.pbanner.img');
      b.style.backgroundImage = b.style.backgroundImage; });
    await pg.waitForTimeout(400);
    const got = await pg.evaluate(() => ({
      banner: document.querySelector('.pbanner.img').style.backgroundImage,
      pic: document.querySelector('.split .pic').dataset.bg || document.querySelector('.split .pic').style.backgroundImage,
    }));
    if (want === null) {
      ok(got.banner.includes('photo-team.webp') && got.pic.includes('photo-review.webp') && !/evil|secret|a\.png/.test(got.banner + got.pic),
         what + ': both pictures stay as the markup has them');
    } else {
      ok(got.banner.includes(want), `${what}: the banner (${got.banner.slice(-70)})`);
      ok(/gradient/.test(got.banner), 'and the wash over the banner is kept');
    }
    await pg.close();
  }
  // Scrolling a waiting picture into view after the swap paints the NEW one.
  {
    const pg = await open(browser, base, '/about', [
      { page_key: 'about', block_key: 'practice_photo', body: 'pages/2026/later.webp', items: null }]);
    await pg.waitForTimeout(300);
    const after = await pg.evaluate(async () => {
      document.documentElement.style.scrollBehavior = 'auto';
      const el = document.querySelector('.split .pic');
      el.scrollIntoView({ block: 'center' });
      await new Promise(r => setTimeout(r, 900));
      return { style: el.style.backgroundImage, waiting: el.dataset.bg || '' };
    });
    ok(after.style.includes('pages/2026/later.webp') && !after.waiting,
       'a photograph still waiting for the lazy painter is painted as the new one: ' + after.style.slice(-60));
    await pg.close();
  }

  // ---- 8. The CPD scheme page lists what the office has switched on (0040) ----
  console.log('\ncpd-scheme: activity lists from the database');
  {
    const acts = [
      { name: 'AMI Seminar', is_core: true, points: 3, points_min: null, points_max: null, sort_order: 30 },
      { name: 'Technical Review', is_core: true, points: null, points_min: 0.5, points_max: 2, sort_order: 40 },
      { name: '<img src=x onerror="window.__xss=1">Self Directed Learning', is_core: false, points: 1,
        points_min: null, points_max: null, sort_order: 180 },
    ];
    // A stale typed list in the block, which the live list must win over.
    const pg = await open(browser, base, '/cpd-scheme', [{ page_key: 'cpd-scheme', block_key: 'counts', body: null,
      items: [{ icon: 'award', title: 'Core activities', body: 'Core words', bullets: ['OLD CORE BULLET'] },
              { icon: 'people', title: 'Non core activities', body: 'Non core words', bullets: ['OLD NON CORE BULLET'] }] }],
      900, { public_cpd_activities: acts });
    const got = await pg.evaluate(() => {
      const cards = [...document.querySelectorAll('.support-grid')][0].querySelectorAll('.scard');
      return { core: [...cards[0].querySelectorAll('li')].map(l => l.textContent),
               non: [...cards[1].querySelectorAll('li')].map(l => l.textContent),
               title: cards[0].querySelector('h4').textContent, xss: window.__xss || 0,
               imgs: cards[1].querySelectorAll('img').length };
    });
    ok(got.core.join('|') === 'AMI Seminar · 3 points|Technical Review · 0.5 to 2 points',
       'the core card lists the core activities with their points: ' + got.core.join('|'));
    ok(got.non.length === 1 && /Self Directed Learning · 1 point$/.test(got.non[0]),
       'the non core card lists the non core ones: ' + got.non.join('|'));
    ok(!got.core.concat(got.non).some(t => /OLD/.test(t)), 'and the typed list in the block is not what shows');
    ok(got.title === 'Core activities', 'while the card heading is still the block\'s');
    ok(got.xss === 0 && got.imgs === 0, 'an activity name is words, never markup');
    await pg.close();
    const empty = await open(browser, base, '/cpd-scheme', [], 900, { public_cpd_activities: [] });
    const kept = await empty.evaluate(() =>
      [...document.querySelectorAll('.support-grid')][0].querySelectorAll('.scard')[0].querySelectorAll('li').length);
    ok(kept > 0, 'if the list cannot be read, the markup\'s list stays rather than an empty card');
    await empty.close();
  }

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
