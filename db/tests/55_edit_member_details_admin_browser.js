/* Edit details on the Members card (0060 and 0061, admin 45), in a browser, under the
   admin app's real Content-Security-Policy.

   Only window.supabase is replaced. update_member_details answers as the
   database would: a number already held is refused with its own words.

   Run:  node tests/55_edit_member_details_admin_browser.js [path-to-admin]
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
  admin_member_list: [
    { id:'m1', given_name:'Jo', family_name:'Bloggs', email:'jo@test.invalid', alt_email:'jo.home@test.invalid',
      membership_number:'020626', grade:'Fellow', status:'current', is_active:true, has_account:true,
      joined_on:'2020-01-01', current_job_title:'Contracts Manager', employer:'Bloggs Removals Ltd', in_dynamics:true,
      preferred_email:'work', contact_email:'jo@test.invalid' },
    { id:'m2', given_name:'Al', family_name:'Unlinked', email:'al@test.invalid', membership_number:'010525',
      grade:'Member', status:'current', is_active:true, has_account:false, joined_on:'2025-05-01', in_dynamics:false } ],
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
    if (fn === 'whoami') return res([{ person_id:'p1', given_name:'Olive', family_name:'Office',
           roles:(JSON.parse(sessionStorage.getItem('roles') || 'null') || ['membership']) }]);
    if (fn === 'update_member_details') { window.__w.push(['rpc', fn, args]);
      if (args.p_membership_number === '010525')
        return res(null, { message: 'Membership number 010525 is already held by another member.' });
      return res({ membership_number: args.p_membership_number, number_changed: args.p_membership_number !== '020626',
        contact_email: args.p_preferred_email === 'private' ? 'jo.home@test.invalid' : 'jo@test.invalid' }); }
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

  await nav('Members');
  await page.waitForTimeout(400);
  const card = await page.evaluate(() => document.querySelector('.q').textContent.replace(/\s+/g, ' '));
  ok(/Bloggs Removals Ltd/.test(card), 'the card now shows the employer: ' + card.slice(0, 160));
  ok(/jo@test.invalid work email/.test(card), 'and the address AMI writes to, marked work or private');
  ok(await page.$('[data-act$="|Edit details"]'), 'membership staff are offered Edit details');

  // open it with a real click, so anything lying over it would fail the test
  await page.click('[data-act$="|Edit details"]');
  await page.waitForTimeout(300);
  const d = await page.evaluate(() => ({
    sub: document.getElementById('mSub').textContent,
    num: document.getElementById('m_num').value, date: document.getElementById('m_date').value,
    title: document.getElementById('m_title').value, emp: document.getElementById('m_emp').value,
    fields: [...document.querySelectorAll('#mBody input')].map(i => i.id) }));
  ok(d.num === '020626' && d.date === '2020-01-01' && d.title === 'Contracts Manager' && d.emp === 'Bloggs Removals Ltd',
     'the dialog opens with what is held: ' + JSON.stringify(d));
  ok(/come from ARCA's Dynamics/.test(d.sub) && /Email Address 2 the private one/.test(d.sub) && /Fellow/.test(d.sub),
     'and says what Dynamics owns, and which Dynamics field is which email');
  const pref = await page.evaluate(() => ({ v: document.getElementById('m_pref').value,
    o: [...document.querySelectorAll('#m_pref option')].map(o => o.value + '=' + o.textContent) }));
  ok(pref.v === 'work' && pref.o.join('|') === 'work=Work email: jo@test.invalid|private=Private email: jo.home@test.invalid',
     'Send AMI emails to offers the work and private emails, on work: ' + JSON.stringify(pref));
  ok(d.fields.join() === 'm_num,m_date,m_title,m_emp', 'and offers only the four the website holds: ' + d.fields.join());

  // a number another member holds: the database's words are shown and the dialog stays
  await page.fill('#m_num', '010525');
  await page.click('#mOk');
  await page.waitForTimeout(300);
  const refused = await page.evaluate(() => ({ msg: document.getElementById('mMsg').textContent,
    open: document.getElementById('modal').classList.contains('on') }));
  ok(refused.open && /already held by another member/.test(refused.msg), 'a refused number is explained and the dialog stays open: ' + refused.msg);

  // a good one, typed untidily
  await page.fill('#m_num', ' 030626 ');
  await page.fill('#m_title', 'Operations Director');
  await page.fill('#m_emp', 'New Employer Ltd');
  await page.selectOption('#m_pref', 'private');
  await page.click('#mOk');
  await page.waitForTimeout(400);
  const call = (await w()).filter(x => x[1] === 'update_member_details').pop();
  ok(call && call[2].p_member_id === 'm1' && call[2].p_membership_number === '030626' && call[2].p_joined_on === '2020-01-01'
     && call[2].p_current_job_title === 'Operations Director' && call[2].p_employer === 'New Employer Ltd'
     && call[2].p_preferred_email === 'private',
     'Save sends the values and the email choice, the number trimmed: ' + JSON.stringify(call && call[2]));
  ok(/now writes to jo.home@test.invalid/.test(await msg()), 'and says which address AMI now writes to');
  ok(/now 030626/.test(await msg()) && /Reissue their card/.test(await msg()), 'and a new number says to reissue the card: ' + await msg());
  ok(!(await page.evaluate(() => document.getElementById('modal').classList.contains('on'))), 'the dialog closes');

  // a member not linked to Dynamics
  await page.evaluate(() => [...document.querySelectorAll('.q')][1].querySelector('[data-act$="|Edit details"]').click());
  await page.waitForTimeout(300);
  ok(/not linked to Dynamics yet/.test(await page.evaluate(() => document.getElementById('mSub').textContent)),
     'an unlinked member is said to be unlinked');
  ok((await page.evaluate(() => [...document.querySelectorAll('#m_pref option')].map(o => o.value).join())) === 'work',
     'and with no private email, work is the only choice');
  await page.evaluate(() => document.getElementById('modal').classList.remove('on'));

  // somebody without a membership role sees no button
  await page.evaluate(() => sessionStorage.setItem('roles', JSON.stringify(['editor'])));
  await page.reload();
  await page.waitForTimeout(900);
  await page.evaluate(() => { const b = [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'Members'); if (b) b.click(); });
  await page.waitForTimeout(400);
  ok(!(await page.$('[data-act$="|Edit details"]')), 'an editor is not offered Edit details');

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'no policy violation anywhere: ' + (v[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));
  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
