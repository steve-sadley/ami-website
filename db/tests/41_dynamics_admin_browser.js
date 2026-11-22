/* The admin app's ARCA records screens (0048), in a browser, under the app's
   real Content-Security-Policy.

   What this proves: the feeds screen has no New (there are three feeds, made
   by the migration), says which still need their columns naming, shows the
   column names the sync found as words, and saves only the columns the office
   may change, keyed by the feed's code; Sync now goes to the SITE carrying the
   staff member's own sign in and nothing else, and says what each view gave;
   Recent syncs reads the log; a course is decided through
   dynamics_course_decide; ARCA's rows in People to match read sensibly with no
   minutes; and nothing breaks the policy.

   Run:  node tests/41_dynamics_admin_browser.js [path-to-admin]
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
window.__rpc = []; window.__upd = [];
const ROWS = {
  dynamics_feeds: [
    { code:'arca_agm', title:'ARCA AGM', view_name:'AMI Sync: ARCA AGM', activity_code:'arca_agm',
      email_field:null, name_field:null, event_field:null, code_field:null, date_field:null, active:true,
      seen_entity:'arca_attendance', seen_fields:['arca_date','c.emailaddress1','<b>x</b>'], last_run_at:'2027-03-02T08:20:00Z',
      last_result:{ read:12, waiting:'the columns are not named yet' } },
    { code:'regional_meetings', title:'ARCA regional meetings', view_name:'AMI Sync: Regional meetings', activity_code:'regional_meeting_2027',
      email_field:'c.emailaddress1', name_field:'c.fullname', event_field:'_arca_meetingid_value', code_field:null, date_field:'arca_date', active:true,
      seen_entity:'arca_attendance', seen_fields:['arca_date'], last_run_at:'2027-03-02T08:20:00Z',
      last_result:{ read:40, unreadable:1, decided:{ awarded:30, unmatched:2 } } },
  ],
  dynamics_runs: [{ id:'r1', trigger:'schedule', status:'ok', started_at:'2027-03-02T08:20:00Z', requested_at:null },
                  { id:'r2', trigger:'office', status:'failed', started_at:'2027-03-02T09:00:00Z', requested_at:'2027-03-02T09:00:00Z',
                    error:'No system view is called "AMI Sync: Training completions".' },
                  ...Array.from({ length: 18 }, (_, i) => ({ id:'x' + i, trigger:'office', status:'failed',
                    started_at:'2027-03-01T09:00:00Z', requested_at:'2027-03-01T09:00:00Z',
                    error:'Dynamics refused (403). A long reason that wraps onto several lines in the dialog, as the real ones do.' }))],
  admin_dynamics_member_check: [
    { id:'d:c-9', kind:'dynamics_only', name:'Nora Nowhere', email:'nora@x.invalid', email2:null, category:'Fellow',
      membership_number:null, note:'Nobody on the website has either email.', updated_at:'2026-10-31T12:00:00Z' },
    { id:'w:m-4', kind:'website_only', name:'Ida Unlinked', email:'ida@x.invalid', email2:null, category:'Affiliate',
      membership_number:'AMI-0004', note:'An active member on the website who is not an AMI member in Dynamics.', updated_at:'2026-10-31T12:00:00Z' },
    { id:'c:mysterygrade', kind:'category', name:'Mystery Grade', category:'Mystery Grade', note:'Not mapped to a website grade yet.',
      updated_at:'2026-10-31T12:00:00Z' }],
  membership_grades: [{ id:'g1', code:'member', name:'Member' }, { id:'g2', code:'fellow', name:'Fellow' }],
  admin_dynamics_courses: [{ id:'c1', name:'Asbestos supervisor refresher', counts:null, completions:5, waiting:5, awarded:0,
                             first_seen:'2027-02-10T10:00:00Z' }],
  admin_dynamics_sessions: [{ id:'s1', feed:'regional_meetings', title:'North West regional meeting', held_on:'2027-03-04',
                              points:1, event_key:'regional-meeting-2027-03-04-north-west-abc123', people:32, awarded:30, to_match:2,
                              waiting:0, before_scheme:0 }],
  admin_cpd_feed_queue: [
    { id:'d1', source:'ARCA records', feed:'regional_meetings', session_id:'s1', session:'North West regional meeting',
      held_on:'2027-03-04', min_percent:null, counted_minutes:null, email:null, name:'Walk In', possible:'Wendy Inman (AMI-0042)',
      minutes:null, percent:null, outcome:'no_email', updated_at:'2027-03-04T12:00:00Z' },
    ...Array.from({ length: 2500 }, (_, i) => ({ id:'n' + i, source:'ARCA records', feed:'arca_training', session_id:'s2',
      session:'A course', held_on:'2026-05-01', email:'n' + i + '@x.invalid', name:'Person ' + i,
      minutes:null, percent:null, outcome:'unmatched', updated_at:'2026-05-01T12:00:00Z' }))],
};
function table(name){
  let rows = (ROWS[name] || []).slice();
  let upd = null;
  const q = new Proxy({}, { get(_, p){
    if (p === 'then') return r => res(rows).then(r);
    if (p === 'range') return (a, b) => { rows = rows.slice(a, b + 1); return q; };
    if (p === 'update') return body => { upd = { table: name, body }; window.__upd.push(upd); return q; };
    if (p === 'eq') return (c, v) => { if (upd) upd.eq = [c, v]; rows = rows.filter(x => String(x[c]) === String(v)); return q; };
    if (p === 'single' || p === 'maybeSingle') return () => res(rows[0] || null);
    return () => q;
  } });
  return q;
}
window.__stubClient = {
  from: table,
  rpc: (fn, args) => {
    if (fn === 'whoami') return res([{ person_id:'p1', given_name:'Olive', family_name:'Office', roles:['membership','super_user'] }]);
    window.__rpc.push([fn, args]);
    if (fn === 'dynamics_course_decide') return res({ awarded: 5 });
    if (fn === 'dynamics_grade_map_set') return res(null);
    if (fn === 'dynamics_members_load') return res({ go: args.p_go, count: 2, kept: 1, new: 1, register: 3, allowed: false,
      first: [{ number:'020615', name:'Adam Aardvark', grade:'Fellow', email:'a@x.invalid', how:'kept', joined:'12 Jun 2015' },
              { number:'011126', name:'Zoe Zebra', grade:'Member', email:'z@x.invalid', how:'new', joined:'01 Nov 2026' }],
      renumbered: [{ name:'Sam Linked', from:'TEST-1', to:'050918' }],
      not_in_dynamics: [{ number:'040817', name:'Gone Away', grade:'Associate' }],
      left_out: [{ name:'Myra Mystery', why:'AMI Category "Mystery" is not mapped to a grade.' }] });
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
  let asked = [], answer = null;
  await page.route('https://staging.ami.uk.com/api/dynamics/sync-now', async r => {
    asked.push({ headers: r.request().headers(), body: r.request().postData() });
    if (answer) return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(answer) });
    await r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ run:'r3', error:'x',
      feeds: { regional_meetings: { ready:true, read:40, unreadable:0, decided:{ awarded:3, unmatched:1 } },
               arca_agm: { ready:false, read:12 },
               arca_training: { error:'No system view is called "AMI Sync: Training completions".' } } }) });
  });

  await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
  await page.waitForTimeout(900);
  const nav = n => page.evaluate(n => [...document.querySelectorAll('#nav button')].find(b => b.textContent === n).click(), n);
  const msg = () => page.evaluate(() => document.getElementById('msg').textContent.trim());

  const names = await page.evaluate(() => [...document.querySelectorAll('#nav button')].map(b => b.textContent));
  ok(['ARCA records feeds', 'ARCA courses', 'ARCA meetings'].every(n => names.includes(n)),
     'membership staff see the three ARCA records screens');

  // ---- The feeds ----------------------------------------------------------
  await nav('ARCA records feeds');
  await page.waitForTimeout(300);
  ok(await page.evaluate(() => getComputedStyle(document.getElementById('addRow')).display === 'none'),
     'there is no New: the three feeds are the migration\'s');
  const metas = await page.evaluate(() => [...document.querySelectorAll('.rec .meta')].map(m => m.textContent));
  ok(/columns to name/.test(metas[0]) && /ready/.test(metas[1]) && /30 awarded, 2 not matched to a member/.test(metas[1]),
     'each feed says whether it is ready and what it last read: ' + metas.map(m => m.trim()).join(' / '));

  await page.evaluate(() => document.querySelector('[data-dyn="cols:0"]').click());
  await page.waitForTimeout(200);
  const cols = await page.evaluate(() => ({ tags: [...document.querySelectorAll('#mBody code')].map(c => c.textContent),
                                            bold: document.querySelectorAll('#mBody b').length }));
  ok(cols.tags.includes('c.emailaddress1') && cols.tags.includes('<b>x</b>') && cols.bold === 0,
     'Columns found lists the names the sync saw, as words');
  ok(await page.evaluate(() => getComputedStyle(document.querySelector('#mBody code')).textTransform) === 'none',
     'in their real case, not in capitals, so what is copied is what Dynamics calls it');
  await page.evaluate(() => document.getElementById('modal').classList.remove('on'));

  await page.evaluate(() => document.querySelector('[data-edit-rec="0"]').click());
  await page.waitForTimeout(200);
  await page.fill('#e_email_field', 'c.emailaddress1');
  await page.fill('#e_date_field', 'arca_date');
  await page.click('#dSave');
  await page.waitForTimeout(300);
  const u = await page.evaluate(() => window.__upd.pop());
  ok(u && u.table === 'dynamics_feeds' && u.eq && u.eq[0] === 'code' && u.eq[1] === 'arca_agm',
     'saving updates the feed by its code');
  ok(u && u.body.email_field === 'c.emailaddress1' && u.body.date_field === 'arca_date'
     && !('seen_entity' in u.body) && !('seen_fields' in u.body) && !('activity_code' in u.body),
     'with only the columns the office may change: ' + JSON.stringify(u && u.body));

  await page.evaluate(() => document.querySelector('[data-dyn^="sync:"]').click());
  await page.waitForTimeout(500);
  ok(asked.length === 1 && asked[0].headers.authorization === 'Bearer STAFF-TOKEN' && !asked[0].body,
     'Sync now reaches the site with the staff member\'s own sign in and nothing else');
  const m = await msg();
  ok(/Regional meetings: 40 rows, 3 awarded, 1 not matched to a member/.test(m) && /ARCA AGM: 12 rows read, but the columns are not named yet/.test(m)
     && /Training: No system view is called/.test(m), 'and says what each view gave: ' + m);

  answer = { run:'r4', feeds:{}, error:'Signing in to Dynamics: Microsoft refused (400, unauthorized_client). Check CLIENT_ID, CLIENT_SECRET and TENANT_ID.' };
  await page.evaluate(() => document.querySelector('[data-dyn^="sync:"]').click());
  await page.waitForTimeout(500);
  ok(/Microsoft refused \(400, unauthorized_client\)/.test(await msg()),
     'a sign in refused by Microsoft is said in its own words, not as the site being unreachable: ' + await msg());

  await page.evaluate(() => document.querySelector('[data-dyn^="runs:"]').click());
  await page.waitForTimeout(300);
  const runs = await page.evaluate(() => document.getElementById('mBody').textContent);
  ok(/On the schedule/.test(runs) && /Sync now/.test(runs) && /No system view is called/.test(runs),
     'Recent syncs reads the log, errors and all');
  ok(/failed/i.test(await page.evaluate(() => document.querySelector('#mBody .tag.off')?.textContent || '')),
     'and a failed run says failed');
  const fit = await page.evaluate(() => { const b = document.getElementById('mOk').getBoundingClientRect();
    return { top: b.top, bottom: b.bottom, h: innerHeight }; });
  ok(fit.top > 0 && fit.bottom <= fit.h, 'a long list scrolls inside the dialog and Close stays on screen: ' + JSON.stringify(fit));
  await page.click('#mOk');
  ok(await page.evaluate(() => !document.getElementById('modal').classList.contains('on')), 'and Close closes it, clicked for real');

  // ---- Courses, meetings, the queue ----------------------------------------
  await nav('ARCA courses');
  await page.waitForTimeout(300);
  await page.evaluate(() => document.querySelector('[data-act$="|Counts"]').click());
  await page.waitForTimeout(300);
  const dec = await page.evaluate(() => window.__rpc.filter(c => c[0] === 'dynamics_course_decide').pop());
  ok(dec && dec[1].p_course === 'c1' && dec[1].p_counts === true, 'Counts goes to dynamics_course_decide');
  ok(/5 people have the point on their record/.test(await msg()), 'and says who was awarded: ' + await msg());

  await nav('ARCA meetings');
  await page.waitForTimeout(300);
  const meet = await page.evaluate(() => document.querySelector('.q .meta').textContent);
  ok(/regional-meeting-2027-03-04-north-west-abc123/.test(meet) && /2 not matched to a member/.test(meet),
     'a meeting shows its event key for a recording to share');

  await nav('People to match');
  await page.waitForTimeout(300);
  ok(await page.evaluate(() => document.querySelectorAll('.q').length) === 0,
     'ARCA\'s records do not bury the Zoom people in To match');
  await page.evaluate(() => document.querySelector('[data-tab="arca"]').click());
  await page.waitForTimeout(300);
  const pg = await page.evaluate(() => ({ all: document.querySelector('[data-tab="all"]').textContent,
    count: document.querySelector('.count').textContent, cards: document.querySelectorAll('.q').length }));
  ok(/2501/.test(pg.all), 'every row is read, a thousand at a time, not just the first thousand: ' + pg.all.trim());
  ok(pg.cards === 200 && /First 200 of 2501: search to narrow/.test(pg.count), 'and the list draws 200 and says so');
  await page.fill('#qSearch', 'Walk In');
  await page.waitForTimeout(300);
  const card = await page.evaluate(() => document.querySelector('.q .meta').textContent);
  ok(/no email in ARCA's records/.test(card) && /ARCA records: North West regional meeting/.test(card) && !/null|undefined|NaN/.test(card),
     'ARCA\'s rows read sensibly in People to match: ' + card.trim());
  ok(/Possibly: Wendy Inman \(AMI-0042\)/.test(card), 'and a possible member is named');

  // ---- Members and Dynamics (0054) ----------------------------------------------
  await nav('Members and Dynamics');
  await page.waitForTimeout(300);
  const tabs = await page.evaluate(() => [...document.querySelectorAll('[data-tab]')].map(b => b.textContent.replace(/\s+/g, ' ').trim()));
  ok(tabs.join('|') === 'In Dynamics only 1|On the website only 1|AMI Categories 1', 'the check list has its three tabs: ' + tabs.join(' | '));
  await page.click('[data-tab="cat"]');
  await page.waitForTimeout(200);
  await page.click('[data-act="c:mysterygrade|Map to a grade"]');
  await page.waitForTimeout(300);
  await page.selectOption('#m_g', 'member');
  await page.click('#mOk');
  await page.waitForTimeout(300);
  const mapped = await page.evaluate(() => window.__rpc.filter(c => c[0] === 'dynamics_grade_map_set').pop());
  ok(mapped && mapped[1].p_category_key === 'mysterygrade' && mapped[1].p_grade_code === 'member',
     'an AMI Category is mapped to a grade, chosen from a list, with real clicks');
  ok(/Mystery Grade now becomes Member/.test(await msg()), 'and the office is told: ' + await msg());

  await page.click('#qLoad');
  await page.waitForTimeout(400);
  const load = await page.evaluate(() => ({ title: document.getElementById('mTitle').textContent,
    body: document.getElementById('mBody').textContent, ok: document.getElementById('mOk').textContent }));
  const loads = await page.evaluate(() => window.__rpc.filter(c => c[0] === 'dynamics_members_load').map(c => c[1].p_go));
  ok(/2 members would be created/.test(load.title) && /020615/.test(load.body) && /kept, joined 12 Jun 2015/.test(load.body)
     && /011126/.test(load.body) && /new number/.test(load.body) && /was TEST-1/.test(load.body)
     && /Gone Away/.test(load.body) && /not mapped/.test(load.body)
     && load.ok === 'Close' && loads.join() === 'false',
     'Create website members previews at once: kept and new numbers, renumbered, not in Dynamics, left out; locked, so only Close: ' + load.title);
  await page.click('#mOk');
  await page.waitForTimeout(200);
  ok((await page.evaluate(() => window.__rpc.filter(c => c[0] === 'dynamics_members_load' && c[1].p_go).length)) === 0,
     'and nothing is created');

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'with no policy violation anywhere: ' + (v[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
