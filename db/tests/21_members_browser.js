/* The members area, in a real browser, under the site's real headers.

   REBUILT 30 October 2026. The original was members.spec.js, 125 checks, in a
   member area test bundle that was lost. This is not a copy of it, because
   nobody has it to copy: it is written again from what the members area does
   and what this project has learned the hard way. It is smaller and it says so;
   the handover lists what it does not yet cover.

   What it does cover:

     THE GUARD. A members page visited signed out goes to the sign in page and
     draws nothing first.

     EVERY MEMBERS PAGE DRAWS. /me, /cpd, /profile, /photo, /forum, /t/<slug>
     and /card, each with realistic rows, no page error, and no content
     security policy violation. The real _headers is applied, so a page that
     needed an inline script would fail here rather than for a member.

     THE PUBLIC RECORD. /m/<slug> for a current member, for one whose
     membership has ended, and for a slug nobody holds. The second and third
     are different answers on purpose, and neither may be a blank page.

     MEMBER TEXT IS WORDS, NEVER MARKUP. The forum and the CPD log are the
     largest bodies of member written text on the site. A payload carrying a
     script element and an onerror handler is put into every free text field
     that reaches a page, and the assertion is that nothing ran, no script
     element appeared, and the words are still there to read.

   Only window.supabase is replaced. site.js, the page scripts, the guard and
   the sanitiser all run.

   Run:  node tests/21_members_browser.js [path-to-site]
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

// ---- the data ---------------------------------------------------------------
const WORDS = 'Plain words survive';
const P = `${WORDS} <img src=x onerror="window.__xss=(window.__xss||0)+1"><script>window.__xss=99</script>`;
const now = new Date().toISOString();
const year = new Date().getFullYear();
const ids = { person: '11111111-1111-1111-1111-111111111111', member: '22222222-2222-2222-2222-222222222222',
              cat: '33333333-3333-3333-3333-333333333333', thread: '44444444-4444-4444-4444-444444444444' };

const PROFILE = { member_id: ids.member, person_id: ids.person, membership_number: 'TEST-0042',
  given_name: 'Jane', family_name: 'Tester', post_nominals: 'MAMI', email: 'jane@test.invalid',
  mobile: '07000 000000', home_address: { line1: P, town: 'Burton', postcode: 'DE13 0BY' },
  business_address: null, photo_path: null, photo_strip_path: null, photo_consent: true,
  grade: 'Member', grade_post_nominals: 'MAMI', is_assessed: true, requires_cpd: true, employer: P,
  current_job_title: P, joined_on: '2021-04-01', is_active: true, status: 'current',
  list_on_register: true, public_profile: true, photo_on_public_page: false, forum_notifications: 'replies',
  email_newsletter: true, email_events: true, slug: 'jane-tester', cpd_required_core: 5,
  cpd_required_non_core: 5, last_year_recorded: year, card_issued_at: null, cpd_reminders: true,
  cpd_receipts: true, unsubscribe_token: '55555555-5555-5555-5555-555555555555' };

const DATA = {
  my_profile: [PROFILE],
  my_cpd_summary: [{ member_id: ids.member, year, core_points: 3, non_core_points: 2, entry_count: 2,
    requirement_met: false, core_required: 5, non_core_required: 5, requires_cpd: true, pending_count: 1,
    rejected_count: 0, points_automatic: 0, points_awarded: 0, points_self: 5 }],
  my_cpd: [
    { id: 'c1', year, occurred_on: `${year}-03-01`, title: P, provider: P, points: 3, is_core: true,
      how_recorded: 'self', status: 'accepted', evidence_ref: null, duration_minutes: 180, recorded_at: now,
      reviewed_at: now, review_note: P, activity_type: 'Assessed training course', activity_code: 'course', evidence_count: 0 },
    { id: 'c2', year, occurred_on: `${year}-04-01`, title: 'Toolbox talk', provider: 'Own firm', points: 2,
      is_core: false, how_recorded: 'self', status: 'pending', evidence_ref: null, duration_minutes: 60,
      recorded_at: now, reviewed_at: null, review_note: null, activity_type: 'An in house briefing', activity_code: 'briefing', evidence_count: 0 },
    // 0043: an entry a person accepted with Claude's recommendation in front of them.
    { id: 'c3', year, occurred_on: `${year}-05-01`, title: 'Supervisor refresher reflection', provider: null, points: 2,
      is_core: false, how_recorded: 'self_declared', status: 'accepted', evidence_ref: null, duration_minutes: null,
      recorded_at: now, reviewed_at: now, review_note: null, activity_type: 'Reflection following a training course',
      activity_code: 'training_reflection', evidence_count: 0, ai_assisted: true },
  ],
  my_recent: [{ kind: 'cpd', title: P, detail: P, happened_at: now, href: '/cpd' }],
  public_content: [{ kind: 'event', slug: 'test-agm', title: 'Test AGM', summary: 'An event', published_at: now,
    category: null, image_path: null, starts_at: new Date(Date.now() + 864e6).toISOString(), location: 'Burton' }],
  // The 2027 scheme's shape (0038): a value on each type, some needing a
  // reflection or evidence, some not loggable by hand at all.
  cpd_activity_types: [
    { id: 't1', code: 'ami_seminar', name: 'AMI Seminar', is_core: true, sort_order: 30, points: 3,
      min_words: 0, member_can_log: false, needs_evidence: false, guidance: 'From attendance.' },
    { id: 't2', code: 'technical_review', name: 'Technical Review', is_core: true, sort_order: 40, points: null,
      min_words: 0, member_can_log: false, needs_evidence: false, guidance: null },
    { id: 't3', code: 'external_training', name: 'External training course or seminar', is_core: false,
      sort_order: 130, points: 1, min_words: 0, member_can_log: true, needs_evidence: true,
      guidance: 'Attach the certificate.' },
    { id: 't4', code: 'training_reflection', name: 'Reflection following a training course', is_core: false,
      sort_order: 150, points: 2, min_words: 500, member_can_log: true, needs_evidence: false,
      guidance: 'At least 500 words.' },
    { id: 't5', code: 'self_directed', name: 'Self Directed Learning', is_core: false, sort_order: 180,
      points: 1, min_words: 0, member_can_log: true, needs_evidence: false, guidance: 'Anything else.' },
    { id: 't6', code: 'qualification', name: 'Formal asbestos qualification (RSPH, NVQ, BOHS)', is_core: false,
      sort_order: 140, points: 2, min_words: 0, member_can_log: true, needs_evidence: true,
      guidance: 'Attach the certificate.' }],
  cpd_evidence: [],
  member_preferences: [{ member_id: ids.member, list_on_register: true, public_profile: true,
    photo_on_public_page: false, forum_notifications: 'replies', email_newsletter: true, email_events: true,
    cpd_reminders: true, cpd_receipts: true }],
  my_posts: [{ id: 'mp1', thread_id: ids.thread, thread: P, thread_slug: 'test-thread', category: 'General',
    body: P, status: 'published', created_at: now, edited_at: null }],
  forum_category_list: [{ id: ids.cat, slug: 'general', name: P, description: P, sort_order: 1, locked: false,
    thread_count: 1, last_post_at: now }],
  forum_thread_list: [{ id: ids.thread, slug: 'test-thread', title: P, category_id: ids.cat, category_slug: 'general',
    category: P, pinned: false, locked: false, post_count: 2, last_post_at: now, created_at: now,
    given_name: P, family_name: 'Tester', post_nominals: 'MAMI', grade: 'Member', photo_path: null, mine: true }],
  forum_post_list: [
    { id: 'p1', thread_id: ids.thread, seq: 1, body: P + '\n\nSecond paragraph https://example.org/x',
      status: 'published', held_reason: null, created_at: now, edited_at: null, given_name: P, family_name: 'Tester',
      post_nominals: 'MAMI', grade: 'Member', employer: P, photo_path: null, author_slug: 'jane-tester',
      mine: true, can_edit: true, endorsed: false },
    { id: 'p2', thread_id: ids.thread, seq: 2, body: 'A reply', status: 'published', held_reason: null,
      created_at: now, edited_at: null, given_name: 'Sam', family_name: 'Other', post_nominals: null,
      grade: 'Associate', employer: null, photo_path: null, author_slug: 'sam-other', mine: false,
      can_edit: false, endorsed: false }],
  forum_posts: [], forum_reports: [],
  my_learning: [
    { id: 'L1', slug: 'test-review', title: 'TEST Technical Review ' + P, kind: 'read', summary: P,
      body: '<p>' + WORDS + ' about the regulations.</p><script>window.__xss=7</script>', vimeo_id: null,
      min_watch_percent: 80, points: 1.5, activity_type: 'Technical Review', is_core: true, pass_mark: 80,
      max_attempts: 2, published_at: now, attempts_used: 0, passed: false, already_counted: false,
      questions: [{ q: 'Which is right? ' + P, options: ['Option A ' + P, 'Option B'] },
                  { q: 'Second?', options: ['Yes', 'No', 'Maybe'] }] },
    { id: 'L2', slug: 'test-seminar', title: 'TEST seminar recording', kind: 'watch', summary: 'A recording',
      body: null, vimeo_id: '123456789', min_watch_percent: 80, points: 3, activity_type: 'AMI Seminar',
      is_core: true, pass_mark: 80, max_attempts: 2, published_at: now, attempts_used: 0, passed: false,
      already_counted: false, questions: [{ q: 'Q?', options: ['a', 'b'] }] },
    { id: 'L3', slug: 'test-done', title: 'TEST already passed', kind: 'read', summary: 'Done one', body: '<p>x</p>',
      vimeo_id: null, min_watch_percent: 0, points: 1, activity_type: 'ARCA News Updates', is_core: false,
      pass_mark: 80, max_attempts: 2, published_at: now, attempts_used: 1, passed: true, already_counted: false,
      questions: [{ q: 'Q?', options: ['a', 'b'] }] }],
  my_card: [{ member_id: ids.member, membership_number: 'TEST-0042', given_name: 'Jane', family_name: 'Tester',
    post_nominals: 'MAMI', grade: 'Member', grade_post_nominals: 'MAMI', is_assessed: true, requires_cpd: true,
    joined_on: '2021-04-01', is_active: true, status: 'current', photo_strip_path: null, photo_path: null,
    slug: 'jane-tester', scopes: [], cpd_core: 3, cpd_non_core: 2, cpd_required_total: 10, pass_id: null,
    pass_platform: null, serial_number: null, pass_issued_at: null, times_issued: 0 }],
  public_profile: [
    { slug: 'jane-tester', membership_number: 'TEST-0042', given_name: 'Jane', family_name: 'Tester',
      post_nominals: 'MAMI', grade: 'Member', is_assessed: true, requires_cpd: true, is_active: true,
      employer: P, joined_on: '2021-04-01', photo_path: null, cpd_status: 'on track', cpd_period: year, verified_at: now },
    { slug: 'old-member', membership_number: 'TEST-0001', given_name: 'Olive', family_name: 'Former',
      post_nominals: null, grade: 'Member', is_assessed: true, requires_cpd: true, is_active: false,
      employer: null, joined_on: '2015-01-01', photo_path: null, cpd_status: null, cpd_period: null, verified_at: now }],
};

const STUB = (signedIn, data) => `
window.__calls = [];
const DATA = ${JSON.stringify(data)};
const res = (data, error) => Promise.resolve({ data, error: error || null });
function q(name){
  let rows = (DATA[name] || []).slice(), one = false;
  const chain = new Proxy({}, { get(_, p){
    if (p === 'then') return r => res(one ? (rows[0] || null) : rows).then(r);
    if (p === 'eq') return (c, v) => { rows = rows.filter(x => !(c in x) || String(x[c]) === String(v)); return chain; };
    if (p === 'in') return (c, vs) => { rows = rows.filter(x => !(c in x) || vs.map(String).includes(String(x[c]))); return chain; };
    if (p === 'single' || p === 'maybeSingle') return () => { one = true; return chain; };
    if (['insert','update','upsert','delete'].includes(p))
      return v => { window.__calls.push({ table: name, op: p, v }); return chain; };
    return () => chain;
  } });
  return chain;
}
window.__client = {
  from: q,
  rpc: (fn, args) => {
    window.__calls.push({ rpc: fn, args });
    if (fn === 'whoami') return res(${signedIn} ? [{ person_id: '${ids.person}', member_id: '${ids.member}',
      email: 'jane@test.invalid', given_name: 'Jane', family_name: 'Tester', roles: ['member'] }] : []);
    if (fn === 'link_account') return res('${ids.person}');
    if (fn === 'log_reflection_with_certificate') return res({ reflection_id: 'r1', certificate_id: 'c1' });
    if (fn === 'cpd_evidence_seen') return res(window.__seen === true);
    if (fn === 'submit_learning') return res(args.p_answers[0] === 0
      ? { correct: 2, total: 2, score: 100, passed: true, pass_mark: 80, attempts_left: 1, points: 1.5, already_counted: false }
      : { correct: 1, total: 2, score: 50, passed: false, pass_mark: 80, attempts_left: 1, points: 0, already_counted: false });
    return res(null);
  },
  auth: {
    getSession: () => res({ session: ${signedIn} ? { access_token: 'tok', user: { id: 'u1', email: 'jane@test.invalid' } } : null }),
    getUser: () => res({ user: ${signedIn} ? { id: 'u1', email: 'jane@test.invalid' } : null }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null), signInWithOtp: () => res({}), updateUser: () => res({}),
  },
  storage: { from: () => ({ createSignedUrl: () => res({ signedUrl: 'data:,' }),
                            upload: () => res({ path: 'x' }), remove: () => res(null) }) },
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

  async function visit(p, signedIn = true, data = DATA){
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/storage/v1/**', r => r.fulfill({ contentType: 'image/png', body: Buffer.alloc(0) }));
    // 0045: evidence goes to the Worker. Recorded so the checks can see it.
    page.__evidence = [];
    await page.route('**/api/cpd/evidence', async r => {
      page.__evidence.push({ auth: r.request().headers().authorization, body: r.request().postDataBuffer() });
      await r.fulfill({ status: 200, contentType: 'application/json', body: '{"id":"ev1"}' });
    });
    await page.addInitScript(STUB(signedIn, data));
    await page.goto(base + p, { waitUntil: 'load' });
    await page.waitForTimeout(900);
    const got = await page.evaluate(() => ({
      url: location.pathname + location.search,
      text: document.body.innerText,
      xss: window.__xss || 0,
      scripts: [...document.querySelectorAll('main script, body > div script')].length,
      imgs: [...document.querySelectorAll('img[onerror*="__xss"]')].length,
      inputs: [...document.querySelectorAll('input, textarea')].map(i => i.value).join(' | '),
      csp: window.__csp,
      calls: window.__calls,
    }));
    got.errors = errors;
    await page.close();
    return got;
  }

  // ---- the guard -------------------------------------------------------------
  console.log('\nthe guard');
  for (const p of ['/me', '/cpd', '/profile', '/photo', '/forum', '/card']) {
    const g = await visit(p, false);
    ok(/^\/login/.test(g.url), `${p} signed out goes to the sign in page, got ${g.url}`);
    ok(!/TEST-0042|jane@test\.invalid/.test(g.text), `${p} signed out shows nothing of the member's record`);
  }

  // ---- every members page draws ------------------------------------------------
  console.log('\nthe members pages');
  const expect = {
    '/me':        ['Jane'],
    '/cpd':       [WORDS, 'Toolbox talk', 'reviewed with AI help'],
    '/profile':   ['jane@test.invalid', WORDS],
    '/photo':     [],
    '/forum':     [WORDS],
    '/t/test-thread': [WORDS, 'A reply'],
    '/card':      ['TEST-0042'],
  };
  for (const [p, words] of Object.entries(expect)) {
    const g = await visit(p);
    ok(g.url.split('?')[0] === p, `${p} stays on ${p} for a signed in member, got ${g.url}`);
    ok(g.errors.length === 0, `${p} draws with no page error: ${g.errors[0] || ''}`);
    ok(g.csp.length === 0, `${p} runs under the site's content security policy: ${g.csp[0] || ''}`);
    // Shown, or offered for editing: a value in an input is not in innerText.
    for (const w of words) ok(g.text.includes(w) || g.inputs.includes(w), `${p} shows "${w}"`);
    ok(g.xss === 0 && g.imgs === 0, `${p}: member text arrived as words, nothing ran (xss=${g.xss}, onerror images=${g.imgs})`);
    ok(!/onerror=|<script/.test(g.text) || g.text.includes(WORDS),
       `${p}: no markup is shown as if it were content`);
  }

  // ---- logging CPD under the 2027 scheme --------------------------------------
  console.log('\nlogging CPD');
  {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    page.__evidence = [];
    await page.route('**/api/cpd/evidence', async r => {
      page.__evidence.push({ auth: r.request().headers().authorization, body: r.request().postDataBuffer() });
      await r.fulfill({ status: 200, contentType: 'application/json', body: '{"id":"ev1"}' });
    });
    await page.addInitScript(STUB(true, DATA));
    await page.goto(base + '/cpd', { waitUntil: 'load' });
    await page.waitForTimeout(800);
    await page.evaluate(() => document.getElementById('logbtn').click());
    await page.waitForTimeout(300);
    const opts = await page.evaluate(() =>
      [...document.querySelectorAll('#type option')].map(o => o.textContent.trim()).filter(Boolean));
    ok(!opts.includes('AMI Seminar') && !opts.includes('Technical Review'),
       'the form does not offer what arrives by itself: ' + opts.join(' | '));
    ok(opts.includes('Self Directed Learning') && opts.includes('Reflection following a training course'),
       'and does offer what a member logs');
    ok(await page.evaluate(() => !document.getElementById('points')), 'and there is no points box to fill in');

    await page.selectOption('#type', 't4');
    let st = await page.evaluate(() => ({
      worth: document.getElementById('worth').textContent,
      refl: getComputedStyle(document.getElementById('reflbox')).display,
      off: document.getElementById('send').disabled,
      wc: document.getElementById('wc').textContent }));
    ok(/2 points, non core/.test(st.worth), 'choosing it says what it is worth: ' + st.worth);
    ok(st.refl !== 'none' && st.off && /0 of 500/.test(st.wc),
       'and opens the reflection, with Send off at 0 of 500: ' + st.wc);
    await page.fill('#refl', Array.from({ length: 499 }, (_, i) => 'word' + i).join(' ') + ' --- ...');
    st = await page.evaluate(() => ({ off: document.getElementById('send').disabled,
                                      wc: document.getElementById('wc').textContent }));
    ok(st.off && /499 of 500/.test(st.wc), 'punctuation is not words, and 499 is not enough: ' + st.wc);
    await page.fill('#refl', Array.from({ length: 500 }, (_, i) => 'don\'t' + i).join(' '));
    st = await page.evaluate(() => ({ off: document.getElementById('send').disabled,
                                      wc: document.getElementById('wc').textContent }));
    ok(!st.off && /500 words/.test(st.wc), 'at 500 it can be sent: ' + st.wc);
    await page.fill('#title', 'TEST reflection on a course');
    await page.evaluate(() => { window.__calls = []; document.getElementById('send').click(); });
    await page.waitForTimeout(500);
    const call = await page.evaluate(() => window.__calls.find(c => c.rpc === 'log_cpd'));
    ok(call && !('p_points' in call.args) && call.args.p_activity_type_id === 't4'
       && (call.args.p_reflection || '').length > 2000,
       'it sends the activity and the reflection and no points: ' + JSON.stringify(call ? Object.keys(call.args) : null));

    await page.evaluate(() => document.getElementById('logbtn') && document.getElementById('logbtn').click());
    await page.waitForTimeout(300);
    await page.selectOption('#type', 't3');
    await page.fill('#title', 'TEST outside course');
    await page.evaluate(() => { window.__calls = []; document.getElementById('send').click(); });
    await page.waitForTimeout(300);
    const ev = await page.evaluate(() => ({ msg: document.getElementById('fmsg').textContent,
      sent: window.__calls.filter(c => c.rpc === 'log_cpd').length }));
    ok(ev.sent === 0 && /attach evidence/i.test(ev.msg), 'an activity needing evidence is not sent without it: ' + ev.msg);

    // 0044: a reflection with its course certificate earns both. The first
    // send above redraws the log 1.2 seconds later, form and all, so wait for
    // that and open the form afresh, or the checks race the redraw.
    await page.waitForTimeout(1500);
    await page.evaluate(() => document.getElementById('logbtn') && document.getElementById('logbtn').click());
    await page.waitForSelector('#type');
    await page.selectOption('#type', 't4');
    let cb = await page.evaluate(() => ({ label: document.getElementById('filelabel').textContent,
      box: getComputedStyle(document.getElementById('certbox')).display }));
    ok(cb.label === 'Course certificate' && cb.box === 'none',
       'on a reflection the evidence box asks for the course certificate, and no choice shows until one is chosen');
    await page.setInputFiles('#file', { name: 'certificate.pdf', mimeType: 'application/pdf',
                                        buffer: Buffer.from('%PDF-1.4 test') });
    await page.waitForTimeout(150);
    cb = await page.evaluate(() => ({ box: getComputedStyle(document.getElementById('certbox')).display,
      opts: [...document.querySelectorAll('#certtype option')].map(o => o.value + ':' + o.textContent),
      note: document.getElementById('certnote').textContent }));
    ok(cb.box !== 'none' && cb.opts.length === 2 && /^t3:External training.*1 point non core/.test(cb.opts[0])
       && /^t6:Formal asbestos qualification.*2 points non core/.test(cb.opts[1]),
       'with a certificate attached it asks what it is for, external course or qualification: ' + cb.opts.join(' | '));
    ok(/ARCA course, leave the certificate off/.test(cb.note), 'and says an ARCA course arrives on its own');
    await page.fill('#refl', Array.from({ length: 500 }, (_, i) => 'learned' + i).join(' '));
    await page.fill('#title', 'TEST face fit course');
    await page.selectOption('#certtype', 't6');
    await page.evaluate(() => { window.__calls = []; document.getElementById('send').click(); });
    await page.waitForTimeout(600);
    const pair = await page.evaluate(() => ({
      call: window.__calls.find(c => c.rpc === 'log_reflection_with_certificate'),
      single: window.__calls.filter(c => c.rpc === 'log_cpd').length,
      seen: window.__calls.find(c => c.rpc === 'cpd_evidence_seen'),
      msg: document.getElementById('fmsg').textContent }));
    ok(pair.call && pair.call.args.p_reflection_type === 't4' && pair.call.args.p_certificate_type === 't6'
       && (pair.call.args.p_reflection || '').length > 2000 && pair.single === 0,
       'it sends both as one, the reflection and the chosen course type: '
       + JSON.stringify(pair.call ? pair.call.args.p_certificate_type : null));
    const up = page.__evidence[0];
    const sent = up ? up.body.toString('latin1') : '';
    ok(up && up.auth === 'Bearer tok' && /name="entry"\r\n\r\nc1\r\n/.test(sent) && /%PDF-1\.4 test/.test(sent),
       'and the certificate goes to the Worker, on the course entry, which is the one it proves');
    ok(pair.seen && /^[0-9a-f]{64}$/.test(pair.seen.args.p_sha256),
       'the form asks first whether the file has been used, by its fingerprint');
    ok(/two entries/.test(pair.msg), 'and the member is told it went as two: ' + pair.msg);

    // 0045: a certificate already used is stopped before anything is logged.
    await page.waitForTimeout(1500);
    await page.evaluate(() => document.getElementById('logbtn') && document.getElementById('logbtn').click());
    await page.waitForSelector('#type');
    await page.selectOption('#type', 't3');
    await page.fill('#title', 'TEST reused certificate');
    await page.setInputFiles('#file', { name: 'certificate.pdf', mimeType: 'application/pdf',
                                        buffer: Buffer.from('%PDF-1.4 test') });
    await page.evaluate(() => { window.__seen = true; window.__calls = []; document.getElementById('send').click(); });
    await page.waitForTimeout(600);
    const reused = await page.evaluate(() => ({ logged: window.__calls.filter(c => /^log_/.test(c.rpc || '')).length,
                                                msg: document.getElementById('fmsg').textContent }));
    ok(reused.logged === 0 && /already been used for CPD/.test(reused.msg),
       'a certificate already used is refused before anything is logged: ' + reused.msg);
    ok(errors.length === 0, 'and the form threw nothing: ' + (errors[0] || ''));
    await page.close();
  }

  // ---- earning CPD on the site (0041) -------------------------------------------
  console.log('\nearn CPD');
  {
    let g = await visit('/learn');
    ok(g.errors.length === 0 && g.csp.length === 0, '/learn draws with no error under the policy: ' + (g.errors[0] || g.csp[0] || ''));
    ok(g.text.includes('TEST Technical Review') && g.text.includes('TEST seminar recording'), 'it lists what is still to do');
    ok(/Done[\s\S]*TEST already passed/.test(g.text), 'and puts what is passed under Done');
    ok(g.xss === 0 && g.imgs === 0, 'and the titles and summaries are words');
    g = await visit('/learn', false);
    ok(/^\/login/.test(g.url), '/learn signed out goes to sign in');

    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    await page.addInitScript(STUB(true, DATA));
    // Randomness pinned to zero on THIS page, so the shuffle always swaps the
    // two questions. Left to chance, a version that forgot to put the answers
    // back in stored order would pass half the time.
    await page.addInitScript(() => { crypto.getRandomValues = a => a.fill(0); });
    await page.goto(base + '/learn?i=test-review', { waitUntil: 'load' });
    await page.waitForTimeout(800);
    let st = await page.evaluate(() => ({
      title: document.getElementById('ltitle').textContent,
      body: document.getElementById('material').innerHTML,
      legends: [...document.querySelectorAll('#qform legend')].map(l => l.textContent),
      radios: document.querySelectorAll('#qform input[type=radio]').length,
      xss: window.__xss || 0, imgs: document.querySelectorAll('#qform img, h2 img').length }));
    ok(/Plain words survive about the regulations/.test(st.body) && !/<script/.test(st.body),
       'the reading is shown, sanitised');
    ok(st.legends.length === 2 && st.radios === 5, 'with two questions and their five answers');
    ok(st.xss === 0 && st.imgs === 0 && st.legends.some(l => l.includes('<img')), 'questions and answers are words, never markup');
    await page.evaluate(() => { window.__calls = []; document.getElementById('qsend').click(); });
    await page.waitForTimeout(200);
    st = await page.evaluate(() => ({ msg: document.getElementById('qmsg').textContent,
                                      n: window.__calls.filter(c => c.rpc === 'submit_learning').length }));
    ok(st.n === 0 && /answer question 1/.test(st.msg), 'an unanswered question is asked for, nothing sent: ' + st.msg);
    // The questions and their answers are shuffled every time, so answers are
    // chosen by what they SAY, never by position.
    const choose = (qText, aText) => page.evaluate(([qText, aText]) => {
      const fs = [...document.querySelectorAll('#qform fieldset')]
        .find(f => f.querySelector('legend').textContent.includes(qText));
      const lab = [...fs.querySelectorAll('label')].find(l => l.textContent.trim().startsWith(aText));
      lab.querySelector('input').checked = true;
    }, [qText, aText]);
    await choose('Which is right?', 'Option B');
    await choose('Second?', 'Yes');
    await page.evaluate(() => { window.__calls = []; document.getElementById('qsend').click(); });
    await page.waitForTimeout(400);
    st = await page.evaluate(() => ({ msg: document.getElementById('qmsg') && document.getElementById('qmsg').textContent,
      call: window.__calls.find(c => c.rpc === 'submit_learning') }));
    ok(st.call && JSON.stringify(st.call.args) === JSON.stringify({ p_item: 'L1', p_answers: [1, 0] }),
       'the answers go to the database as choices, to be marked there: ' + JSON.stringify(st.call && st.call.args));
    ok(/50%[\s\S]*try once more/.test(st.msg || ''), 'a fail says the score and offers the retake: ' + st.msg);
    await choose('Which is right?', 'Option A');
    await choose('Second?', 'Yes');
    await page.evaluate(() => document.getElementById('qsend').click());
    await page.waitForTimeout(400);
    const pass = await page.evaluate(() => document.getElementById('quiz').textContent);
    ok(/100%[\s\S]*1\.5 points core have gone onto your record/.test(pass), 'a pass says the points went on the record: ' + pass.trim());
    ok(errors.length === 0, 'and nothing threw: ' + (errors[0] || ''));

    // A new order each time the questions open, on a page with real randomness.
    const page2 = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await page2.addInitScript(STUB(true, DATA));
    const orders = new Set(), qorders = new Set();
    for (let n = 0; n < 12; n++) {
      await page2.goto(base + '/learn?i=test-review', { waitUntil: 'load' });
      await page2.waitForTimeout(250);
      const o = await page2.evaluate(() => {
        const fs = [...document.querySelectorAll('#qform fieldset')];
        const second = fs.find(f => f.querySelector('legend').textContent.includes('Second?'));
        return { q: fs.map(f => f.querySelector('legend').textContent.replace(/^\d+\. /, '').slice(0, 6)).join('|'),
                 a: [...second.querySelectorAll('label')].map(l => l.textContent.trim()).join('|'),
                 nums: fs.map(f => f.querySelector('legend').textContent.split('.')[0]).join(',') };
      });
      orders.add(o.a); qorders.add(o.q);
      if (o.nums !== '1,2') { ok(false, 'questions are numbered in the order shown: ' + o.nums); break; }
    }
    ok(orders.size > 1, `the answers come in a new order each time: ${orders.size} different orders in 12 openings`);
    ok(qorders.size > 1, `and so do the questions: ${qorders.size} different orders in 12 openings`);
    await page2.close();

    await page.goto(base + '/learn?i=test-seminar', { waitUntil: 'load' });
    await page.waitForTimeout(800);
    st = await page.evaluate(() => ({ gate: (document.getElementById('gate') || {}).textContent || '',
      q: document.querySelectorAll('#qform').length,
      src: (document.getElementById('vid') || {}).src || '' }));
    ok(/open once you have watched\s+80%/.test(st.gate) && st.q === 0, 'a recording keeps its questions closed until it has been watched');
    ok(/^https:\/\/player\.vimeo\.com\/video\/123456789\?dnt=1/.test(st.src), 'and plays from Vimeo without tracking: ' + st.src);
    await page.goto(base + '/learn?i=test-done', { waitUntil: 'load' });
    await page.waitForTimeout(700);
    const dn = await page.evaluate(() => document.getElementById('quiz').textContent);
    ok(/already passed|passed this one/.test(dn), 'a passed item says so and offers no questions');
    await page.close();
  }

  // ---- the public record -------------------------------------------------------
  console.log('\nthe public record');
  let g = await visit('/m/jane-tester', false);
  ok(g.text.includes('Jane') && g.text.includes('TEST-0042'), 'a current member\'s record shows their name and number');
  ok(g.xss === 0 && g.imgs === 0, 'and their employer, a free text field, is words');
  ok(g.errors.length === 0 && g.csp.length === 0, 'with no error and no policy violation');
  g = await visit('/m/old-member', false);
  ok(/not a current member/i.test(g.text), 'a membership that has ended says "not a current member"');
  g = await visit('/m/nobody-holds-this', false);
  ok(/cannot be confirmed/i.test(g.text), 'a slug nobody holds says it cannot be confirmed, not a blank page');
  ok(!/not a current member/i.test(g.text), 'which is a different answer from a membership that has ended');

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
