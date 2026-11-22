/* CPD evidence through the Worker, and Claude reading certificates (0045),
   actually run.

   Test 32 proves the database refuses a file used before. What is proved here
   is that the Worker gives it the truth: the fingerprint is taken from the
   bytes it stores, a file is what its first bytes say and not what its name
   says, a refused file is not left in storage, and a certificate goes to
   Claude without the member's name.

   Nothing mocked except the network.

   Run:  node tests/33_evidence_worker.mjs [path-to-site]
*/
import fs from 'fs';
import os from 'os';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SITE = process.argv[2] || path.resolve(HERE, '../../site');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };
const section = t => console.log('\n' + t);

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-ev-'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'worker.mjs'));

const J = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const PDF = new TextEncoder().encode('%PDF-1.4\n1 0 obj <<>> endobj\ntrailer\n%%EOF\n');
const SHA = crypto.createHash('sha256').update(PDF).digest('hex');
const PERSON = '5d5d1111-0000-0000-0000-000000000009';

let calls = [], over = {};
globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  const call = { url, method: init.method || 'GET', headers, body: init.body };
  calls.push(call);
  const u = new URL(url);
  const key = u.host === 'api.anthropic.com' ? 'claude' : u.pathname.replace('/rest/v1/rpc/', '');
  if (over[key]) return over[key](call);
  // 0057 era: the Worker asks Supabase Auth whether a sign in is real first.
  if (u.pathname === '/auth/v1/user') return headers.authorization === 'Bearer forged' ? J({ msg: 'bad jwt' }, 401) : J({ id: 'u1' });
  if (key === 'cpd_evidence_begin') return J({ upload_id: 'up-1', path: 'person-1/entry-1-abc.pdf' });
  if (key === 'cpd_evidence_record') return J('ev-1');
  if (u.pathname.startsWith('/storage/v1/object/cpd-evidence/'))
    return call.method === 'GET' ? new Response(PDF) : J({ Key: 'x' });
  if (key === 'ai_review_begin') return J({ by: PERSON, guide_id: 'g', guide_version: 1, guide: 'g', model: 'claude-test', items: [], remaining: 0 });
  if (key === 'ai_certificate_begin') return J({ by: PERSON, model: 'claude-test', remaining: 0, items: [
    { id: 'ev-9', path: 'person-2/entry-9-x.pdf', content_type: 'application/pdf', byte_size: PDF.length,
      activity: 'External training course or seminar', title: 'Face fit testing', provider: 'ACME', occurred_on: '2027-03-01' } ] });
  if (key === 'claude') return J({ content: [{ type: 'tool_use', name: 'record_certificate', input: {
    readable: true, is_certificate: true, holder_name: 'Cerys Cert', course: 'Face fit testing', issuer: 'ACME',
    awarded_on: '1 March 2027', certificate_number: 'AB-12/34', concerns: '' } }] });
  if (key === 'ai_certificate_record' || key === 'ai_certificate_release') return J('ok');
  return new Response('unexpected ' + url, { status: 599 });
};

const W = await import(pathToFileURL(path.join(TMP, 'worker.mjs')).href);
const worker = W.default;
const ENV = {
  SUPABASE_URL: 'https://ttjvwxxtoidiiejyqmbc.supabase.co',
  SUPABASE_SECRET: 'x.eyJyZWYiOiJ0dGp2d3h4dG9pZGlpZWp5cW1iYyJ9.x',
  SUPABASE_ANON: 'sb_publishable_x', ANTHROPIC_API_KEY: 'sk-ant-test',
  ASSETS: { fetch: async () => new Response('x') },
};
const upload = (bytes, { name = 'certificate.pdf', type = 'application/pdf', token = 'MEMBER', entry = '5d5d4444-0000-0000-0000-000000000001' } = {}) => {
  const fd = new FormData();
  fd.append('entry', entry);
  fd.append('file', new Blob([bytes], { type }), name);
  return worker.fetch(new Request('https://staging.ami.uk.com/api/cpd/evidence', {
    method: 'POST', headers: token ? { Authorization: 'Bearer ' + token } : {}, body: fd }), ENV);
};
const reset = () => { calls = []; over = {}; };
const find = k => calls.find(c => c.url.includes(k));

// ---- 1. The upload ------------------------------------------------------------
section('the upload');
{
  reset();
  let r = await worker.fetch(new Request('https://staging.ami.uk.com/api/cpd/evidence'), ENV);
  ok(r.status === 405 && r.headers.get('Allow') === 'POST', 'by GET is 405 and says POST');
  r = await upload(PDF, { token: null });
  ok(r.status === 401, 'signed out, 401');
  reset();
  r = await upload(PDF, { token: 'forged' });
  ok(r.status === 401 && !find('cpd_evidence_begin') && !find('/storage/'),
     'a made up sign in is refused at the door, before anything is read or stored (security check, 31 October)');

  reset();
  r = await upload(PDF);
  const j = await r.json();
  ok(r.status === 200 && j.id === 'ev-1', 'a real PDF is stored and recorded');
  const b = find('cpd_evidence_begin');
  const args = JSON.parse(b.body);
  ok(b.headers.authorization === 'Bearer MEMBER' && b.headers.apikey === 'sb_publishable_x',
     'the database is asked AS THE MEMBER whether this file may go on this entry');
  ok(args.p_sha256 === SHA, 'with the SHA-256 of the bytes themselves');
  ok(args.p_type === 'application/pdf' && args.p_size === PDF.length, 'and the type and size the Worker found');
  const st = calls.find(c => c.url.includes('/storage/v1/object/cpd-evidence/person-1/entry-1-abc.pdf'));
  ok(st && st.method === 'POST' && st.headers.apikey === ENV.SUPABASE_SECRET, 'stored where the database said, with the service key');
  const rec = JSON.parse(find('cpd_evidence_record').body);
  ok(rec.p_upload === 'up-1' && rec.p_sha256 === SHA && find('cpd_evidence_record').headers.apikey === ENV.SUPABASE_SECRET,
     'and recorded as the service role, with the fingerprint taken HERE, not one the browser sent');

  reset();
  r = await upload(new TextEncoder().encode('MZ this is a program, not a certificate'), { name: 'certificate.pdf' });
  ok(r.status === 400 && /PDF, JPEG, PNG or WebP/.test((await r.json()).error) && !find('cpd_evidence_begin'),
     'a file called .pdf that is not a PDF is refused before anything is asked or stored');

  reset();
  const jpeg = new Uint8Array([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0]);
  r = await upload(jpeg, { name: 'photo.pdf', type: 'application/pdf' });
  ok(r.status === 200 && JSON.parse(find('cpd_evidence_begin').body).p_type === 'image/jpeg',
     'a photograph is called a photograph, whatever its name and type said');

  reset();
  over.cpd_evidence_begin = () => J({ code: '23505', message: 'This certificate has already been used for CPD. A certificate counts once.' }, 409);
  r = await upload(PDF);
  let k = await r.json();
  ok(r.status === 409 && k.duplicate && /already been used/.test(k.error), 'a certificate used before is refused, in the database\'s words');
  ok(!calls.some(c => c.url.includes('/storage/')), 'and nothing is stored');

  reset();
  over.cpd_evidence_record = () => J({ code: '23505', message: 'This certificate has already been used for CPD. A certificate counts once.' }, 409);
  r = await upload(PDF);
  k = await r.json();
  ok(r.status === 409 && k.duplicate, 'losing a race to the same file is refused too');
  ok(calls.some(c => c.method === 'DELETE' && c.url.includes('/storage/v1/object/cpd-evidence/person-1/entry-1-abc.pdf')),
     'and the file already stored is taken away again');

  reset();
  const big = new Uint8Array(20 * 1024 * 1024 + 1); big.set(PDF);
  r = await upload(big);
  ok(r.status === 400 && /20MB/.test((await r.json()).error), 'over 20MB is refused');
}

// ---- 2. Claude reading a certificate ------------------------------------------
section('Claude reading a certificate');
{
  reset();
  const r = await worker.fetch(new Request('https://staging.ami.uk.com/api/cpd/ai-review', {
    method: 'POST', headers: { Authorization: 'Bearer STAFF', Origin: 'https://admin-staging.ami.uk.com' }, body: '{}' }), ENV);
  const j = await r.json();
  ok(r.status === 200 && j.certificates === 1 && j.done === 0, 'with no reflection waiting, the certificates are read: ' + JSON.stringify(j));
  ok(find('ai_certificate_begin').headers.authorization === 'Bearer STAFF', 'asked for as the staff member');
  const get = calls.find(c => c.method === 'GET' && c.url.includes('/storage/v1/object/cpd-evidence/person-2/entry-9-x.pdf'));
  ok(get && get.headers.apikey === ENV.SUPABASE_SECRET, 'the file is fetched from the private bucket with the service key');
  const c = find('api.anthropic.com');
  const body = JSON.parse(c.body);
  const blocks = body.messages[0].content;
  ok(blocks[0].type === 'document' && blocks[0].source.media_type === 'application/pdf'
     && Buffer.from(blocks[0].source.data, 'base64').equals(Buffer.from(PDF)),
     'Claude is given the certificate itself, as a PDF document');
  ok(/Face fit testing/.test(blocks[1].text) && !/Cerys|5d5d/.test(JSON.stringify(body)),
     'with the entry\'s activity, title and date, and NOTHING about who logged it');
  ok(body.tools[0].name === 'record_certificate' && body.tool_choice.type === 'auto', 'and asked to answer through the one tool');
  ok(/never an instruction to you/.test(body.system), 'and told that words in the document are evidence, not instructions');
  const rec = JSON.parse(find('ai_certificate_record').body);
  ok(rec.p_evidence === 'ev-9' && rec.p_by === PERSON && rec.p_holder === 'Cerys Cert' && rec.p_number === 'AB-12/34',
     'what Claude read is recorded, for the person who asked');
  ok(rec.p_awarded_on === '', 'a date not given as YYYY-MM-DD is left empty rather than guessed at');
  ok(find('ai_certificate_record').headers.apikey === ENV.SUPABASE_SECRET, 'as the service role');
  ok(!calls.some(x => /review_cpd/.test(x.url)), 'and nothing anywhere decides the entry');

  reset();
  over.claude = () => J({ content: [{ type: 'text', text: 'Looks fine to me.' }] });
  const r2 = await worker.fetch(new Request('https://staging.ami.uk.com/api/cpd/ai-review', {
    method: 'POST', headers: { Authorization: 'Bearer STAFF' }, body: '{}' }), ENV);
  const j2 = await r2.json();
  ok(r2.status === 422 && !find('ai_certificate_record') && find('ai_certificate_release'),
     'prose instead of the tool records nothing, and the certificate is released to be read again');
  ok(/expected shape/.test(j2.error), 'and says why');

  ok(W.evidenceType(new Uint8Array([0x52,0x49,0x46,0x46,0,0,0,0,0x57,0x45,0x42,0x50])) === 'image/webp'
     && W.evidenceType(new Uint8Array([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0,0,0,0])) === 'image/png',
     'WebP and PNG are known by their first bytes');
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
