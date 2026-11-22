/* The Worker, actually run. Rebuilt 30 October 2026 in place of worker.spec.js
   and pass.spec.js, which were in the member area test bundle that was lost.

   WHY THIS EXISTS. `node --check` parses a file and cannot find a name that is
   never defined. A comment block was once rewritten, three helpers inside it
   went with it, every suite passed, and the first sign was a member getting
   "keyMismatch is not defined" on the application form. So every route is
   called here with a stub environment and a stub network, and the assertion is
   that the code reached an answer rather than falling over.

   And the wallet pass, which iOS refuses in total silence if any part is wrong:
   a certificate chain is generated with openssl on the spot, a real pass is
   built by the Worker's own buildPkpass, and openssl is asked whether the
   signature verifies against that chain. What this proves is the DER, the CMS
   SignedData, the SHA-1 manifest, the zip and the layout. What it cannot prove
   is that an iPhone accepts it: the only certificate here is one made up a
   second ago. The phone did accept one on 23 August.

   Nothing mocked except the network, the ASSETS binding and the cache.

   Run:  node tests/20_worker.mjs [path-to-site]
*/
import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SITE = process.argv[2] || path.resolve(HERE, '../../site');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };
const section = t => console.log('\n' + t);

// The Worker is an ES module with a .js name and no package.json saying so.
// A copy with an .mjs name is imported instead, from a scratch folder.
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-worker-'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'worker.mjs'));

// ---- the stand ins -----------------------------------------------------------
const cacheStore = new Map();
globalThis.caches = { default: {
  match: async r => cacheStore.has(r.url) ? new Response(cacheStore.get(r.url)) : undefined,
  put: async (r, res) => { cacheStore.set(r.url, await res.text()); },
} };

let outbound = [];       // every fetch the Worker makes
let answer = () => new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  const body = init.body !== undefined ? init.body : (input.body ? await input.text() : undefined);
  outbound.push({ url, method: init.method || (input.method) || 'GET', headers: init.headers, body });
  return answer(url, init);
};

const ASSETS = { fetch: async req => {
  const u = new URL(req.url);
  let p = u.pathname === '/' ? '/index.html' : u.pathname;
  const f = path.join(SITE, p);
  if (!fs.existsSync(f) || fs.statSync(f).isDirectory())
    return new Response('not found', { status: 404 });
  return new Response(fs.readFileSync(f), { status: 200,
    headers: { 'Content-Type': p.endsWith('.html') ? 'text/html' : 'application/octet-stream',
               'X-Asked-For': u.pathname + u.search } });
} };

const W = await import(pathToFileURL(path.join(TMP, 'worker.mjs')).href);
const worker = W.default;
const call = (url, init = {}, env = {}) =>
  worker.fetch(new Request(url, init), Object.assign({ ASSETS }, env));
const STAGING = 'https://staging.ami.uk.com';
const LIVE = 'https://ami.uk.com';

// ---- 1. Routes answer, and with the right status -----------------------------
section('routes');
{
  let r = await call(STAGING + '/robots.txt');
  ok(/Disallow: \//.test(await r.text()), 'staging tells crawlers to go away');
  r = await call(LIVE + '/robots.txt');
  ok(/Allow: \//.test(await r.text()), 'live lets them in');

  r = await call(STAGING + '/.well-known/security.txt');
  const sec = await r.text();
  const exp = (sec.match(/^Expires: (\S+)$/m) || [])[1];
  ok(r.status === 200 && /^Contact: https:\/\/ami\.uk\.com\/contact\.html$/m.test(sec)
     && exp && new Date(exp) > new Date(Date.now() + 300 * 864e5) && new Date(exp) <= new Date(Date.now() + 366 * 864e5),
     'security.txt says who to tell, and expires within a year: ' + exp);

  for (const [p, allow] of [['/api/apply', 'POST'], ['/api/contact', 'POST'], ['/api/mail/drain', 'POST'],
                            ['/api/photo', 'POST, DELETE'], ['/api/pass/apple', 'POST']]) {
    r = await call(STAGING + p);
    ok(r.status === 405 && r.headers.get('Allow') === allow, `${p} by GET is 405 and says ${allow}`);
  }

  r = await call(STAGING + '/t/a-discussion');
  ok(r.status === 200 && /\/thread\.html\?t=a-discussion/.test(r.headers.get('X-Asked-For') || ''),
     '/t/<slug> is served by thread.html with the slug carried: ' + r.headers.get('X-Asked-For'));
  r = await call(STAGING + '/m/jane-smith');
  ok(r.status === 200 && /\/member\.html\?slug=jane-smith/.test(r.headers.get('X-Asked-For') || ''),
     '/m/<slug> is served by member.html');
  ok(/noindex/i.test(r.headers.get('X-Robots-Tag') || ''), 'and on staging it says noindex');
  r = await call(LIVE + '/m/jane-smith');
  ok(!/noindex/i.test(r.headers.get('X-Robots-Tag') || ''), 'and on live it does not');
  r = await call(STAGING + '/about');
  ok(r.status === 200 || r.status === 404, 'anything else goes to the static files');
}

// ---- 2. A route with no bindings says so, rather than reading as a bug -------
section('missing bindings');
{
  const post = (p, body) => call(STAGING + p, { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
  let r = await post('/api/contact', { name: 'A', email: 'a@test.invalid', message: 'Hello there office' });
  ok(r.status === 503, '/api/contact with no mail bindings is 503, got ' + r.status);
  r = await call(STAGING + '/api/apply', { method: 'POST', body: new FormData() });
  ok(r.status >= 400 && r.status < 600 && r.status !== 502 && r.status !== 504,
     '/api/apply with no bindings answers, and never with 502 or 504, which Cloudflare would eat: ' + r.status);
  r = await call(STAGING + '/api/pass/apple', { method: 'POST', headers: { Authorization: 'Bearer x' } });
  ok(r.status === 503, '/api/pass/apple with no certificate is 503: ' + r.status);
  r = await call(STAGING + '/api/pass/apple', { method: 'POST' });
  ok(r.status === 401, 'and with no sign in, 401: ' + r.status);

  r = await call(STAGING + '/api/pass/status');
  const st = await r.json();
  ok(st.apple === false && st.google === false, '/api/pass/status says neither wallet is ready when none is set');
  r = await call(STAGING + '/api/pass/status', {}, {
    SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SECRET: 'SECRET-VALUE-1', SUPABASE_ANON: 'ANON-2',
    SMTP2GO_KEY: 'SMTP-3', CONTACT_TO: 'a@test.invalid', CONTACT_FROM: 'b@test.invalid' });
  const txt = await r.text();
  ok(JSON.stringify(Object.keys(JSON.parse(txt)).sort()) === '["apple","google"]',
     'and says only that: no binding is named to strangers (security check, 31 October)');
  ok(!/SECRET|SMTP|ANON/.test(txt), 'and never a value or a binding name');
}

// ---- 3. The contact form ------------------------------------------------------
section('contact form');
{
  const env = { SMTP2GO_KEY: 'k', CONTACT_TO: 'office@test.invalid', CONTACT_FROM: 'no-reply@ami.uk.com',
                SITE_ORIGIN: STAGING };
  outbound = [];
  answer = () => new Response(JSON.stringify({ data: { succeeded: 1, failed: 0 } }),
                              { status: 200, headers: { 'Content-Type': 'application/json' } });
  const r = await call(STAGING + '/api/contact', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Eve\r\nBcc: victim@test.invalid <x>', email: 'eve@test.invalid',
      topic: 'other', message: 'Hello <script>alert(1)</script> office, please help.' }) }, env);
  const j = await r.json();
  ok(r.status === 200 && j.ok, 'an enquiry is accepted: ' + JSON.stringify(j));
  const mails = outbound.filter(o => /smtp2go/.test(o.url)).map(o => JSON.parse(o.body));
  ok(mails.length === 2, 'two messages, the enquiry and the acknowledgement, got ' + mails.length);
  const all = JSON.stringify(mails);
  ok(!/\\r|\\nBcc|Bcc: victim/.test(mails.map(m => m.subject + ' ' + JSON.stringify(m.custom_headers || '')).join(' ')),
     'a line break in a name does not reach a header');
  ok(!/<script>alert/.test(all) && /&lt;script&gt;/.test(all), 'the message is escaped in the email body');
  ok(mails.every(m => /ami\.uk\.com/.test(m.sender || '')), 'both are sent FROM AMI, never as the visitor');

  // The fourth from the same address inside the hour is turned away.
  for (let n = 0; n < 3; n++) await call(STAGING + '/api/contact', { method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Ray', email: 'ray@test.invalid', message: 'A message long enough.' }) }, env);
  const r4 = await call(STAGING + '/api/contact', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Ray', email: 'ray@test.invalid', message: 'A message long enough.' }) }, env);
  ok(r4.status === 429, 'the fourth enquiry in an hour from one address is 429, got ' + r4.status);
  const hp = await call(STAGING + '/api/contact', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Bot', email: 'bot@test.invalid', message: 'Buy things now please', website: 'x' }) }, env);
  ok(hp.status === 200, 'a honeypot submission is thanked and dropped');
}

// ---- 4. The public photograph ---------------------------------------------------
section('public photograph');
{
  const env = { SUPABASE_URL: 'https://ttjvwxxtoidiiejyqmbc.supabase.co',
                SUPABASE_SECRET: 'x.eyJyZWYiOiJ0dGp2d3h4dG9pZGlpZWp5cW1iYyJ9.x', SUPABASE_ANON: 'sb_publishable_x' };
  answer = () => new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
  const r = await call(STAGING + '/api/photo/p/nobody-at-all', {}, env);
  ok(r.status === 404, 'a slug nobody holds is 404, not an error: ' + r.status);
  answer = () => { throw new Error('network down'); };
  const r2 = await call(STAGING + '/api/photo/p/someone', {}, env);
  ok(r2.status !== 502 && r2.status !== 504 && r2.status >= 400, 'a network failure is not a 502 or 504: ' + r2.status);
}

// ---- 5. The wallet pass ---------------------------------------------------------
section('wallet pass');
{
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-pass-'));
  const sh = (...a) => execFileSync('openssl', a, { cwd: d, stdio: 'pipe' });
  sh('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2',
     '-subj', '/CN=Test WWDR');
  sh('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'raw.key', '-out', 'p.csr', '-subj', '/CN=Test pass');
  sh('x509', '-req', '-in', 'p.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'pass.pem', '-days', '2');
  sh('pkcs8', '-topk8', '-nocrypt', '-in', 'raw.key', '-out', 'pass.key');
  const rd = f => fs.readFileSync(path.join(d, f), 'utf8');
  ok(/BEGIN PRIVATE KEY/.test(rd('pass.key')), 'the key is PKCS#8, the form the Worker imports');

  const PNG = fs.readFileSync(path.join(SITE, 'assets/pass/icon.png'));
  const JPEG = Buffer.from([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9]);
  const env = { ASSETS, SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SECRET: 's', APPLE_PASS_TYPE_ID: 'pass.uk.com.ami.membership',
                APPLE_TEAM_ID: 'ABCDE12345', APPLE_PASS_CERT_PEM: rd('pass.pem'), APPLE_PASS_KEY_PEM: rd('pass.key'),
                APPLE_WWDR_PEM: rd('ca.pem') };
  const card = { given_name: 'Jane', family_name: 'Smith', slug: 'jane-smith', membership_number: 'TEST-0001',
                 grade: 'Member', grade_post_nominals: 'MAMI', is_active: true, joined_on: '2021-04-01',
                 requires_cpd: true, cpd_core: 3, cpd_non_core: 2, cpd_required_total: 10, photo_strip_path: 'p/strip.png' };
  const issued = { serial_number: 'test-serial-1', issued_at: '2026-10-30T20:00:00Z' };

  const build = async strip => {
    answer = () => new Response(strip, { status: 200 });
    const zip = await W.buildPkpass(env, card, issued, STAGING);
    const out = path.join(d, 'out-' + Math.random().toString(36).slice(2));
    fs.mkdirSync(out);
    fs.writeFileSync(path.join(out, 'a.pkpass'), zip);
    execFileSync('python3', ['-I', '-c', 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])',
                             path.join(out, 'a.pkpass'), out]);
    return out;
  };

  let out = await build(PNG);
  const names = fs.readdirSync(out).sort();
  for (const n of ['pass.json', 'manifest.json', 'signature', 'icon.png', 'logo.png', 'strip.png'])
    ok(names.includes(n), `the pass contains ${n}`);

  const manifest = JSON.parse(fs.readFileSync(path.join(out, 'manifest.json'), 'utf8'));
  const sha1 = f => execFileSync('openssl', ['dgst', '-sha1', '-r', path.join(out, f)]).toString().split(' ')[0];
  ok(Object.keys(manifest).length >= 8 && Object.entries(manifest).every(([f, h]) => sha1(f) === h),
     'every file in the manifest has its true SHA-1');
  ok(!('manifest.json' in manifest) && !('signature' in manifest), 'and the manifest does not list itself or the signature');

  const verify = content => {
    try {
      execFileSync('openssl', ['smime', '-verify', '-binary', '-inform', 'DER', '-in', path.join(out, 'signature'),
        '-content', content, '-CAfile', path.join(d, 'ca.pem'), '-purpose', 'any', '-out', '/dev/null'], { stdio: 'pipe' });
      return true;
    } catch { return false; }
  };
  ok(verify(path.join(out, 'manifest.json')), 'the signature verifies against the chain');
  const tampered = path.join(out, 'manifest-tampered.json');
  fs.writeFileSync(tampered, JSON.stringify(Object.assign({}, manifest, { 'pass.json': '0'.repeat(40) })));
  ok(!verify(tampered), 'and a tampered manifest does not');
  const asn = execFileSync('openssl', ['asn1parse', '-inform', 'DER', '-in', path.join(out, 'signature')]).toString();
  ok(/sha256/.test(asn), 'the signature digest is SHA-256; only the manifest hashes are SHA-1, because Apple defines those');

  const pj = JSON.parse(fs.readFileSync(path.join(out, 'pass.json'), 'utf8'));
  ok(pj.storeCard && !pj.storeCard.primaryFields, 'no primary field, so nothing is drawn over the photograph');
  ok(pj.storeCard.secondaryFields.length === 2 && pj.storeCard.auxiliaryFields.length === 2,
     'two and two, so MEMBERSHIP NO is not cut to MEMBE...');
  ok(pj.barcodes.length === 1 && pj.barcodes[0].message === STAGING + '/m/jane-smith',
     'one QR code, pointing at the public record');
  ok(pj.storeCard.auxiliaryFields.some(f => f.value === '5 of 10'), 'the CPD position is on the card');
  ok(pj.passTypeIdentifier === 'pass.uk.com.ami.membership' && pj.teamIdentifier === 'ABCDE12345',
     'with the identifiers from the bindings');

  out = await build(JPEG);
  ok(!fs.readdirSync(out).includes('strip.png'),
     'a strip that is a JPEG called .png is LEFT OUT, because iOS refuses the whole pass over it');

  const noAssets = Object.assign({}, env, { ASSETS: { fetch: async () => new Response('x', { status: 404 }) } });
  let threw = false;
  try { await W.buildPkpass(noAssets, card, issued, STAGING); } catch { threw = true; }
  ok(threw, 'a missing pass image stops the build rather than shipping a pass without it');
  fs.rmSync(d, { recursive: true, force: true });
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
