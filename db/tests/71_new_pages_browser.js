/* The guidance documents page, professional conduct and committees (site 83),
   in a real browser under the site's real headers.

   Run:  node tests/71_new_pages_browser.js [path-to-site]
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




const GUIDES = [
  { slug:'open-guide', title:'Competency within removal', category:'Removal', summary:'What competence looks like.',
    published_at:'2026-11-01T00:00:00Z', members_only:false, has_document:true, file_type:'pdf', file_size: 482000 },
  { slug:'members-guide', title:'Members briefing', category:'Surveying', summary:'For members.',
    published_at:'2026-10-01T00:00:00Z', members_only:true, has_document:true, file_type:'docx', file_size: 2400000 },
  { slug:'xss-guide', title:'<img src=x onerror="window.__pwned=1">Tricky', category:'Removal', summary:'<script>window.__pwned=2</script>',
    published_at:'2026-09-01T00:00:00Z', members_only:false, has_document:false, file_type:null, file_size:null },
];

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();
  const open = async (p, rows) => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.__errors = [];
    page.on('pageerror', e => page.__errors.push(String(e)));
    await page.addInitScript(() => { window.__csp = [];
      document.addEventListener('securitypolicyviolation', e => window.__csp.push(e.violatedDirective + ' ' + e.blockedURI)); });
    await page.route('**/rest/v1/**', r => r.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify(r.request().url().includes('public_guidance') ? (rows || []) : []) }));
    await page.route('**/auth/v1/**', r => r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }));
    await page.goto(base + p, { waitUntil: 'load' });
    await page.waitForTimeout(900);
    return page;
  };
  const clean = async page => page.__errors.length === 0 && (await page.evaluate(() => window.__csp)).length === 0;
  const painted = page => page.evaluate(async () => { const el = document.querySelector('main section.reveal');
    el.scrollIntoView(); await new Promise(r => setTimeout(r, 900)); return Number(getComputedStyle(el).opacity); });

  // guidance
  let page = await open('/guidance', GUIDES);
  const g = await page.evaluate(() => ({
    titles: [...document.querySelectorAll('.doc h3')].map(h => h.textContent),
    open: document.querySelector('a[href="/api/guidance/open-guide"]') ? true : false,
    memberBtn: !!document.querySelector('[data-member-dl="members-guide"]'),
    memberRead: !!document.querySelector('a[href*="slug=members-guide"]'),
    lock: [...document.querySelectorAll('.doc')][1].textContent.includes('Members only'),
    meta: document.querySelector('.doc .doc-meta').textContent,
    pills: [...document.querySelectorAll('#cats [data-cat]')].map(b => b.textContent),
    pwned: window.__pwned, imgs: document.querySelectorAll('#docs img, #docs script').length }));
  ok(g.titles.length === 3, 'every published guidance document is listed');
  ok(g.open, 'an open document downloads from the site\'s own address');
  ok(g.memberBtn && g.lock && !g.memberRead, 'a members only one is marked, downloads with a sign in, and has no public article link');
  ok(/Removal/.test(g.meta) && /PDF, 482 KB|PDF, 471 KB/.test(g.meta), 'with its category, type and size: ' + g.meta);
  ok(g.pills.join('|') === 'All|Removal|Surveying', 'one pill per category');
  ok(!g.pwned && g.imgs === 0 && /<img src=x/.test(g.titles[2]), 'a title carrying markup stays words');
  await page.click('[data-cat="Surveying"]'); await page.waitForTimeout(200);
  ok((await page.$$eval('.doc h3', h => h.map(x => x.textContent))).join() === 'Members briefing', 'a category pill filters the list');
  await page.click('[data-cat=""]'); await page.fill('#q', 'competency'); await page.waitForTimeout(200);
  ok((await page.$$eval('.doc h3', h => h.length)) === 1, 'the search box filters the list');
  await page.fill('#q', '');
  await page.click('[data-member-dl="members-guide"]'); await page.waitForURL(/\/login\?next=%2Fguidance/, { timeout: 4000 }).catch(() => {});
  ok(/\/login\?next=%2Fguidance/.test(page.url()), 'signed out, a members only download goes to sign in and comes back');
  await page.close();

  page = await open('/guidance', []);
  ok(/No guidance documents have been published yet/.test(await page.textContent('#docs')), 'an empty list says so rather than going blank');
  ok(await clean(page), 'the guidance page raises no error and no policy violation');
  await page.close();

  // professional conduct and committees
  page = await open('/professional-conduct');
  const pc = await page.evaluate(() => ({ h1: document.querySelector('h1').textContent,
    items: document.querySelectorAll('#intro > ul > li').length, sub: document.querySelectorAll('#intro ul ul li').length,
    nav: (document.querySelector('.navbar a.active') || {}).textContent }));
  ok(pc.h1 === 'Professional conduct' && pc.items === 10 && pc.sub === 5, 'professional conduct carries the ten obligations and five sub points, as on the old site');
  ok(pc.nav === 'Membership', 'and sits under Membership in the menu');
  ok(await painted(page) > 0.95 && await clean(page), 'painted, with no error and no policy violation');
  await page.close();

  page = await open('/committees');
  const cm = await page.evaluate(() => ({ cards: [...document.querySelectorAll('.cards2 .qcard h3')].map(h => h.textContent),
    chair: document.querySelector('.cards2 .qcard li').textContent }));
  ok(cm.cards.join('|') === 'Membership Sub-Committee|Technical Sub-Committee' && /Chair/.test(cm.chair), 'committees lists both, with their chairs');
  ok(await painted(page) > 0.95 && await clean(page), 'painted, with no error and no policy violation');
  await page.close();

  // the rules of membership (site 87)
  page = await open('/rules');
  const ru = await page.evaluate(() => ({ h1: document.querySelector('h1').textContent,
    sections: [...document.querySelectorAll('#rules h3')].map(h => h.textContent),
    grades: [...document.querySelectorAll('#rules p strong')].map(s => s.textContent).filter(t => !/^\d/.test(t)),
    pdf: (document.querySelector('.aside a.btn') || {}).getAttribute && document.querySelector('.aside a.btn').getAttribute('href'),
    nav: (document.querySelector('.navbar a.active') || {}).textContent }));
  ok(ru.h1 === 'Rules of membership' && ru.sections.length === 10 && /^1\. Articles/.test(ru.sections[0]) && /^10\. Conflicts/.test(ru.sections[9]),
     'the rules carry all ten sections, in order');
  ok(['Honorary Fellow', 'Fellow', 'Full Member', 'Competent Person Qualification', 'Associate', 'Technician Grade Member',
      'Entrant Member', 'Affiliate Member'].every(g => ru.grades.includes(g)), 'every grade of membership is set out');
  ok(ru.pdf === '/assets/AMI-Rules-of-Membership-V6-0325.pdf', 'and the PDF of the rules is offered');
  ok(ru.nav === 'Membership', 'it sits under Membership in the menu');
  ok(await painted(page) > 0.95 && await clean(page), 'painted, with no error and no policy violation');
  await page.close();

  // footer and membership
  page = await open('/membership');
  const f = await page.evaluate(() => ({ line: document.body.textContent.includes('checked against the AMI record'),
    links: ['/guidance', '/rules', '/professional-conduct', '/committees'].every(h => document.querySelector('footer a[href="' + h + '"]')),
    cards: [...document.querySelectorAll('#standards a.qcard')].map(a => a.getAttribute('href')) }));
  ok(!f.line, 'the footer no longer says every entry is checked against the AMI record');
  ok(f.links, 'the footer links to guidance documents, the rules, professional conduct and committees');
  ok(f.cards.join() === '/rules,/professional-conduct,/committees', 'the membership page links to the rules, conduct and committees');
  await page.close();

  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
