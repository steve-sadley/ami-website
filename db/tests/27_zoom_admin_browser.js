/* The admin app's Zoom screens (0042), in a browser, under the app's real
   Content-Security-Policy.

   What this proves: the Zoom sessions screen lists a session with what the last
   import found; Fetch attendance goes to the SITE carrying the staff member's
   own sign in and nothing else, and reports what came back, including Zoom's
   refusals in words; People to match links by membership number through
   feed_link and dismisses through feed_dismiss; and the policy lets the app
   reach the site at all.

   That last one is not a formality. From admin 18 to admin 21 the policy's
   connect-src named Supabase and not the site, so every request to the Worker
   (Send queued mail, a bulletin's sending) was refused by the browser before it
   left, and the app said only that the site could not be reached. A route
   intercepted here is only reached if the policy allowed the request, so a
   request that arrives is a request the policy permits.

   Only window.supabase is replaced, and the site's two endpoints are answered.

   Run:  node tests/27_zoom_admin_browser.js [path-to-admin]
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
window.__rpc = [];
const ROWS = {
  zoom_sessions: [{ id:'5e550000-0000-0000-0000-000000000001', title:'Spring seminar', kind:'meeting',
    zoom_id:'81234567890', held_on:'2027-03-11', activity_type_id:'t1', points:3, status:'imported',
    imported_at:'2027-03-11T12:00:00Z', counted_minutes:90, min_percent:75,
    last_result:{ awarded:41, too_short:3, unmatched:2, no_email:1 } }],
  admin_cpd_feed_queue: [
    { id:'a1', source:'Zoom', session_id:'5e550000-0000-0000-0000-000000000001', session:'Spring seminar',
      held_on:'2027-03-11', min_percent:75, counted_minutes:90, email:'j.smith@contractor.invalid',
      name:'Jo Smith', minutes:88, percent:97, outcome:'unmatched', updated_at:'2027-03-11T12:00:00Z' },
    { id:'a2', source:'Zoom', session_id:'5e550000-0000-0000-0000-000000000001', session:'Spring seminar',
      held_on:'2027-03-11', min_percent:75, counted_minutes:90, email:null,
      name:'iPhone', minutes:80, percent:88, outcome:'no_email', updated_at:'2027-03-11T12:00:00Z' },
    { id:'a3', source:'Zoom', session_id:'5e550000-0000-0000-0000-000000000001', session:'Spring seminar',
      held_on:'2027-03-11', min_percent:75, counted_minutes:90, email:'<img src=x onerror=alert(1)>@x.invalid',
      name:'<script>window.__xss=1</script>', minutes:90, percent:100, outcome:'unmatched', updated_at:'2027-03-11T12:00:00Z' },
  ],
  cpd_activity_types: [{ id:'t1', name:'AMI Seminar' }],
};
function table(name){
  let rows = (ROWS[name] || []).slice();
  const q = new Proxy({}, { get(_, p){
    if (p === 'then') return r => res(rows).then(r);
    if (p === 'eq') return (c, v) => { rows = rows.filter(x => String(x[c]) === String(v)); return q; };
    if (p === 'single' || p === 'maybeSingle') return () => res(rows[0] || null);
    return () => q;
  } });
  return q;
}
window.__stubClient = {
  from: table,
  rpc: (fn, args) => {
    if (fn === 'whoami') return res([{ person_id:'p1', given_name:'Olive', family_name:'Office',
                                       roles:['membership'] }]);
    window.__rpc.push([fn, args]);
    if (fn === 'feed_link') return res(args.p_membership_number === 'AMI-0042' ? 'awarded' : null,
      args.p_membership_number === 'AMI-0042' ? null : { message: 'No member has the membership number ' + args.p_membership_number + '.' });
    if (fn === 'feed_dismiss') return res('not_member');
    return res([]);
  },
  auth: {
    getSession: () => res({ session: { access_token:'STAFF-TOKEN', user: { id:'u1', email:'office@test.invalid' } } }),
    getUser: () => res({ user: { id:'u1', email:'office@test.invalid' } }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null),
  },
  storage: { from: () => ({ upload: () => res({}), createSignedUrl: () => res({ signedUrl: 'data:,' }) }) },
  channel: () => ({ on(){ return this; }, subscribe(){ return this; } }),
  removeChannel: () => {},
};
window.__csp = [];
document.addEventListener('securitypolicyviolation', e =>
  window.__csp.push(e.violatedDirective + ' ' + (e.blockedURI || '')));
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
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await page.addInitScript(STUB);
  await page.route('https://fonts.googleapis.com/**', r => r.fulfill({ contentType: 'text/css', body: '' }));

  let zoomAsked = [], zoomAnswer = { status: 200, body: { lines: 52, counts: { awarded: 41, too_short: 3, unmatched: 2 }, warnings: [] } };
  await page.route('https://staging.ami.uk.com/api/zoom/attendance', async r => {
    zoomAsked.push({ headers: r.request().headers(), body: r.request().postData() });
    await r.fulfill({ status: zoomAnswer.status, contentType: 'application/json', body: JSON.stringify(zoomAnswer.body) });
  });
  let drained = 0, drainAuth = null;
  await page.route('https://staging.ami.uk.com/api/mail/drain', async r => {
    drained++; drainAuth = r.request().headers().authorization;
    await r.fulfill({ status: 200, contentType: 'application/json', body: '{"sent":0,"failed":0}' });
  });

  await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
  await page.waitForTimeout(900);
  const nav = n => page.evaluate(n => [...document.querySelectorAll('#nav button')].find(b => b.textContent === n).click(), n);
  const msg = () => page.evaluate(() => document.getElementById('msg').textContent.trim());

  // ---- The sessions screen ------------------------------------------------
  const names = await page.evaluate(() => [...document.querySelectorAll('#nav button')].map(b => b.textContent));
  ok(names.includes('Zoom sessions') && names.includes('People to match'),
     'membership staff see Zoom sessions and People to match');
  await nav('Zoom sessions');
  await page.waitForTimeout(300);
  const meta = await page.evaluate(() => (document.querySelector('.rec .meta') || {}).textContent || '');
  ok(/47 attended, 41 awarded, 3 to match/.test(meta), 'a session says what its last import found: ' + meta.trim());

  await page.evaluate(() => document.querySelector('[data-zoom^="fetch:"]').click());
  await page.waitForTimeout(500);
  ok(zoomAsked.length === 1, 'Fetch attendance reaches the site under the policy');
  ok(zoomAsked[0] && zoomAsked[0].headers.authorization === 'Bearer STAFF-TOKEN',
     'carrying the staff member\'s own sign in');
  ok(zoomAsked[0] && JSON.parse(zoomAsked[0].body).session === '5e550000-0000-0000-0000-000000000001'
     && Object.keys(JSON.parse(zoomAsked[0].body)).length === 1,
     'and nothing but which session: no attendance, no points, no names');
  ok(/Read 52 lines from Zoom/.test(await msg()) && /People to match/.test(await msg()),
     'and says what came back: ' + await msg());

  zoomAnswer = { status: 422, body: { error: 'The Zoom app is missing a permission. Zoom said: "does not contain scopes:[report:read:list_meeting_participants:admin]"' } };
  await page.evaluate(() => document.querySelector('[data-zoom^="fetch:"]').click());
  await page.waitForTimeout(500);
  ok(/report:read:list_meeting_participants:admin/.test(await msg()), 'Zoom refusing is said in Zoom\'s words');

  await page.evaluate(() => document.getElementById('addRow').click());
  await page.waitForTimeout(300);
  const editor = await page.evaluate(() => ({
    date: (document.getElementById('e_held_on') || {}).type,
    num: !!document.getElementById('e_zoom_id'),
    fk: document.querySelectorAll('#e_activity_type_id option').length }));
  ok(editor.date === 'date' && editor.num && editor.fk === 2,
     'a new session opens with a date picker, the number and the activity list');
  await page.evaluate(() => document.getElementById('drawer').classList.remove('on'));

  await page.evaluate(() => document.querySelector('[data-zoom^="who:"]').click());
  await page.waitForTimeout(400);
  const who = await page.evaluate(() => document.querySelectorAll('#mBody .rec').length);
  ok(who === 3, 'Who attended lists the session\'s people: ' + who);
  await page.evaluate(() => document.getElementById('modal').classList.remove('on'));

  // ---- People to match ------------------------------------------------------
  await nav('People to match');
  await page.waitForTimeout(400);
  const cards = await page.evaluate(() => [...document.querySelectorAll('.q h3')].map(h => h.textContent));
  ok(cards.length === 3, 'three are waiting to be matched: ' + cards.length);
  const safe = await page.evaluate(() => ({ xss: window.__xss, scripts: document.querySelectorAll('.q script').length,
                                            imgs: document.querySelectorAll('.q img').length }));
  ok(!safe.xss && safe.scripts === 0 && safe.imgs === 0, 'a name or address from Zoom arrives as words, never markup');

  const linkBtn = i => page.evaluate(i => [...document.querySelectorAll('.q')][i]
    .querySelector('[data-act$="|Link to a member"]').click(), i);
  await linkBtn(0);
  await page.waitForTimeout(200);
  ok(/remembered/.test(await page.evaluate(() => document.getElementById('mSub').textContent)),
     'linking an address says it will be remembered');
  await page.fill('#m_num', 'AMI-9999');
  await page.click('#mOk');
  await page.waitForTimeout(300);
  ok(/No member has the membership number AMI-9999/.test(await page.evaluate(() => document.getElementById('mMsg').textContent)),
     'a number nobody holds is refused in the dialog, which stays open');
  await page.fill('#m_num', ' AMI-0042 ');
  await page.click('#mOk');
  await page.waitForTimeout(300);
  const linked = await page.evaluate(() => window.__rpc.filter(c => c[0] === 'feed_link').pop());
  ok(linked && linked[1].p_row === 'a1' && linked[1].p_membership_number === 'AMI-0042',
     'and a real one is sent to feed_link, trimmed');
  ok(/points have gone onto their record/.test(await msg()), 'and the office is told the points went on');

  await linkBtn(1);
  await page.waitForTimeout(200);
  ok(/this session only/.test(await page.evaluate(() => document.getElementById('mSub').textContent)),
     'linking a display name says it is for this session only');
  await page.evaluate(() => document.getElementById('modal').classList.remove('on'));

  await page.evaluate(() => [...document.querySelectorAll('.q')][0].querySelector('[data-act$="|Not a member"]').click());
  await page.waitForTimeout(300);
  ok((await page.evaluate(() => window.__rpc.filter(c => c[0] === 'feed_dismiss').length)) === 1,
     'Not a member goes to feed_dismiss');

  // ---- And the mail drain, which the old policy refused -----------------------
  await nav('Email queue');
  await page.waitForTimeout(300);
  await page.evaluate(() => document.getElementById('qDrain').click());
  await page.waitForTimeout(400);
  ok(drained === 1, 'Send queued mail reaches the site too, which admin 18 to 21 refused');
  ok(drainAuth === 'Bearer STAFF-TOKEN', 'carrying the staff member\'s sign in, which the site now requires (31 October)');

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'with no policy violation anywhere: ' + (v[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
