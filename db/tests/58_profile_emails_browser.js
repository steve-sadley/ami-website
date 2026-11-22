/* Your emails on /profile (0062, site 76), in a real browser, under the
   site's real headers.

   Both emails are shown; a change is ASKED for, because ARCA's records own
   them; a pending request shows and can be withdrawn; a declined one says why;
   the member chooses which email AMI writes to; the sign-in box shows the
   account's address, not the record's; and an address made of markup arrives
   as words.

   Only window.supabase is replaced.

   Run:  node tests/58_profile_emails_browser.js [path-to-site]
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


const ids = { person: '11111111-1111-1111-1111-111111111111', member: '22222222-2222-2222-2222-222222222222' };
const BASE = { member_id: ids.member, person_id: ids.person, membership_number: 'TEST-0042',
  given_name: 'Jane', family_name: 'Tester', post_nominals: null, email: 'jane.work@test.invalid',
  mobile: null, home_address: null, business_address: null, photo_path: null, photo_strip_path: null,
  photo_consent: true, grade: 'Member', grade_post_nominals: 'MAMI', is_assessed: true, requires_cpd: true,
  employer: null, current_job_title: null, joined_on: '2021-04-01', is_active: true, status: 'current',
  list_on_register: true, public_profile: true, photo_on_public_page: false, forum_notifications: 'daily',
  email_newsletter: true, email_events: true, slug: 'jane-tester', cpd_required_core: 5,
  cpd_required_non_core: 5, last_year_recorded: 2026, card_issued_at: null, cpd_reminders: true,
  cpd_receipts: true, unsubscribe_token: '55555555-5555-5555-5555-555555555555',
  alt_email: 'jane.home@test.invalid', preferred_email: 'work', contact_email: 'jane.work@test.invalid',
  email_request_status: null, email_request_work: null, email_request_private: null,
  email_request_at: null, email_request_note: null };

const STUB = (profile) => `
window.__calls = [];
const PROFILE = ${JSON.stringify(profile)};
const res = (data, error) => Promise.resolve({ data, error: error || null });
function q(name){
  const rows = name === 'my_profile' ? [PROFILE] : [];
  let one = false;
  const chain = new Proxy({}, { get(_, p){
    if (p === 'then') return r => res(one ? (rows[0] || null) : rows).then(r);
    if (p === 'single' || p === 'maybeSingle') return () => { one = true; return chain; };
    if (['insert','update','upsert','delete'].includes(p)) return v => { window.__calls.push({ table: name, op: p, v }); return chain; };
    return () => chain;
  } });
  return chain;
}
window.__client = {
  from: q,
  rpc: (fn, args) => {
    window.__calls.push({ rpc: fn, args });
    if (fn === 'whoami') return res([{ person_id: '${ids.person}', member_id: '${ids.member}', given_name: 'Jane',
      family_name: 'Tester', roles: ['member'] }]);
    if (fn === 'link_account') return res('${ids.person}');
    if (fn === 'request_my_email_change') {
      if (args.p_work === 'jane.work@test.invalid' && args.p_private === 'jane.home@test.invalid')
        return res(null, { message: 'Those are the emails AMI already holds.' });
      return res({ id: 'r1', status: 'pending', work_email: args.p_work, private_email: args.p_private });
    }
    if (fn === 'withdraw_my_email_change') return res(true);
    if (fn === 'set_my_preferred_email') return res(args.p_choice === 'private' ? 'jane.home@test.invalid' : 'jane.work@test.invalid');
    return res(null);
  },
  auth: {
    getSession: () => res({ session: { access_token: 'tok', user: { id: 'u1', email: 'jane.signin@test.invalid' } } }),
    getUser: () => res({ user: { id: 'u1', email: 'jane.signin@test.invalid' } }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null), updateUser: () => res({}), resetPasswordForEmail: () => res({}),
  },
  storage: { from: () => ({ createSignedUrl: () => res({ signedUrl: 'data:,' }) }) },
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
  const open = async (profile) => {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    page.__errors = [];
    page.on('pageerror', e => page.__errors.push(String(e)));
    await page.route('**/storage/v1/**', r => r.fulfill({ contentType: 'image/png', body: Buffer.alloc(0) }));
    await page.addInitScript(STUB(profile));
    await page.goto(base + '/profile', { waitUntil: 'load' });
    await page.waitForTimeout(900);
    return page;
  };
  const val = (page, id) => page.evaluate(id => (document.getElementById(id) || {}).value, id);
  const text = (page, id) => page.evaluate(id => (document.getElementById(id) || {}).textContent || '', id);
  const calls = page => page.evaluate(() => window.__calls.filter(c => c.rpc && !['whoami','link_account'].includes(c.rpc)));

  // ---- the card as it opens -------------------------------------------------
  let page = await open(BASE);
  ok(await val(page, 'ework') === 'jane.work@test.invalid' && await val(page, 'eprivate') === 'jane.home@test.invalid',
     'both emails are shown, work and private');
  ok(await val(page, 'email') === 'jane.signin@test.invalid',
     'the sign-in box shows the account\'s own address, not the record\'s');
  const opts = await page.evaluate(() => [...document.querySelectorAll('#epref option')].map(o => o.value + '=' + o.textContent));
  ok(opts.length === 2 && /work=My work email: jane.work/.test(opts[0]) && /private=My private email: jane.home/.test(opts[1])
     && await val(page, 'epref') === 'work', 'Send AMI emails to offers both, on work: ' + opts.join(' | '));

  // asking for what is already held: the database's words
  await page.click('#ereqbtn');
  await page.waitForTimeout(300);
  ok(/already holds/.test(await text(page, 'emsg')), 'asking for what is held says so');

  // a bad address never leaves the page
  await page.fill('#eprivate', 'not an address');
  await page.click('#ereqbtn');
  await page.waitForTimeout(200);
  ok(/does not look like/.test(await text(page, 'emsg'))
     && (await calls(page)).filter(c => c.rpc === 'request_my_email_change').length === 1,
     'a bad address is stopped before it is sent');

  // a real change
  await page.fill('#ework', 'jane.newjob@test.invalid');
  await page.fill('#eprivate', 'jane.home@test.invalid');
  await page.click('#ereqbtn');
  await page.waitForTimeout(400);
  const asked = (await calls(page)).filter(c => c.rpc === 'request_my_email_change').pop();
  ok(asked && asked.args.p_work === 'jane.newjob@test.invalid' && asked.args.p_private === 'jane.home@test.invalid',
     'Ask for this change sends both addresses');
  ok(/Waiting for the AMI office/.test(await text(page, 'ereq')) && /jane.newjob@test.invalid/.test(await text(page, 'ereq'))
     && /Sent to the AMI office/.test(await text(page, 'emsg')),
     'and the card now says what is waiting');
  await page.click('#ewd');
  await page.waitForTimeout(300);
  ok((await calls(page)).some(c => c.rpc === 'withdraw_my_email_change') && /Withdrawn/.test(await text(page, 'emsg'))
     && !(await page.$('#ereq')), 'a waiting request can be withdrawn');

  // choosing
  await page.selectOption('#epref', 'private');
  await page.waitForTimeout(300);
  ok((await calls(page)).some(c => c.rpc === 'set_my_preferred_email' && c.args.p_choice === 'private')
     && /now writes to jane.home@test.invalid/.test(await text(page, 'epmsg')),
     'choosing private saves at once and says where AMI now writes');
  ok(page.__errors.length === 0, 'no page error: ' + (page.__errors[0] || ''));
  ok((await page.evaluate(() => window.__csp)).length === 0, 'and no policy violation');
  await page.close();

  // ---- a declined request, no private email, and markup as an address ----------
  page = await open(Object.assign({}, BASE, { alt_email: null, email: 'x<img src=x onerror="window.__xss=1">@test.invalid',
    email_request_status: 'declined', email_request_note: 'Please ring the office <script>window.__xss=2</script>',
    email_request_at: '2026-11-01T09:00:00Z' }));
  const declined = await text(page, 'ereq');
  ok(/did not make your last change/.test(declined) && /Please ring the office/.test(declined), 'a declined request says why');
  ok((await page.evaluate(() => [...document.querySelectorAll('#epref option')].map(o => o.value).join())) === 'work',
     'with no private email, only work is offered');
  ok(!(await page.evaluate(() => window.__xss)) && (await page.$$('#ereq script, .formcard img[onerror]')).length === 0,
     'markup in an address or a note arrives as words');
  await page.close();

  // ---- pending when the page opens -----------------------------------------------
  page = await open(Object.assign({}, BASE, { email_request_status: 'pending', email_request_work: 'jane.next@test.invalid',
    email_request_private: null, email_request_at: '2026-11-01T09:00:00Z' }));
  ok(/Waiting for the AMI office/.test(await text(page, 'ereq')) && /private: none/.test(await text(page, 'ereq'))
     && (await text(page, 'ereqbtn')).trim() === 'Replace my request',
     'a request already waiting is shown, and asking again replaces it');
  await page.close();

  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
