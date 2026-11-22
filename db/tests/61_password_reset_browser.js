/* Setting a new password from the reset email (site 77, rules from site 80), in a real browser,
   under the site's real headers.

   Found by Steve, 1 November 2026: the reset link came back to /login and
   simply signed the member in, so nothing ever asked for the new password.

   Run:  node tests/61_password_reset_browser.js [path-to-site]
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


const STUB = (session) => `
window.__calls = [];
const res = (data, error) => Promise.resolve({ data, error: error || null });
window.__client = {
  from: () => new Proxy({}, { get(_, p){ return p === 'then' ? r => res([]).then(r) : () => window.__client.from(); } }),
  rpc: (fn) => { window.__calls.push({ rpc: fn });
    return fn === 'whoami' ? res([{ person_id: 'p1', member_id: 'm1', roles: ['member'] }]) : res(null); },
  auth: {
    getSession: () => res({ session: ${session} ? { access_token: 't', user: { id: 'u1', email: 'jane@test.invalid' } } : null }),
    getUser: () => res({ user: null }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signInWithPassword: () => res(null, { message: 'Invalid login credentials' }),
    resetPasswordForEmail: (email, o) => { window.__calls.push({ reset: email, to: o && o.redirectTo }); return res({}); },
    updateUser: (u) => { window.__calls.push({ update: u });
      return u.password === 'The Same Old Passw0rd' ? res(null, { message: 'New password should be different from the old password.', code: 'same_password' })
           : u.password === 'Leaked Passw0rd1' ? res(null, { message: 'Password is known to be weak and easy to guess, please choose a different one.', code: 'weak_password' })
           : res({ user: {} }); },
    signOut: () => res(null),
  },
  storage: { from: () => ({}) },
  channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel: () => {},
};
window.__csp = [];
document.addEventListener('securitypolicyviolation', e => window.__csp.push(e.violatedDirective + ' ' + e.blockedURI));
Object.defineProperty(window, 'supabase', { configurable: true, value: { createClient: () => window.__client } });
`;

(async () => {
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  const browser = await chromium.launch();
  const open = async (url, session) => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.__errors = [];
    page.on('pageerror', e => page.__errors.push(String(e)));
    await page.addInitScript(STUB(session));
    await page.goto(base + url, { waitUntil: 'load' });
    await page.waitForTimeout(700);
    return page;
  };
  const msg = page => page.evaluate(() => (document.getElementById('msg') || {}).textContent || '');

  // the link from the email, with a session
  let page = await open('/login?reset=1', true);
  ok(await page.$('#np1') && await page.$('#np2') && !(await page.$('#pw')),
     'the reset link opens Set a new password, not the members area');
  await page.fill('#np1', 'Short1'); await page.fill('#np2', 'Short1');
  await page.click('#npgo'); await page.waitForTimeout(200);
  ok(/at least 12/.test(await msg(page)), 'a password under 12 characters is refused, as Supabase is set');
  await page.fill('#np1', 'a long new password1'); await page.fill('#np2', 'a long new password1');
  await page.click('#npgo'); await page.waitForTimeout(200);
  ok(/capital letter/.test(await msg(page)), 'one with no capital letter is refused, in words');
  await page.fill('#np1', 'A LONG NEW PASSWORD1'); await page.fill('#np2', 'A LONG NEW PASSWORD1');
  await page.click('#npgo'); await page.waitForTimeout(200);
  ok(/small letter/.test(await msg(page)), 'and one with no small letter');
  await page.fill('#np1', 'A long new password'); await page.fill('#np2', 'A long new password');
  await page.click('#npgo'); await page.waitForTimeout(200);
  ok(/a number/.test(await msg(page)), 'and one with no number');
  await page.fill('#np1', 'A long new passw0rd'); await page.fill('#np2', 'A long new passwr0d');
  await page.click('#npgo'); await page.waitForTimeout(200);
  ok(/do not match/.test(await msg(page)), 'two that differ are refused');
  await page.fill('#np1', 'The Same Old Passw0rd'); await page.fill('#np2', 'The Same Old Passw0rd');
  await page.click('#npgo'); await page.waitForTimeout(300);
  ok(/already have/.test(await msg(page)), 'the password already held is explained in words');
  await page.fill('#np1', 'Leaked Passw0rd1'); await page.fill('#np2', 'Leaked Passw0rd1');
  await page.click('#npgo'); await page.waitForTimeout(300);
  ok(/data breach/.test(await msg(page)), 'a leaked password is explained in words, not as the same password');
  await page.fill('#np1', 'A long new passw0rd'); await page.fill('#np2', 'A long new passw0rd');
  await page.click('#npgo'); await page.waitForTimeout(250);
  const calls = await page.evaluate(() => window.__calls);
  ok(calls.some(c => c.update && c.update.password === 'A long new passw0rd'), 'the new password is saved to the account');
  await page.waitForTimeout(1400);
  ok(new URL(page.url()).pathname === '/me', 'and the member goes on to the members area: ' + page.url());
  ok(page.__errors.length === 0 && (await page.evaluate(() => window.__csp)).length === 0, 'no page error or policy violation');
  await page.close();

  // the link opened after it has expired
  page = await open('/login?reset=1', false);
  ok(/expired/.test(await msg(page)) && await page.$('#pw'), 'an expired link says so and offers the sign in form');
  await page.close();

  // asking for a reset sends the member back to the new step
  page = await open('/login', false);
  await page.fill('#email', 'jane@test.invalid');
  await page.click('#forgot'); await page.waitForTimeout(300);
  const r = (await page.evaluate(() => window.__calls)).find(c => c.reset);
  ok(r && /\/login\?reset=1$/.test(r.to), 'Forgotten your password sends a link that comes back to the new step: ' + (r && r.to));
  await page.close();

  // an ordinary visit with a session still goes straight in
  page = await open('/login', true);
  await page.waitForTimeout(500);
  ok(new URL(page.url()).pathname === '/me' , 'an ordinary signed in visit still goes straight to the members area');
  await page.close();

  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
