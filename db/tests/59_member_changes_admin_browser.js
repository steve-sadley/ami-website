/* Email changes and Member changes (0062, admin 46), in a browser, under
   the admin app's real Content-Security-Policy. Only window.supabase is replaced.

   Run:  node tests/59_member_changes_admin_browser.js [path-to-admin]
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = process.argv[2] || path.resolve(__dirname, '../../admin');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

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

const STUB = `
const res = (data, error) => Promise.resolve({ data, error: error || null });
window.__w = [];
const ROWS = {
  admin_email_change_requests: [
    { id:'q1', status:'pending', requested_at:'2026-11-01T09:00:00Z', decided_at:null, note:null,
      work_email:'jo.new@test.invalid', private_email:'jo.home@test.invalid', current_work:'jo@test.invalid',
      current_private:'jo.home@test.invalid', person_id:'p2', given_name:'Jo', family_name:'Linked',
      membership_number:'020626', in_dynamics:true, address_on_another_record:false },
    { id:'q2', status:'pending', requested_at:'2026-11-01T08:00:00Z', decided_at:null, note:null,
      work_email:'al.new@test.invalid', private_email:'taken@test.invalid', current_work:'al@test.invalid',
      current_private:null, person_id:'p3', given_name:'Al', family_name:'Unlinked',
      membership_number:'010525', in_dynamics:false, address_on_another_record:true },
    { id:'q3', status:'declined', requested_at:'2026-10-30T08:00:00Z', decided_at:'2026-10-30T10:00:00Z',
      note:'Ring the office <img src=x onerror="window.__xss=1">', work_email:'x@test.invalid', private_email:null,
      current_work:'al@test.invalid', current_private:null, person_id:'p3', given_name:'Al', family_name:'Unlinked',
      membership_number:'010525', in_dynamics:false, address_on_another_record:false } ],
  admin_member_changes: [
    { id: 3, occurred_at:'2026-11-01T10:00:00Z', action:'UPDATE', area:'Details', person_id:'p2', given_name:'Jo',
      family_name:'Linked', membership_number:'020626',
      changes:{ mobile:{ before:'07700 900000', after:'07700 900123' },
                home_address:{ before:null, after:{ lines:['1 High St', 'Burton <b>x</b>'] } } } },
    { id: 2, occurred_at:'2026-11-01T09:30:00Z', action:'UPDATE', area:'Switches', person_id:'p2', given_name:'Jo',
      family_name:'Linked', membership_number:'020626', changes:{ list_on_register:{ before:true, after:false } } },
    { id: 1, occurred_at:'2026-11-01T09:00:00Z', action:'INSERT', area:'Email request', person_id:'p2', given_name:'Jo',
      family_name:'Linked', membership_number:'020626',
      changes:{ status:{ before:null, after:'pending' }, work_email:{ before:null, after:'jo.new@test.invalid' } } } ],
};
function table(name){
  let rows = (ROWS[name] || []).slice();
  const q = new Proxy({}, { get(_, p){
    if (p === 'then') return r => res(rows).then(r);
    if (p === 'eq') return (c, v) => { rows = rows.filter(x => String(x[c]) === String(v)); return q; };
    if (p === 'single' || p === 'maybeSingle') return () => res(rows[0] || null);
    if (p === 'insert') return v => { window.__w.push([name, 'insert', v]); return res(v); };
    if (p === 'update') return v => { window.__w.push([name, 'update', v]); return q; };
    if (p === 'delete') return () => { window.__w.push([name, 'delete']); return q; };
    return () => q;
  } });
  return q;
}
window.__stubClient = {
  from: table,
  rpc: (fn, args) => {
    if (fn === 'whoami') return res([{ person_id:'p1', given_name:'Olive', family_name:'Office', roles:['membership'] }]);
    if (fn === 'email_change_decide') { window.__w.push(['rpc', fn, args]); return res(args.p_action === 'apply' ? 'done' : 'declined'); }
    return res([]);
  },
  auth: {
    getSession: () => res({ session: { access_token:'T', user: { id:'u1', email:'office@test.invalid' } } }),
    getUser: () => res({ user: { id:'u1', email:'office@test.invalid' } }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null),
  },
  storage: { from: () => ({ upload: (p) => res({ path: p }), remove: (ps) => { window.__w.push(['storage','remove',ps]); return res(null); },
                            createSignedUrl: () => res({ signedUrl: 'data:,' }) }) },
  channel: () => ({ on(){ return this; }, subscribe(){ return this; } }),
  removeChannel: () => {},
};
window.__csp = [];
document.addEventListener('securitypolicyviolation', e => window.__csp.push(e.violatedDirective + ' ' + (e.blockedURI || '')));
Object.defineProperty(window, 'supabase', { configurable: true, value: { createClient: () => window.__stubClient } });
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
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('dialog', d => d.accept());
  await page.addInitScript(STUB);
  await page.route('https://fonts.googleapis.com/**', r => r.fulfill({ contentType: 'text/css', body: '' }));
  await page.route('**/*.webp', r => r.fulfill({ contentType: 'image/png', body: Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64') }));
  await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
  await page.waitForTimeout(900);
  const nav = n => page.evaluate(n => [...document.querySelectorAll('#nav button')].find(b => b.textContent === n).click(), n);
  const msg = () => page.evaluate(() => document.getElementById('msg').textContent.trim());
  const w = () => page.evaluate(() => window.__w);


  const cards = () => page.evaluate(() => [...document.querySelectorAll('.q')].map(c => c.textContent.replace(/\s+/g, ' ')));

  // ---- Email changes ----------------------------------------------------------
  await nav('Email changes');
  await page.waitForTimeout(400);
  let c = await cards();
  ok(c.length === 2, 'Waiting shows the two waiting requests: ' + c.length);
  ok(/Jo Linked/.test(c[0]) && /jo@test.invalid → jo.new@test.invalid/.test(c[0]) && /Change this in Dynamics/.test(c[0])
     && /Email Address 2 the private one/.test(c[0]), 'a linked member\'s request says what to change in Dynamics: ' + c[0].slice(0, 220));
  ok(/unchanged/.test(c[0]), 'and marks the address that is not changing');
  const acts0 = await page.evaluate(() => [...document.querySelectorAll('.q')][0].querySelectorAll('[data-act$="|Apply"]').length);
  const acts1 = await page.evaluate(() => [...document.querySelectorAll('.q')][1].querySelectorAll('[data-act$="|Apply"]').length);
  ok(acts0 === 0 && acts1 === 1, 'Apply is offered only for somebody not linked to Dynamics');
  ok(/somebody else's record/.test(c[1]), 'and a clash with another record is flagged');

  await page.evaluate(() => [...document.querySelectorAll('.q')][1].querySelector('[data-act$="|Apply"]').click());
  await page.waitForTimeout(400);
  ok((await w()).some(x => x[1] === 'email_change_decide' && x[2].p_id === 'q2' && x[2].p_action === 'apply'),
     'Apply asks the database to apply it');

  await page.click('[data-act$="|Decline"]');
  await page.waitForTimeout(300);
  await page.click('#mOk');
  await page.waitForTimeout(200);
  ok(/Say why/.test(await page.evaluate(() => document.getElementById('mMsg').textContent)), 'declining with no reason is stopped');
  await page.fill('#m_note', 'Please confirm by phone first.');
  await page.click('#mOk');
  await page.waitForTimeout(400);
  ok((await w()).some(x => x[1] === 'email_change_decide' && x[2].p_id === 'q1' && x[2].p_action === 'decline'
       && x[2].p_note === 'Please confirm by phone first.'), 'with a reason it is declined');

  await page.evaluate(() => document.querySelector('[data-tab="declined"]').click());
  await page.waitForTimeout(300);
  c = await cards();
  ok(c.length === 1 && /Ring the office/.test(c[0]) && !(await page.evaluate(() => window.__xss)),
     'a declined request shows its reason, as words');

  // ---- Member changes ----------------------------------------------------------
  await nav('Member changes');
  await page.waitForTimeout(400);
  c = await cards();
  ok(c.length === 3, 'every change members made is listed: ' + c.length);
  ok(/Details/.test(c[0]) && /Mobile: 07700 900000 → 07700 900123/.test(c[0]) && /Home address: empty → 1 High St, Burton <b>x<\/b>/.test(c[0]),
     'each field with what it was and what it became: ' + c[0].slice(0, 200));
  ok(/List on register: true → false/.test(c[1]), 'switches are listed the same way');
  ok(!(await page.$('.q b b')), 'and what a member typed arrives as words');
  await page.fill('#qSearch', 'register');
  await page.waitForTimeout(300);
  ok((await cards()).length === 1, 'searching by field finds the change');

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'no policy violation anywhere: ' + (v[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));
  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
