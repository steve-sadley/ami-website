/* The admin app's AI review controls (0043), in a browser, under the app's
   real Content-Security-Policy.

   What this proves: a pending reflection shows Claude's recommendation and
   says plainly that it is only a recommendation; Ask Claude goes to the SITE
   with the staff member's own sign in, presses again until nothing is left,
   and reports; Accept the ones Claude recommends goes through review_cpd,
   the same call a person makes ticking them, and through nothing else; the
   reject dialog starts from Claude's suggested note; text from a reflection
   or from Claude arrives as words; and the guide screen opens.

   Only window.supabase is replaced, and the site's endpoint is answered.

   Run:  node tests/30_ai_review_admin_browser.js [path-to-admin]
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
const base = { year:2027, occurred_on:'2027-02-01', provider:null, points:2, is_core:false, evidence_ref:null,
  recorded_at:'2027-02-02T10:00:00Z', activity_type:'Reflection following a training course', membership_number:'AMI-0001',
  reflection_words:520, min_words:500, needs_evidence:false, evidence_count:0, ai_assisted:false };
const ROWS = {
  admin_cpd_queue: [
    Object.assign({}, base, { id:'e1', title:'Refresher', given_name:'Ann', family_name:'Able', status:'pending',
      reflection:'I learned a great deal.', ai_recommendation:'accept', ai_reason:'All four points are met.',
      ai_member_note:null, ai_model:'claude-sonnet-5-5', ai_guide_version:1, ai_reviewed_at:'2027-02-03T10:00:00Z' }),
    Object.assign({}, base, { id:'e2', title:'Supervisor course', given_name:'Bob', family_name:'Bee', status:'pending',
      reflection:'<img src=x onerror="window.__xss=1">', ai_recommendation:'query', ai_reason:'<b>Point 3</b> is missing.',
      ai_member_note:'Please add how the course changes the way you work.', ai_model:'claude-sonnet-5-5',
      ai_guide_version:1, ai_reviewed_at:'2027-02-03T10:00:00Z' }),
    Object.assign({}, base, { id:'e3', title:'Third course', given_name:'Cat', family_name:'Sea', status:'pending',
      reflection:'Words.', ai_recommendation:'accept', ai_reason:'Met.', ai_member_note:null,
      ai_model:'claude-sonnet-5-5', ai_guide_version:1, ai_reviewed_at:'2027-02-03T10:00:00Z' }),
    Object.assign({}, base, { id:'e4', title:'Not yet read', given_name:'Dan', family_name:'Dee', status:'pending',
      reflection:'Words.', ai_recommendation:null }),
    // 0045: a course entry whose certificate Claude has read, with everything to check.
    Object.assign({}, base, { id:'e6', title:'NVQ', given_name:'Fay', family_name:'Eff', status:'pending', reflection:null,
      reflection_words:0, min_words:0, activity_type:'Formal asbestos qualification', evidence_count:2,
      cert_readable:true, cert_is_certificate:true, cert_holder:'John Smith', cert_course:'NVQ Level 3',
      cert_issuer:'Awarding Body', cert_awarded_on:'2026-01-01', cert_number:'AB1234',
      cert_number_used_on:'Cerys Cert, 01 Mar 2027, accepted', cert_holder_matches:false, cert_date_gap_days:197,
      cert_concerns:'<script>window.__xss2=1</script>Looks edited.', cert_files_too_large:1,
      possible_repeat:'NVQ, 02 Jan 2027, pending' }),
    Object.assign({}, base, { id:'e5', title:'Done before', given_name:'Eve', family_name:'Ee', status:'accepted',
      reflection:'Words.', ai_recommendation:'accept', ai_reason:'Met.', ai_assisted:true }),
  ],
  admin_cpd_evidence: [{ id:'v1', cpd_entry_id:'e6', storage_path:'p/e6-a.pdf', original_name:'nvq.pdf',
    byte_size:120000, content_type:'application/pdf', uploaded_at:'2027-03-01T10:00:00Z', fingerprinted:true }],
  cpd_review_guides: [{ id:'g1', version:1, active:true, created_at:'2026-10-31T00:00:00Z',
    body:'Recommend ACCEPT when the reflection does all four of these.' }],
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
    if (fn === 'whoami') return res([{ person_id:'p1', given_name:'Olive', family_name:'Office', roles:['membership'] }]);
    window.__rpc.push([fn, args]);
    if (fn === 'review_cpd') return res(args.p_ids.length);
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

  let asked = [], answers = [];
  await page.route('https://staging.ami.uk.com/api/cpd/ai-review', async r => {
    asked.push({ headers: r.request().headers(), body: r.request().postData() });
    const a = answers.shift() || { status: 200, body: { done: 0, remaining: 0 } };
    await r.fulfill({ status: a.status, contentType: 'application/json', body: JSON.stringify(a.body) });
  });

  // The mail drain: one letter goes, then the queue is empty.
  let drains = 0, drainAnswers = [];
  await page.route('https://staging.ami.uk.com/api/mail/drain', async r => {
    drains++;
    const a = drainAnswers.shift() || { sent: 0, failed: 0 };
    await r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(a) });
  });

  await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
  await page.waitForTimeout(900);
  const nav = n => page.evaluate(n => [...document.querySelectorAll('#nav button')].find(b => b.textContent === n).click(), n);
  const msg = () => page.evaluate(() => document.getElementById('msg').textContent.trim());

  await nav('CPD to review');
  await page.waitForTimeout(400);
  const cards = await page.evaluate(() => [...document.querySelectorAll('.q')].map(q => q.textContent));
  ok(cards.length === 5, 'five pending entries: ' + cards.length);
  const c6 = cards[4];
  ok(/Certificate, as Claude read it:.*John Smith.*NVQ Level 3.*No\. AB1234/s.test(c6),
     'a certificate shows what Claude read on it');
  ok(/certificate number already used: Cerys Cert, 01 Mar 2027, accepted/.test(c6)
     && /in the name of John Smith, not Fay Eff/.test(c6) && /197 days from the entry/.test(c6),
     'with the reused number, the wrong name and the date gap all called out');
  ok(/too large for Claude to read/.test(c6) && /Possible repeat of NVQ, 02 Jan 2027/.test(c6),
     'a file too large for Claude, and a likely repeat, are said too');
  ok(!/Claude recommends/.test(c6), 'and there is no recommendation: on a certificate the office decides on the facts');
  ok(/Claude recommends accept\..*All four points are met\..*A recommendation only: you decide\./s.test(cards[0]),
     'a recommendation shows on its card, and says it is only a recommendation');
  ok(/Claude recommends a query\..*Suggested note to the member: Please add/s.test(cards[1]),
     'a query shows with its suggested note');
  ok(!/Claude recommends/.test(cards[3]), 'an entry Claude has not read says nothing about Claude');
  const safe = await page.evaluate(() => ({ xss: window.__xss || window.__xss2, b: document.querySelectorAll('.q .why b').length,
    imgs: document.querySelectorAll('.q img').length }));
  ok(!safe.xss && safe.imgs === 0 && cards[1].includes('<b>Point 3</b>') && cards[4].includes('<script>'),
     'text from a reflection or from Claude arrives as words, never markup');

  await page.evaluate(() => [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'CPD to review').click());
  await page.waitForTimeout(300);
  await page.evaluate(() => document.querySelector('.filters .pill:last-of-type') && null);
  // The Accepted tab shows the AI assisted mark.
  await page.evaluate(() => [...document.querySelectorAll('[data-tab]')].find(b => b.dataset.tab === 'accepted').click());
  await page.waitForTimeout(200);
  ok(/AI assisted/.test(await page.evaluate(() => document.querySelector('.q').textContent)),
     'a decided entry says it was AI assisted');
  await page.evaluate(() => [...document.querySelectorAll('[data-tab]')].find(b => b.dataset.tab === 'pending').click());
  await page.waitForTimeout(200);

  // Ask Claude: two rounds, then nothing left.
  answers = [{ status: 200, body: { done: 3, accept: 2, query: 1, certificates: 0, failed: 0, remaining: 2, more: true } },
             { status: 200, body: { done: 2, accept: 1, query: 1, certificates: 0, failed: 0, remaining: 0, more: true } },
             { status: 200, body: { done: 0, accept: 0, query: 0, certificates: 2, failed: 0, remaining: 0, more: false } }];
  await page.evaluate(() => document.getElementById('qAsk').click());
  await page.waitForTimeout(800);
  ok(asked.length === 3, 'Ask Claude asks again until nothing is left, reflections then certificates: ' + asked.length);
  ok(asked.every(a => a.headers.authorization === 'Bearer STAFF-TOKEN' && a.body === '{}'),
     'each time with the staff member\'s own sign in and nothing else: the database chooses what is read');
  ok(/Claude read 5 reflections: 3 to accept, 2 to query, and 2 certificates/.test(await msg()), 'and says what it found: ' + await msg());

  answers = [{ status: 422, body: { done: 0, failed: 3, error: 'The Claude key was not accepted. Check ANTHROPIC_API_KEY on the site.' } }];
  await page.evaluate(() => document.getElementById('qAsk').click());
  await page.waitForTimeout(600);
  ok(/ANTHROPIC_API_KEY/.test(await msg()), 'a refusal is said in words somebody can act on');

  answers = [{ status: 503, body: { error: 'Claude is not connected yet: ANTHROPIC_API_KEY needs setting on the site.', at: 'ai-bindings' } }];
  await page.evaluate(() => document.getElementById('qAsk').click());
  await page.waitForTimeout(600);
  ok(/not connected yet/.test(await msg()), 'and before the key is set it says Claude is not connected yet');

  // Accept the ones Claude recommends.
  const label = await page.evaluate(() => (document.getElementById('qAiAccept') || {}).textContent || '');
  ok(/Accept the 2 Claude recommends/.test(label), 'the button counts only pending entries Claude recommends: ' + label);
  const before = await page.evaluate(() => window.__rpc.length);
  await page.evaluate(() => document.getElementById('qAiAccept').click());
  await page.waitForTimeout(250);
  ok(/Ann Able: Refresher; Cat Sea: Third course/.test(await page.evaluate(() => document.getElementById('mSub').textContent)),
     'it names each one before anything happens');
  ok((await page.evaluate(() => window.__rpc.filter(c => c[0] === 'review_cpd').length)) === 0,
     'and nothing is accepted until a person confirms');
  drains = 0; drainAnswers = [{ sent: 2, failed: 0 }];
  await page.click('#mOk');
  await page.waitForTimeout(600);
  ok(drains >= 1 && /2 members have been emailed/.test(await msg()),
     'the decision letters are sent straight away, not left in the queue: ' + await msg());
  const rc = await page.evaluate(() => window.__rpc.filter(c => c[0] === 'review_cpd'));
  ok(rc.length === 1 && rc[0][1].p_status === 'accepted' && rc[0][1].p_ids.sort().join() === 'e1,e3',
     'confirming accepts exactly those two, through review_cpd, as a person');
  ok((await page.evaluate(b => window.__rpc.slice(b).map(c => c[0]), before)).every(f => f === 'review_cpd'),
     'and through no other call');

  // Reject starts from Claude's note.
  await page.evaluate(() => [...document.querySelectorAll('.q')][1].querySelector('[data-act$="|Reject"]').click());
  await page.waitForTimeout(250);
  ok((await page.evaluate(() => document.getElementById('m_note').value)) === 'Please add how the course changes the way you work.',
     'rejecting a queried entry starts from Claude\'s suggested note, for a person to change');
  drains = 0; drainAnswers = [{ sent: 1, failed: 0 }];
  await page.click('#mOk');
  await page.waitForTimeout(600);
  const rj = await page.evaluate(() => window.__rpc.filter(c => c[0] === 'review_cpd').pop());
  ok(rj && rj[1].p_status === 'rejected' && rj[1].p_note === 'Please add how the course changes the way you work.'
     && drains >= 1 && /Rejected, with the reason recorded\. The member has been emailed\./.test(await msg()),
     'a rejection goes with its reason, and the member is emailed at once: ' + await msg());

  // The evidence on a card opens from the private bucket.
  await page.evaluate(() => [...document.querySelectorAll('.q')][4].querySelector('[data-act$="|Evidence"]').click());
  await page.waitForTimeout(300);
  ok(/nvq\.pdf/.test(await page.evaluate(() => document.getElementById('mBody').textContent)),
     'Evidence on the card lists the files, to open');
  await page.evaluate(() => document.getElementById('modal').classList.remove('on'));

  // The guide screen.
  await nav('CPD review guide');
  await page.waitForTimeout(300);
  ok(/Version 1/.test(await page.evaluate(() => document.querySelector('.rec h3').textContent)), 'the guide screen lists the versions');
  await page.evaluate(() => document.querySelector('[data-edit-rec]').click());
  await page.waitForTimeout(250);
  ok(/Recommend ACCEPT/.test(await page.evaluate(() => document.getElementById('e_body').value)), 'and opens one to read');

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'with no policy violation anywhere: ' + (v[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
