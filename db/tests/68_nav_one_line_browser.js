/* The menu bar stays on one line at every width (site 82).

   Found by Steve, 3 November 2026: between 1,080 and about 1,340 pixels the
   seven items and the two buttons broke onto two lines, which doubled the
   height of the bar and read as broken. Nothing in the bar may wrap; below
   the width where it all fits, the burger takes over.

   Run:  node tests/68_nav_one_line_browser.js [path-to-site]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = process.argv[2] || path.resolve(__dirname, '../../site');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };
const TYPES = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.woff2':'font/woff2' };

(async () => {
  const srv = await new Promise(r => {
    const s = http.createServer((req, res) => {
      let p = req.url.split('?')[0];
      if (p === '/') p = '/index.html'; else if (!path.extname(p)) p += '.html';
      const f = path.join(ROOT, p);
      if (!f.startsWith(ROOT) || !fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream' });
      res.end(fs.readFileSync(f));
    });
    s.listen(0, () => r(s));
  });
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.route('**/rest/v1/**', r => r.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));

  for (const pageUrl of ['/index.html', '/membership.html']) {
    for (let w = 1000; w <= 1700; w += 20) {
      await page.setViewportSize({ width: w, height: 500 });
      await page.goto(base + pageUrl);
      await page.waitForTimeout(150);
      const m = await page.evaluate(() => {
        const burger = getComputedStyle(document.querySelector('.burger')).display !== 'none';
        const nav = document.querySelector('.navbar').getBoundingClientRect();
        const links = [...document.querySelectorAll('.navbar ul a')];
        const btns = [...document.querySelectorAll('.navbar .right .btn')];
        const oneLine = el => el.getBoundingClientRect().height < 30 || getComputedStyle(el).display === 'none';
        const right = document.querySelector('.navbar .right').getBoundingClientRect();
        const last = links[links.length - 1].getBoundingClientRect();
        return { burger,
          linksOneLine: burger || links.every(oneLine),
          btnsOneLine: btns.every(b => b.getBoundingClientRect().height < 56),
          inside: nav.right <= innerWidth + 0.5 && (burger || last.right <= right.left),
          noSideScroll: document.documentElement.scrollWidth <= innerWidth };
      });
      ok(m.linksOneLine && m.btnsOneLine && m.inside && m.noSideScroll,
         `${pageUrl} at ${w}px: every menu item and button on one line, inside the bar, no sideways scroll ` + JSON.stringify(m));
    }
  }
  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
