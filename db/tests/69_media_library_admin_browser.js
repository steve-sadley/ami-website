/* The media library takes documents, and the picture chooser shows its
   pictures (0065, admin 48), in a browser under the admin app's real policy.

   The chooser fault: with the 33 pictures on staging every picture tile was
   squeezed to a sliver a few pixels high, because the chooser borrowed the
   430 pixel sign in box. This test uses 33.

   Run:  node tests/69_media_library_admin_browser.js [path-to-admin]
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
const pics = Array.from({ length: 33 }, (_, i) => ({ id:'p' + i, kind:'image',
  path: i < 5 ? '/assets/hero.webp' : 'library/2026/pic-' + i + '.webp', name:'Picture ' + i,
  builtin: i < 5, archived:false, fallback:false, width:2000, height:1300, uses:[], created_at:'2026-10-30T00:00:00Z' }));
const docs = [
  { id:'d1', kind:'document', path:'documents/2026/competency-abc123.pdf', name:'Competency guidance', mime_type:'application/pdf',
    original_name:'AMI competency.pdf', byte_size: 482000, builtin:false, archived:false, fallback:false,
    uses:['Guidance document: Competency within removal'], created_at:'2026-11-01T00:00:00Z' },
  { id:'d2', kind:'document', path:'documents/2026/old-sheet-def456.xlsx', name:'Old sheet', byte_size: 12000,
    builtin:false, archived:false, fallback:false, uses:[], created_at:'2026-11-02T00:00:00Z' } ];
const ROWS = {
  admin_media_library: pics.concat(docs),
  guidance_documents: [{ id:'g1', slug:'test-guide', title:'Competency within removal', status:'published',
    storage_path:'documents/2026/competency-abc123.pdf', members_only:false, published_at:'2026-11-01T00:00:00Z' }],
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
  rpc: (fn) => fn === 'whoami' ? res([{ person_id:'p1', given_name:'Olive', family_name:'Office',
           roles:['super_user','administrator','editor','membership'] }]) : res([]),
  auth: {
    getSession: () => res({ session: { access_token:'T', user: { id:'u1', email:'office@test.invalid' } } }),
    getUser: () => res({ user: { id:'u1', email:'office@test.invalid' } }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null),
  },
  storage: { from: (b) => ({
    upload: (p, f, o) => { window.__w.push(['storage','upload', b, p, o && o.contentType]); return res({ path: p }); },
    remove: (ps) => { window.__w.push(['storage','remove', b, ps]); return res(null); },
    createSignedUrl: (p) => { window.__w.push(['storage','sign', b, p]); return res({ signedUrl: 'about:blank' }); } }) },
  channel: () => ({ on(){ return this; }, subscribe(){ return this; } }),
  removeChannel: () => {},
};
window.open = () => null;
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

  const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'ami-doc-'));
  const realPdf = path.join(tmp, 'Annual report.pdf');
  fs.writeFileSync(realPdf, Buffer.concat([Buffer.from('%PDF-1.4\n'), Buffer.alloc(2000, 32)]));
  const fakePdf = path.join(tmp, 'not really.pdf');
  fs.writeFileSync(fakePdf, '<html><script>alert(1)</script></html>' + ' '.repeat(100));
  const program = path.join(tmp, 'setup.exe');
  fs.writeFileSync(program, Buffer.concat([Buffer.from('MZ'), Buffer.alloc(500)]));
  const sheet = path.join(tmp, 'Fees.xlsx');
  fs.writeFileSync(sheet, Buffer.concat([Buffer.from([0x50, 0x4B, 0x03, 0x04]), Buffer.alloc(800, 1)]));

  // ---- 1. The picture chooser shows its pictures -----------------------------
  await nav('Guidance');
  await page.waitForTimeout(400);
  await page.evaluate(() => document.querySelector('[data-edit-rec]').click());
  await page.waitForTimeout(300);
  await page.setViewportSize({ width: 1280, height: 760 });
  await page.click('[data-pickimg="image_path"]');
  await page.waitForTimeout(500);
  const pick = await page.evaluate(() => {
    const card = document.querySelector('#libpick .card').getBoundingClientRect();
    // The TILE, not the picture inside it: the tile clips, so a crushed tile
    // still holds a full size picture that nobody can see.
    const ths = [...document.querySelectorAll('#lpGrid .libitem')].map(t => t.getBoundingClientRect().height);
    return { width: card.width, n: ths.length, minH: Math.min(...ths), docs: document.querySelectorAll('#lpGrid .docth').length };
  });
  ok(pick.width > 700, 'the chooser is wide enough to see pictures in, not the 430 pixel sign in box: ' + Math.round(pick.width));
  ok(pick.n === 33 && pick.minH > 100, `all 33 pictures show at a size you can see, smallest ${Math.round(pick.minH)} pixels high`);
  ok(pick.docs === 0, 'and the picture chooser offers no documents');
  let clicked = true;
  try { await page.click('#lpGrid [data-libpath="library/2026/pic-30.webp"]', { timeout: 3000 }); } catch { clicked = false; }
  ok(clicked, 'a picture far down the list can be scrolled to and clicked');
  await page.setViewportSize({ width: 1400, height: 900 });

  // ---- 2. The document field chooses from the library ------------------------
  await page.waitForTimeout(200);
  ok(await page.$('[data-pickdoc="storage_path"]') && !(await page.$('#dBody input[type=file]#e_storage_path')),
     'a guidance document is chosen from the library, not a file box of its own');
  ok(/Competency guidance/.test(await page.evaluate(() => document.getElementById('name_storage_path').textContent)),
     'and the one already chosen is shown by its library name');
  await page.click('[data-pickdoc="storage_path"]');
  await page.waitForTimeout(400);
  const dp = await page.evaluate(() => ({ n: document.querySelectorAll('#lpGrid [data-libpath]').length,
    all: [...document.querySelectorAll('#lpGrid [data-libpath]')].every(b => b.dataset.libpath.startsWith('documents/')),
    label: document.getElementById('lpUpLabel').textContent, accept: document.getElementById('lpFile').accept }));
  ok(dp.n === 2 && dp.all, 'the document chooser offers the two documents and no pictures');
  ok(/document/.test(dp.label) && /\.pdf/.test(dp.accept) && !/image/.test(dp.accept), 'and its upload is for documents');
  await page.setInputFiles('#lpFile', fakePdf);
  await page.waitForTimeout(500);
  ok(/called \.pdf but is not one/.test(await page.evaluate(() => document.getElementById('lpMsg').textContent)),
     'a web page renamed .pdf is refused, by its bytes');
  ok(!(await w()).some(x => x[1] === 'upload'), 'and nothing reached storage');
  await page.setInputFiles('#lpFile', realPdf);
  await page.waitForTimeout(600);
  const up = (await w()).find(x => x[1] === 'upload');
  ok(up && up[2] === 'content-media' && /^documents\/\d{4}\/annual-report-[a-z0-9]{6}\.pdf$/.test(up[3]) && up[4] === 'application/pdf',
     'a real PDF goes to the private bucket under documents/: ' + (up ? up.slice(2).join(' ') : 'nothing'));
  const ins = (await w()).find(x => x[0] === 'media_library' && x[1] === 'insert');
  ok(ins && ins[2].kind === 'document' && ins[2].original_name === 'Annual report.pdf' && ins[2].name === 'Annual report',
     'and is entered in the library as a document, with its name');
  // The stub library does not grow, so the new file is shown by its own name.
  ok(/annual-report-[a-z0-9]{6}\.pdf/.test(await page.evaluate(() => document.getElementById('name_storage_path').textContent)),
     'and becomes the guidance document\'s file');
  await page.evaluate(() => document.getElementById('drawer').classList.remove('on'));

  // ---- 3. The media library screen -------------------------------------------
  await nav('Media library');
  await page.waitForTimeout(500);
  const tabs = await page.evaluate(() => [...document.querySelectorAll('[data-ltab]')].map(b => b.textContent.replace(/\s+/g, ' ').trim()));
  ok(tabs.join('|') === 'Pictures 33|Documents 2|Archived 0', 'three tabs, counted: ' + tabs.join(', '));
  await page.evaluate(() => document.querySelector('[data-ltab="documents"]').click());
  await page.waitForTimeout(400);
  const dl = await page.evaluate(() => [...document.querySelectorAll('[data-lib]')].map(c => ({
    t: c.querySelector('.docth') && c.querySelector('.docth').textContent, del: !!c.querySelector('[data-ldel]'),
    alt: !!c.querySelector('[data-lalt]'), txt: c.textContent.replace(/\s+/g, ' ') })));
  ok(dl.length === 2 && dl[0].t === 'PDF' && dl[1].t === 'XLSX', 'documents are listed with their type');
  ok(!dl[0].del && /Used on: Guidance document/.test(dl[0].txt) && dl[1].del, 'one in use cannot be deleted; an unused one can');
  ok(!dl[0].alt, 'a document has no picture description to fill in');
  await page.click('[data-lib="d1"] [data-lopen]');
  await page.waitForTimeout(200);
  ok((await w()).some(x => x[1] === 'sign' && x[2] === 'content-media' && x[3] === 'documents/2026/competency-abc123.pdf'),
     'Open signs a short link to the private file');
  await page.click('[data-lib="d2"] [data-ldel]');
  await page.waitForTimeout(400);
  ok((await w()).some(x => x[1] === 'remove' && x[2] === 'content-media' && x[3][0] === 'documents/2026/old-sheet-def456.xlsx'),
     'deleting a document removes it from the private bucket, not the picture one');
  await page.setInputFiles('#libFile', program);
  await page.waitForTimeout(400);
  ok(/not a document the library takes/.test(await msg()), 'a program is refused');
  await page.setInputFiles('#libFile', sheet);
  await page.waitForTimeout(500);
  ok((await w()).some(x => x[1] === 'upload' && x[2] === 'content-media' && /\.xlsx$/.test(x[3])), 'a spreadsheet is taken');

  const v = await page.evaluate(() => window.__csp);
  ok(v.length === 0, 'no policy violation: ' + (v[0] || ''));
  ok(errors.length === 0, 'no page errors: ' + (errors[0] || ''));
  fs.rmSync(tmp, { recursive: true, force: true });
  await browser.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
