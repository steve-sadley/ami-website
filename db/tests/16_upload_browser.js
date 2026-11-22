/* Does a picture chosen in the admin app reach the bucket converted?

   Until admin 17 the upload sent whatever file it was given, raw, with the
   type the browser claimed. This drives the real record editor in a real
   browser, chooses each of the awkward pictures in tests/fixtures, and
   inspects the bytes that WOULD have gone to storage: their format by their
   first bytes, their size in pixels by decoding them, and whether any of the
   original's metadata survived.

   The Supabase client is the only stand in. Its storage.upload captures the
   body and answers success.

   Run:  node tests/16_upload_browser.js [path-to-admin]
   The pictures are made by tests/fixtures/make-upload-fixtures.py.
*/
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = process.argv[2] || path.resolve(__dirname, '../../admin');
const FX = path.join(__dirname, 'fixtures');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

const STUB = `
window.__uploads = [];
const res = (data, error) => Promise.resolve({ data, error: error || null });
function table(){
  const q = { select(){ return q; }, eq(){ return q; }, order(){ return q; }, limit(){ return q; }, range(){ return q; },
              in(){ return q; }, then(r){ return res([]).then(r); },
              upsert(p){ return res(p); }, insert(p){ return res(p); }, update(){ return q; },
              delete(){ return q; } };
  return q;
}
window.__stubClient = {
  from: table,
  rpc: fn => fn === 'whoami'
    ? res([{ person_id:'p1', given_name:'Test', family_name:'Editor',
             roles:['super_user','administrator','editor'] }])
    : res(null),
  auth: {
    getSession: () => res({ session: { user: { id:'u1', email:'editor@test.invalid' } } }),
    getUser: () => res({ user: { id:'u1', email:'editor@test.invalid' } }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
    signOut: () => res(null),
  },
  storage: { from: bucket => ({
    upload: async (p, body, opts) => {
      const bytes = new Uint8Array(await body.arrayBuffer());
      window.__uploads.push({ bucket, path: p, opts, size: bytes.length,
                              type: body.type, bytes: Array.from(bytes) });
      return res({ path: p });
    },
    getPublicUrl: p => ({ data: { publicUrl: 'data:,' } }),
  }) },
};
`;

(async () => {
  const srv = await new Promise(r => {
    const s = http.createServer((req, res) => {
      const p = req.url.split('?')[0] === '/' ? '/index.html' : req.url.split('?')[0];
      const f = path.join(ROOT, p);
      if (!f.startsWith(ROOT) || !fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': p.endsWith('.html') ? 'text/html' : 'text/javascript' });
      res.end(fs.readFileSync(f));
    });
    s.listen(0, () => r(s));
  });
  const browser = await chromium.launch();

  async function session(extraInit){
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    // The editor fetches the picture back from the bucket before claiming it is
    // there. There is no bucket here, so any such fetch gets a one pixel PNG.
    const PX = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64');
    await page.route('**/storage/v1/object/public/**', r => r.fulfill({ body: PX, contentType: 'image/png' }));
    await page.addInitScript(STUB + (extraInit || '') + `
      Object.defineProperty(window, 'supabase', { configurable: true,
        value: { createClient: () => window.__stubClient } });`);
    await page.goto('http://127.0.0.1:' + srv.address().port + '/index.html');
    await page.waitForTimeout(800);
    // News, then New: the record editor with its picture field.
    await page.evaluate(() =>
      [...document.querySelectorAll('#nav button')].find(b => b.textContent === 'News').click());
    await page.waitForTimeout(300);
    await page.evaluate(() => document.getElementById('addRow').click());
    await page.waitForTimeout(300);
    page.__errors = errors;
    return page;
  }

  // Since 0046 a picture is uploaded through the image library's chooser,
  // which runs the same converter. The report is said in the chooser on a
  // refusal and in the editor once the picture is chosen.
  async function choose(page, file){
    await page.evaluate(() => { window.__uploads = []; document.getElementById('libpick').classList.remove('on'); });
    await page.evaluate(() => document.querySelector('[data-pickimg="image_path"]').click());
    await page.waitForTimeout(300);
    await page.setInputFiles('#lpFile', path.join(FX, file));
    for (let n = 0; n < 60; n++) {
      await page.waitForTimeout(150);
      const done = await page.evaluate(() => !/Converting/.test(document.getElementById('lpMsg').textContent));
      if (done) break;
    }
    await page.waitForTimeout(200);
    return page.evaluate(async () => {
      const u = window.__uploads[0];
      const out = { msg: document.getElementById('lpMsg').textContent,
                    name: (document.getElementById('name_image_path') || {}).textContent,
                    count: window.__uploads.length };
      if (!u) return out;
      const b = new Uint8Array(u.bytes);
      const s = (i, t) => [...t].every((c, n) => b[i + n] === c.charCodeAt(0));
      out.format = b[0] === 0xFF && b[1] === 0xD8 ? 'jpeg'
                 : s(0, 'RIFF') && s(8, 'WEBP') ? 'webp'
                 : b[0] === 0x89 && s(1, 'PNG') ? 'png' : 'other';
      const bmp = await createImageBitmap(new Blob([b]));
      out.w = bmp.width; out.h = bmp.height;
      const text = String.fromCharCode(...b.slice(0, Math.min(b.length, 200000)));
      out.exif = /Exif|GPS|TestCam/.test(text);
      out.path = u.path; out.bucket = u.bucket; out.type = u.type;
      out.ctype = u.opts && u.opts.contentType; out.size = u.size;
      return out;
    });
  }

  // ---- In Chrome, which encodes WebP ---------------------------------------
  let page = await session();
  ok(page.__errors.length === 0, 'the editor opens with no errors: ' + (page.__errors[0] || ''));

  console.log('\na phone photograph, sideways, with a location in it');
  let r = await choose(page, 'phone.jpg');
  ok(r.count === 1, 'one upload, got ' + r.count + ' ' + r.msg);
  ok(r.format === 'webp', 'stored as WebP by its bytes, got ' + r.format);
  ok(r.ctype === 'image/webp' && /\.webp$/.test(r.path || ''),
     'with the type and the name that say so: ' + r.ctype + ' ' + r.path);
  ok(r.w === 1500 && r.h === 2000,
     `the right way up and no side over 2000: ${r.w} by ${r.h}, from 4032 by 3024 stored sideways`);
  ok(r.exif === false, 'no camera, no location, no metadata at all');
  ok(r.size < 1.5 * 1024 * 1024, 'under the limit: ' + r.size);
  ok(r.bucket === 'public-media', 'into the public bucket');
  ok(/Converted from 3024 by 4032 JPEG/.test(r.msg) && /Location and camera details removed/.test(r.msg),
     'and the screen says what was done: ' + r.msg);

  console.log('\na transparent PNG');
  r = await choose(page, 'alpha.png');
  ok(r.format === 'webp' && r.w === 1600 && r.h === 900,
     `kept at its own size, as WebP: ${r.format} ${r.w} by ${r.h}`);

  console.log('\nsmaller than ideal, and too small');
  r = await choose(page, 'mid.jpg');
  ok(r.count === 1 && r.w === 1000, 'a 1000 pixel picture is accepted and not enlarged: ' + r.w);
  ok(/may look soft/.test(r.msg), 'and the screen says it is on the small side');
  r = await choose(page, 'small.jpg');
  ok(r.count === 0 && /640 pixels wide/.test(r.msg), 'a 640 pixel picture is refused, and says why: ' + r.msg);

  console.log('\nthings that are not pictures');
  r = await choose(page, 'fake.jpg');
  ok(r.count === 0 && /not a picture this can use/.test(r.msg), 'a text file called .jpg is refused: ' + r.msg);
  r = await choose(page, 'drawing.svg');
  ok(r.count === 0 && /SVG files are not accepted/.test(r.msg), 'an SVG is refused: ' + r.msg);
  r = await choose(page, 'photo.heic');
  ok(r.count === 0 && /iPhone HEIC/.test(r.msg), 'a HEIC gets its own message: ' + r.msg);
  ok(page.__errors.length === 0, 'and nothing threw: ' + (page.__errors[0] || ''));
  await page.close();

  // ---- As Safari: asked for WebP, hands back a PNG --------------------------
  // Safari's canvas does not encode WebP and returns a PNG with no complaint.
  // Simulated by making toBlob ignore a WebP request, which is what it does.
  console.log('\nas Safari, which cannot encode WebP');
  page = await session(`
    const realToBlob = HTMLCanvasElement.prototype.toBlob;
    HTMLCanvasElement.prototype.toBlob = function(cb, type, q){
      return realToBlob.call(this, cb, type === 'image/webp' ? 'image/png' : type, q);
    };`);
  r = await choose(page, 'alpha.png');
  ok(r.format === 'jpeg', 'the PNG it handed back is noticed and the picture is stored as JPEG, got ' + r.format);
  ok(r.ctype === 'image/jpeg' && /\.jpg$/.test(r.path || ''), 'named and typed as JPEG: ' + r.ctype + ' ' + r.path);
  const corner = await page.evaluate(async () => {
    const b = new Uint8Array(window.__uploads[0].bytes);
    const bmp = await createImageBitmap(new Blob([b]));
    const c = new OffscreenCanvas(bmp.width, bmp.height); const x = c.getContext('2d');
    x.drawImage(bmp, 0, 0); return Array.from(x.getImageData(bmp.width - 5, 5, 1, 1).data);
  });
  ok(corner[0] > 240 && corner[1] > 240 && corner[2] > 240,
     'and the transparent half is laid on white, not black: ' + corner.join(','));
  await page.close();

  // ---- Documents are not pictures and go as they are ------------------------
  // Guidance documents use the same upload with t:'file'. A PDF must not be put
  // through a picture converter.
  const adminSrc = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
  ok(/case 'image':[\s\S]{0,900}data-pickimg/.test(adminSrc) && /const conv = await prepareImage\(file\);[\s\S]{0,300}'library'/.test(adminSrc)
     && /case 'file':[\s\S]{0,600}type="file"/.test(adminSrc),
     'a picture field goes through the library, which converts; a document field uploads as it is');

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
