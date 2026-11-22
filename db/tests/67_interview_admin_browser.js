/* The interview screens in the admin app (0064, admin 47), in a browser, under
   the admin app's real Content-Security-Policy.

   Only window.supabase and the site's two doors are replaced.

   Run:  node tests/67_interview_admin_browser.js [path-to-admin]
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
const FUTURE = new Date(Date.now() + 5 * 864e5).toISOString();
const ROWS = {
  admin_application_queue: [
    { id:'a1', reference:'AMI-2026-0101', status:'submitted', given_name:'Nia', family_name:'New', email:'nia@test.invalid',
      submitted_at:'2026-11-01T10:00:00Z', documents:0 },
    { id:'a2', reference:'AMI-2026-0102', status:'under_review', given_name:'Ian', family_name:'Invited', email:'ian@test.invalid',
      submitted_at:'2026-11-01T10:00:00Z', documents:0, interview_invited_at:'2026-11-02T09:00:00Z' },
    { id:'a3', reference:'AMI-2026-0103', status:'under_review', given_name:'Bea', family_name:'Booked', email:'bea@test.invalid',
      submitted_at:'2026-11-01T10:00:00Z', documents:0, interview_invited_at:'2026-11-02T09:00:00Z',
      interview_booking_id:'bk-1', interview_at: FUTURE, interview_minutes:75,
      interview_join_url:'https://teams.microsoft.com/l/meetup-join/bea' } ],
  admin_interview_slots: [
    { id:'s1', starts_at: FUTURE, ends_at: FUTURE, minutes:75, state:'booked', booking_id:'bk-1',
      booked_at:'2026-11-02T12:00:00Z', join_url:'https://teams.microsoft.com/l/meetup-join/bea',
      application_id:'a3', reference:'AMI-2026-0103', applicant:'Bea Booked', email:'bea@test.invalid' },
    { id:'s2', starts_at: new Date(Date.now() + 6 * 864e5).toISOString(), minutes:75, state:'open' } ],
  interview_slots: [ { id:'s2', starts_at: new Date(Date.now() + 6 * 864e5).toISOString(), minutes:75, withdrawn:false, note:'Morning' } ],
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
    if (fn === 'interview_invite') { window.__w.push(['rpc', fn, args]);
      return res({ to:'nia@test.invalid', link:'https://staging.ami.uk.com/interview#t=TOKEN123', expires_at:'2027-01-01T00:00:00Z' }); }
    return res([]);
  },
  auth: {
    getSession: () => res({ session: { access_token:'T', user: { id:'u1', email:'office@test.invalid' } } }),
    getUser: () => res({ user: { id:'u1', email:'office@test.invalid' } }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null),
  },
  storage: { from: () => ({ createSignedUrl: () => res({ signedUrl: 'data:,' }) }) },
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
  const posts = [];
  await page.route('https://staging.ami.uk.com/api/**', async r => {
    const u = r.request().url();
    posts.push({ u, h: r.request().headers(), b: r.request().postData() });
    if (u.endsWith('/api/mail/drain')) return r.fulfill({ status: 200, contentType: 'application/json', body: '{"sent":1,"failed":0}' });
    const b = JSON.parse(r.request().postData() || '{}');
    if (b.booking === 'bk-fail') return r.fulfill({ status: 404, contentType: 'application/json',
      body: JSON.stringify({ error: 'There is no booked interview to cancel.' }) });
    return r.fulfill({ status: 200, contentType: 'application/json', body: '{"cancelled":true}' });
  });
  await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
  await page.waitForTimeout(900);
  const nav = n => page.evaluate(n => [...document.querySelectorAll('#nav button')].find(b => b.textContent === n).click(), n);
  const msg = () => page.evaluate(() => document.getElementById('msg').textContent.trim());
  const w = () => page.evaluate(() => window.__w);
  const cards = () => page.evaluate(() => [...document.querySelectorAll('.q')].map(c => c.textContent.replace(/\s+/g, ' ')));

  // Applications
  await nav('Applications');
  await page.waitForTimeout(400);
  let c = await cards();
  ok(/Invite to interview/.test(c[0]) && !/Send interview link again/.test(c[0]), 'an application not yet invited is offered Invite to interview');
  ok(/not booked yet/.test(c[1]) && /Send interview link again/.test(c[1]), 'one invited and not booked says so, and offers the link again');
  ok(/Interview /.test(c[2]) && !/Invite to interview|link again/.test(c[2]), 'a booked one shows the interview and offers no invitation');
  ok(await page.$('a[href="https://teams.microsoft.com/l/meetup-join/bea"]'), 'with the Teams link');

  await page.click('[data-act$="|Invite to interview"]');
  await page.waitForTimeout(500);
  const call = (await w()).find(x => x[1] === 'interview_invite');
  ok(call && call[2].p_application_id === 'a1', 'Invite calls interview_invite for that application');
  ok(posts.some(p => p.u.endsWith('/api/mail/drain') && p.h.authorization === 'Bearer T'), 'and sends the email straight away, as the staff member');
  const d = await page.evaluate(() => ({ t: document.getElementById('mTitle').textContent, s: document.getElementById('mSub').textContent,
    link: (document.getElementById('m_link') || {}).value }));
  ok(/Nia New/.test(d.t) && /email has gone to nia@test.invalid/.test(d.s) && /earlier link/.test(d.s),
     'the dialog says where it went and that any earlier link has stopped: ' + d.s);
  ok(d.link === 'https://staging.ami.uk.com/interview#t=TOKEN123', 'and shows the link to copy');
  await page.click('#mOk'); await page.waitForTimeout(200);

  // Interviews
  await nav('Interviews');
  await page.waitForTimeout(400);
  c = await cards();
  ok(c.length === 1 && /Bea Booked/.test(c[0]) && /AMI-2026-0103/.test(c[0]) && /Cancel interview/.test(c[0]),
     'the Booked tab shows who, the reference, and Cancel interview');
  await page.click('[data-act$="|Cancel interview"]');
  await page.waitForTimeout(200);
  await page.click('#mOk'); await page.waitForTimeout(200);
  ok(/reason is needed/.test(await page.evaluate(() => document.getElementById('mMsg').textContent))
     && !posts.some(p => p.u.endsWith('/office-cancel')), 'no reason, no cancellation');
  await page.fill('#m_reason', 'Interviewer unwell');
  await page.click('#mOk'); await page.waitForTimeout(500);
  const oc = posts.find(p => p.u.endsWith('/api/interview/office-cancel'));
  ok(oc && oc.h.authorization === 'Bearer T' && JSON.parse(oc.b).booking === 'bk-1' && JSON.parse(oc.b).reason === 'Interviewer unwell',
     'cancelling goes to the site with the staff sign in, the booking and the reason');
  ok(/Outlook event cancelled/.test(await msg()), 'and says the applicant was emailed and Outlook updated: ' + await msg());

  await page.evaluate(() => [...document.querySelectorAll('.filters .pill')].find(b => /Open/.test(b.textContent)).click());
  await page.waitForTimeout(200);
  c = await cards();
  ok(c.length === 1 && /open/.test(c[0]) && !/Cancel interview/.test(c[0]), 'an open slot offers nothing to cancel');

  // Interview slots
  await nav('Interview slots');
  await page.waitForTimeout(400);
  ok(/75 minutes/.test(await page.evaluate(() => document.getElementById('grid').textContent)) ,
     'Interview slots lists the times with their length');

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'no policy violation anywhere: ' + (v[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));
  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
