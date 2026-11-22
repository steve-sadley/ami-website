/* The admin app under its own Content-Security-Policy.

   From admin 18 the app carries a policy that allows its two inline scripts by
   the SHA-256 of their exact text and nothing else inline. That is a strong
   lock and a sharp one: if the hashes are stale the browser refuses the whole
   app and the office sees a blank page. So this file does three things.

   1. Recomputes the hashes and fails if _headers does not match index.html,
      which is the forgotten "run tools/admin-csp.py" caught here rather than
      by somebody at nine in the morning.
   2. Serves the app with EVERY header in admin/_headers, exactly as Cloudflare
      would, and walks every screen in the sidebar, opens the record editor and
      the Pages screen, and asserts the browser reported no policy violation.
   3. Proves the policy bites: markup carrying an onerror handler and a script
      element is put into the live page, and neither runs.

   Only window.supabase is replaced.

   Run:  node tests/19_admin_csp_browser.js [path-to-admin]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const ROOT = process.argv[2] || path.resolve(__dirname, '../../admin');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

// ---- 1. The line is up to date ---------------------------------------------
let fresh = false;
try {
  execFileSync('python3', ['-I', path.join(__dirname, '../tools/admin-csp.py'), ROOT, '--check']);
  fresh = true;
} catch {}
ok(fresh, 'the policy in _headers matches the scripts in index.html (run tools/admin-csp.py ADMIN_DIR)');

// The headers for /*, read the way Pages reads them: indented "Name: value"
// lines under the path, comments ignored.
const HEADERS = (() => {
  const out = {};
  let inBlock = false;
  for (const line of fs.readFileSync(path.join(ROOT, '_headers'), 'utf8').split('\n')) {
    if (/^\/\*\s*$/.test(line)) { inBlock = true; continue; }
    if (!inBlock || /^\s*#/.test(line) || !line.trim()) continue;
    if (!/^\s/.test(line)) { inBlock = false; continue; }
    const m = line.match(/^\s+([A-Za-z-]+):\s*(.*)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
})();
ok(!!HEADERS['Content-Security-Policy'], 'there is a policy to apply');
ok(!/unsafe-inline/.test((HEADERS['Content-Security-Policy'] || '').match(/script-src[^;]*/)?.[0] || 'x'),
   'and it does not allow inline script wholesale');

const STUB = `
const res = (data, error) => Promise.resolve({ data, error: error || null });
function table(){
  const q = new Proxy({}, { get(_, p){
    if (p === 'then') return r => res([]).then(r);
    if (p === 'single' || p === 'maybeSingle') return () => res(null);
    return () => q;
  } });
  return q;
}
window.__stubClient = {
  from: table,
  rpc: fn => fn === 'whoami'
    ? res([{ person_id:'p1', given_name:'Test', family_name:'Editor',
             roles:['super_user','administrator','editor','membership'] }])
    : res([]),
  auth: {
    getSession: () => res({ session: { user: { id:'u1', email:'editor@test.invalid' } } }),
    getUser: () => res({ user: { id:'u1', email:'editor@test.invalid' } }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null),
  },
  storage: { from: () => ({ upload: () => res({}), createSignedUrl: () => res({ signedUrl: 'data:,' }) }) },
  channel: () => ({ on(){ return this; }, subscribe(){ return this; } }),
  removeChannel: () => {},
};
window.__csp = [];
document.addEventListener('securitypolicyviolation', e =>
  window.__csp.push(e.violatedDirective + ' ' + (e.blockedURI || '') + ' ' + (e.sample || '')));
Object.defineProperty(window, 'supabase', { configurable: true,
  value: { createClient: () => window.__stubClient } });
`;

(async () => {
  const srv = await new Promise(r => {
    const s = http.createServer((req, res) => {
      const p = req.url.split('?')[0] === '/' ? '/index.html' : req.url.split('?')[0];
      const f = path.join(ROOT, p);
      if (!f.startsWith(ROOT) || !fs.existsSync(f) || p === '/_headers') { res.writeHead(404); res.end(); return; }
      res.writeHead(200, Object.assign({ 'Content-Type': 'text/html' }, HEADERS));
      res.end(fs.readFileSync(f));
    });
    s.listen(0, () => r(s));
  });
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const errors = [], cspConsole = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('console', m => { if (/Content Security Policy/i.test(m.text())) cspConsole.push(m.text().slice(0, 200)); });
  // addInitScript runs before the page's own scripts and is not subject to the
  // page's policy, which is what lets the stand in exist at all.
  await page.addInitScript(STUB);
  // Google Fonts cannot be reached from the test machine; answer it empty so
  // the run is not waiting on a network that is not there.
  await page.route('https://fonts.googleapis.com/**', r => r.fulfill({ contentType: 'text/css', body: '' }));

  await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
  await page.waitForTimeout(900);

  // ---- 2. The app runs under it -------------------------------------------
  const shown = await page.evaluate(() => ({
    app: document.getElementById('app') && document.getElementById('app').style.display,
    ver: (document.getElementById('verTag') || {}).textContent,
    nav: [...document.querySelectorAll('#nav button')].map(b => b.textContent),
  }));
  ok(shown.app === 'block', 'the app starts under the policy rather than a blank page');
  ok(shown.ver === 'v48', 'and it is v48, got ' + shown.ver);
  ok(shown.nav.length >= 15, `the sidebar is drawn, ${shown.nav.length} screens`);

  for (const name of shown.nav) {
    await page.evaluate(n => [...document.querySelectorAll('#nav button')].find(b => b.textContent === n).click(), name);
    await page.waitForTimeout(220);
  }
  // The record editor, with its rich text editor and a pasted picture.
  await page.evaluate(() => [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'News').click());
  await page.waitForTimeout(250);
  await page.evaluate(() => document.getElementById('addRow').click());
  await page.waitForTimeout(300);
  const drawer = await page.evaluate(() => !!document.querySelector('#drawer.on .rt'));
  ok(drawer, 'the record editor opens with its rich text editor');
  // The Pages screen, with lists, icons and photographs.
  await page.evaluate(() => [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'Pages').click());
  await page.waitForTimeout(250);
  await page.evaluate(() => document.querySelector('.prow [data-page]').click());
  await page.waitForTimeout(400);
  const pages = await page.evaluate(() => document.querySelectorAll('.pgedit .seg').length);
  ok(pages > 10, 'the Pages screen opens a page with its fields: ' + pages);

  const violations = await page.evaluate(() => window.__csp);
  ok(violations.length === 0 && cspConsole.length === 0,
     'every screen ran with no policy violation: ' + (violations[0] || cspConsole[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));

  // ---- 3. It bites --------------------------------------------------------
  const bite = await page.evaluate(async () => {
    window.__ran = 0;
    const box = document.createElement('div');
    document.body.appendChild(box);
    box.innerHTML = '<img src="x-not-there" onerror="window.__ran = 1">';
    const s = document.createElement('script');
    s.textContent = 'window.__ran = 2';
    document.body.appendChild(s);
    await new Promise(r => setTimeout(r, 400));
    return window.__ran;
  });
  ok(bite === 0, 'an injected onerror and an injected script both stay dead under the policy, got ' + bite);

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
