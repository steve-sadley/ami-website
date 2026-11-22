/* The guidance document door in the Worker (0065, site 83), actually run.

   Test 65 proves the database's rules. Proved here: a published open
   document is handed over to anybody, as the type its extension says and
   never what storage claims, with nosniff and a sandbox; a members only one
   needs a token and is asked about AS that person; a lapsed member is
   refused; a withdrawn or unknown one is a 404 in words; a slug that is not
   a slug never reaches the database; and the old site's two addresses
   redirect for good.

   Run:  node tests/70_guidance_worker.mjs [path-to-site]
*/
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SITE = process.argv[2] || path.resolve(HERE, '../../site');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-gd-'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'worker.mjs'));

const J = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const PDF = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34, 10, 1, 2, 3]);
const DOCS = {
  'open-guide':    { path: 'documents/2026/open-guide-abc123.pdf', members_only: false, slug: 'open-guide', title: 'Open' },
  'members-guide': { path: 'documents/2026/members-guide-def456.docx', members_only: true, slug: 'members-guide', title: 'Members' },
  'odd-guide':     { path: 'documents/2026/odd-guide-ghi789.html', members_only: false, slug: 'odd-guide', title: 'Odd' },
};

let calls = [], member = true;
globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  calls.push({ url, headers, body: init.body });
  if (url.endsWith('/rpc/guidance_file')) return J(DOCS[JSON.parse(init.body).p_slug] || null);
  if (url.endsWith('/rpc/can_read_member_documents')) return J(member);
  if (url.includes('/storage/v1/object/content-media/'))
    return new Response(PDF, { headers: { 'Content-Type': 'text/html' } });   // storage claiming the wrong type
  return new Response('unexpected ' + url, { status: 599 });
};

const W = await import(pathToFileURL(path.join(TMP, 'worker.mjs')).href);
const worker = W.default;
const ENV = {
  SUPABASE_URL: 'https://ttjvwxxtoidiiejyqmbc.supabase.co',
  SUPABASE_SECRET: 'x.eyJyZWYiOiJ0dGp2d3h4dG9pZGlpZWp5cW1iYyJ9.x',
  SUPABASE_ANON: 'sb_publishable_x',
  ASSETS: { fetch: async () => new Response('page') },
};
const words = async r => { try { return JSON.parse(await r.text()).error || ''; } catch { return ''; } };
const get = (p, headers = {}, method = 'GET') => worker.fetch(new Request('https://staging.ami.uk.com' + p, { method, headers }), ENV);
const reset = () => { calls = []; member = true; };
const find = k => calls.find(c => c.url.includes(k));

reset();
let r = await get('/api/guidance/open-guide');
let bytes = new Uint8Array(await r.arrayBuffer());
ok(r.status === 200 && bytes.length === PDF.length && bytes[0] === 0x25, 'an open document is handed to a visitor');
ok(r.headers.get('Content-Type') === 'application/pdf', 'as a PDF, decided from its extension and not from what storage said');
ok(r.headers.get('X-Content-Type-Options') === 'nosniff' && /sandbox/.test(r.headers.get('Content-Security-Policy') || ''),
   'with nosniff and a sandbox, so nothing in a file can run on the site');
ok(/^inline; filename="open-guide\.pdf"$/.test(r.headers.get('Content-Disposition') || ''), 'a PDF opens in the browser, named after the document');
ok(/public, max-age=300/.test(r.headers.get('Cache-Control') || ''), 'cached briefly, so withdrawing one takes effect quickly');
ok(find('/rpc/guidance_file').headers.authorization === 'Bearer ' + ENV.SUPABASE_SECRET, 'the database is asked as the service role');
ok(find('/storage/v1/object/content-media/documents/2026/open-guide-abc123.pdf'), 'and the file is read from the private bucket');

reset();
r = await get('/api/guidance/members-guide');
const b = await words(r);
ok(r.status === 401 && /members/.test(b) && !find('/storage/'), 'a members only document without a sign in is refused, in words, and not read');

reset();
r = await get('/api/guidance/members-guide', { Authorization: 'Bearer MEMBER-TOKEN' });
const asked = find('/rpc/can_read_member_documents');
ok(asked && asked.headers.authorization === 'Bearer MEMBER-TOKEN' && asked.headers.apikey === 'sb_publishable_x',
   'with a sign in, the database is asked AS that person whether they may have it');
ok(r.status === 200 && r.headers.get('Content-Type').startsWith('application/vnd.openxmlformats-officedocument.wordprocessingml'),
   'a current member gets it, as a Word document');
ok(/^attachment; filename="members-guide\.docx"$/.test(r.headers.get('Content-Disposition') || ''), 'saved rather than opened');
ok(/private, no-store/.test(r.headers.get('Cache-Control') || ''), 'and never cached anywhere shared');

reset(); member = false;
r = await get('/api/guidance/members-guide', { Authorization: 'Bearer LAPSED-TOKEN' });
ok(r.status === 403 && /current members/.test(await words(r)) && !find('/storage/'), 'a lapsed member is refused, and the file is not read');

reset();
r = await get('/api/guidance/withdrawn-guide');
ok(r.status === 404 && /not available/.test(await words(r)), 'a document that is not published is a 404 in words');

reset();
r = await get('/api/guidance/odd-guide');
ok(r.status === 404 && !find('/storage/'), 'a file of a type the site does not serve is never handed out');

reset();
r = await get('/api/guidance/' + encodeURIComponent('../secret'));
ok(r.status === 404 && calls.length === 0, 'a slug that is not a slug never reaches the database');

reset();
r = await get('/api/guidance/open-guide', {}, 'POST');
ok(r.status === 405 && /GET/.test(r.headers.get('Allow') || ''), 'by POST is 405');
r = await get('/api/guidance/open-guide', {}, 'HEAD');
ok(r.status === 200 && (await r.arrayBuffer()).byteLength === 0, 'HEAD answers without the body');

const { SUPABASE_SECRET, ...noKey } = ENV;
reset();
r = await worker.fetch(new Request('https://staging.ami.uk.com/api/guidance/open-guide'), noKey);
ok(r.status === 503 && r.status !== 502, 'without the database key it says documents are unavailable, never 502');

for (const [from, to] of [['/membership/professional-conduct/', '/professional-conduct'],
                          ['/membership/committees', '/committees']]) {
  r = await get(from);
  ok(r.status === 301 && r.headers.get('Location') === 'https://staging.ami.uk.com' + to, `${from} moves for good to ${to}`);
}

console.log(`\n${pass} passed, ${fail} failed`);
fs.rmSync(TMP, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
