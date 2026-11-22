/* The image library, the picture chooser, the home page headline and the
   communication log (0046), in the admin app, in a browser, under the app's
   real Content-Security-Policy.

   Only window.supabase is replaced.

   Run:  node tests/36_library_and_log_admin_browser.js [path-to-admin]
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
  admin_media_library: [
    { id:'b1', path:'/assets/photo-team.webp', name:'The team', alt_text:'A team', builtin:true, archived:false, fallback:true,
      uses:['Page: about, banner'], created_at:'2026-10-01T00:00:00Z' },
    { id:'u1', path:'library/2026/hall-abc123.webp', name:'AGM hall', alt_text:null, builtin:false, archived:false,
      fallback:false, width:2000, height:1300, byte_size:300000, uses:[], created_at:'2026-10-30T00:00:00Z' },
    { id:'u2', path:'library/2026/old-def456.webp', name:'Old one', builtin:false, archived:true, fallback:false, uses:[],
      created_at:'2026-09-30T00:00:00Z' } ],
  news_articles: [{ id:'n1', slug:'zz-news', title:'ZZ news item', status:'published', published_at:'2026-10-30T00:00:00Z',
    image_path:null, summary:'s', body:'<p>b</p>', category:null }],
  hero_statements: [{ id:'h1', statement:'Recognised best practice', image_path:'/assets/photo-team.webp',
    badge:'Assessed on evidence', sort_order:1, active:true }],
  admin_communication_log: [
    { id:'e1', template_code:'direct:contact_ack', route:'Sent by the site as a form was handled', to_email:'eve@test.invalid',
      to_name:'Eve', subject:'AMI has your message', status:'sent', at:'2026-10-31T09:00:00Z', membership_number:null },
    { id:'e2', template_code:'cpd_rejected', route:'Queued by the database', to_email:'jo@test.invalid', to_name:'Jo Bloggs',
      subject:'Your CPD entries have not been accepted', status:'failed', last_error:'SMTP2GO answered 500',
      at:'2026-10-30T09:00:00Z', membership_number:'AMI-0001' } ],
  email_outbox: [{ id:'e1', html:'<p>Thank you, <b>Eve</b>.</p><img src=x onerror="window.__xss=1"><script>window.__xss=2</script>',
    reply_to:'info@ami.uk.com' }],
  non_working_days: [{ id:'d1', day:'2027-01-01', name:"New Year Day" }, { id:'d2', day:'2027-05-03', name:'Early May bank holiday' }],
  admin_member_list: [{ id:'m1', given_name:'Jo', family_name:'Bloggs', email:'jo@test.invalid', membership_number:'AMI-0001',
    grade:'Member', status:'current', is_active:true, has_account:true, joined_on:'2020-01-01' }],
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
           roles:['super_user','administrator','editor','membership'] }]);
    if (fn === 'cpd_monthly_preview') { window.__w.push(['rpc', fn, args]);
      return res({ subject:'Your CPD for 2027: where you stand in March', to:'jo@test.invalid', next:'2026-11-02',
        html:'<p>Dear Jo,</p><p><b>2 of 5</b> core</p><img src=x onerror="window.__xss=3"><p>Last month you missed</p>' }); }
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

  // ---- The library screen --------------------------------------------------
  await nav('Media library');
  await page.waitForTimeout(400);
  const lib = await page.evaluate(() => [...document.querySelectorAll('.libcard')].map(c => c.textContent.replace(/\s+/g, ' ')));
  ok(lib.length === 2, 'the library lists what is available, archived ones apart: ' + lib.length);
  ok(/Built into the site/.test(lib[0]) && /Used on: Page: about, banner/.test(lib[0]) && !/Delete/.test(lib[0]),
     'a built in picture in use says where, and offers no Delete');
  ok(/Not used anywhere/.test(lib[1]) && /Delete/.test(lib[1]), 'an unused upload can be deleted');
  await page.evaluate(() => {
    const c = document.querySelectorAll('.libcard')[1];
    c.querySelector('[data-lname]').value = 'AGM hall, Burton';
    c.querySelector('[data-lalt]').value = 'Members seated in a conference hall';
    c.querySelector('[data-lfall]').checked = true;
    c.querySelector('[data-lsave]').click();
  });
  await page.waitForTimeout(300);
  ok(/Saved\./.test(await page.evaluate(() => (document.querySelectorAll('.libcard')[1].querySelector('[data-lsaid]') || {}).textContent || '')),
     'Save says Saved beside the button, where the person is looking');
  ok((await w()).some(x => x[0] === 'media_library' && x[1] === 'update' && x[2].name === 'AGM hall, Burton'
       && x[2].alt_text === 'Members seated in a conference hall' && x[2].fallback === true),
     'renaming, describing and marking as a default are saved');
  await page.evaluate(() => document.querySelectorAll('.libcard')[1].querySelector('[data-ldel]').click());
  await page.waitForTimeout(300);
  const wr = await w();
  ok(wr.some(x => x[0] === 'media_library' && x[1] === 'delete')
     && wr.some(x => x[0] === 'storage' && x[2][0] === 'library/2026/hall-abc123.webp'),
     'deleting removes the record and then the file');
  await page.evaluate(() => document.querySelector('[data-ltab="archived"]').click());
  await page.waitForTimeout(300);
  ok((await page.evaluate(() => [...document.querySelectorAll('[data-lname]')].map(i => i.value))).join() === 'Old one'
     && /Bring back/.test(await page.evaluate(() => document.getElementById('grid').textContent)),
     'archived pictures are kept apart, and can be brought back');

  // ---- A news item's picture, from the library -------------------------------
  await nav('News');
  await page.waitForTimeout(400);
  await page.evaluate(() => document.querySelector('[data-edit-rec]').click());
  await page.waitForTimeout(300);
  ok(!(await page.evaluate(() => !!document.querySelector('#dBody input[type=file]#e_image_path'))),
     'a news picture is no longer a file box of its own');
  // REAL clicks from here: page.click fails if anything lies over the target,
  // which is how the chooser opening UNDER the drawer's backdrop was missed.
  await page.click('[data-pickimg="image_path"]');
  await page.waitForTimeout(300);
  ok((await page.evaluate(() => document.querySelectorAll('#lpGrid [data-libpath]').length)) === 2,
     'it opens the library, without the archived picture');
  let clicked = true;
  try { await page.click('#lpGrid [data-libpath="library/2026/hall-abc123.webp"]', { timeout: 3000 }); }
  catch { clicked = false; }
  ok(clicked, 'and a picture in it can actually be clicked: nothing lies over the chooser');
  await page.waitForTimeout(300);
  ok(/AGM hall/.test(await page.evaluate(() => document.getElementById('name_image_path').textContent)),
     'and the chosen picture is shown on the item by name');
  await page.evaluate(() => document.getElementById('drawer').classList.remove('on'));

  // ---- The home page headline -----------------------------------------------
  await nav('Home page headline');
  await page.waitForTimeout(400);
  await page.evaluate(() => document.querySelector('[data-edit-rec]').click());
  await page.waitForTimeout(300);
  const hero = await page.evaluate(() => ({ pick: !!document.querySelector('[data-pickimg="image_path"]'),
    badge: (document.getElementById('e_badge') || {}).value, name: document.getElementById('name_image_path').textContent }));
  ok(hero.pick && hero.badge === 'Assessed on evidence' && hero.name === 'The team',
     'each headline has its own photograph, from the library, and its label');
  await page.evaluate(() => document.getElementById('drawer').classList.remove('on'));

  // ---- The communication log --------------------------------------------------
  await nav('Communication log');
  await page.waitForTimeout(400);
  const log = await page.evaluate(() => [...document.querySelectorAll('.q')].map(q => q.textContent.replace(/\s+/g, ' ')));
  ok(log.length === 2 && /AMI has your message/.test(log[0]) && /Sent by the site/.test(log[0]),
     'the log lists every email, including the ones the site sends itself');
  ok(/Last attempt: SMTP2GO answered 500/.test(log[1]), 'a failure says why');
  await page.evaluate(() => [...document.querySelectorAll('.q')][0].querySelector('[data-act$="|Read it"]').click());
  await page.waitForTimeout(400);
  const body = await page.evaluate(() => ({ text: document.getElementById('mBody').textContent,
    b: document.querySelectorAll('#mBody b').length, img: document.querySelectorAll('#mBody img').length,
    script: document.querySelectorAll('#mBody script').length, xss: window.__xss }));
  ok(/Thank you, Eve\./.test(body.text) && body.b === 1 && /info@ami\.uk\.com/.test(body.text),
     'opening one shows what was sent, and where replies went');
  ok(!body.xss && body.img === 0 && body.script === 0, 'and anything hostile in a logged email stays dead');
  await page.evaluate(() => document.getElementById('modal').classList.remove('on'));

  await nav('Members');
  await page.waitForTimeout(400);
  await page.evaluate(() => [...document.querySelectorAll('.q')][0].querySelector('[data-act$="|Emails"]').click());
  await page.waitForTimeout(500);
  const f = await page.evaluate(() => ({ title: document.getElementById('scrTitle').textContent,
    search: (document.getElementById('qSearch') || {}).value, n: document.querySelectorAll('.q').length }));
  ok(f.title === 'Communication log' && f.search === 'AMI-0001' && f.n === 1,
     'Emails on a member opens the log showing only theirs');

  // ---- The monthly CPD email (0047) --------------------------------------------
  await nav('Members');
  await page.waitForTimeout(400);
  await page.click('[data-act$="|Monthly CPD email"]');
  await page.waitForTimeout(400);
  const pv = await page.evaluate(() => ({ sub: document.getElementById('mSub').textContent,
    body: document.getElementById('mBody').textContent, img: document.querySelectorAll('#mBody img').length, xss: window.__xss,
    call: window.__w.find(x => x[1] === 'cpd_monthly_preview') }));
  ok(pv.call && pv.call[2].p_member === 'm1' && /Your CPD for 2027/.test(pv.body) && /2 of 5/.test(pv.body),
     'Monthly CPD email on a member previews theirs, as it would be today');
  ok(/02 Nov 2026/.test(pv.sub) && /first working day/.test(pv.sub), 'and says when it goes on its own: ' + pv.sub);
  ok(pv.img === 0 && !pv.xss, 'shown through the sanitiser');
  await page.evaluate(() => document.getElementById('modal').classList.remove('on'));
  await nav('Bank holidays');
  await page.waitForTimeout(400);
  const bh = await page.evaluate(() => [...document.querySelectorAll('.rec h3')].map(h => h.textContent));
  ok(bh.length === 2 && /01 Jan 2027: New Year/.test(bh[0]), 'the bank holidays the email skips are listed: ' + bh.join(' | '));

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'no policy violation anywhere: ' + (v[0] || ''));
  ok(errors.length === 0, 'and no errors: ' + (errors[0] || ''));
  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
