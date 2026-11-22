/* The communication log in the Worker (0046), actually run.

   Test 34 proves the database's half. What is proved here: each of the four
   emails the Worker sends itself is written to the log after it is sent,
   as sent or failed, with exactly what went; a log that cannot be written
   never costs the visitor their answer; and the drain, whose letters are in
   the outbox already, writes nothing twice.

   Run:  node tests/35_comms_log_worker.mjs [path-to-site]
*/
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SITE = process.argv[2] || path.resolve(HERE, '../../site');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-log-'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'worker.mjs'));
const cacheStore = new Map();
globalThis.caches = { default: {
  match: async r => cacheStore.has(r.url) ? new Response(cacheStore.get(r.url)) : undefined,
  put: async (r, res) => { cacheStore.set(r.url, await res.text()); } } };

const J = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
let calls = [], smtp = () => J({ data: { succeeded: 1, failed: 0 } }), logAnswer = () => J('id-1');
globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  calls.push({ url, headers, body: init.body });
  if (/smtp2go/.test(url)) return smtp();
  if (/rpc\/log_direct_email/.test(url)) return logAnswer();
  if (/rpc\/claim_email_batch/.test(url)) return J([{ id: 'm1', to_email: 'm@test.invalid', to_name: 'M', subject: 'Queued',
                                                       html: '<p>q</p>', reply_to: null, from_email: null }]);
  if (/rpc\/mark_email_sent/.test(url)) return J(null);
  if (/rpc\/whoami/.test(url)) return J(headers.authorization === 'Bearer STAFF' ? [{ person_id: 'p9', roles: ['membership'] }]
                                        : [{ person_id: 'p1', roles: [] }]);
  return new Response('unexpected ' + url, { status: 599 });
};

const W = await import(pathToFileURL(path.join(TMP, 'worker.mjs')).href);
const ENV = { SMTP2GO_KEY: 'k', CONTACT_TO: 'office@test.invalid', CONTACT_FROM: 'no-reply@ami.uk.com',
  SITE_ORIGIN: 'https://staging.ami.uk.com', DRAIN_KEY: 'drain-key-1',
  SUPABASE_URL: 'https://ttjvwxxtoidiiejyqmbc.supabase.co',
  SUPABASE_SECRET: 'x.eyJyZWYiOiJ0dGp2d3h4dG9pZGlpZWp5cW1iYyJ9.x', SUPABASE_ANON: 'sb_publishable_x',
  ASSETS: { fetch: async () => new Response('x') } };
const contact = (email = 'eve@test.invalid') => W.default.fetch(new Request('https://staging.ami.uk.com/api/contact', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ name: 'Eve Enquirer', email, topic: 'other', message: 'Hello office, please help with membership.' }) }), ENV);
const logs = () => calls.filter(c => /log_direct_email/.test(c.url)).map(c => Object.assign(JSON.parse(c.body), { _h: c.headers }));

console.log('\nthe contact form');
{
  calls = [];
  const r = await contact();
  ok(r.status === 200, 'an enquiry is answered');
  const l = logs();
  ok(l.length === 2, 'both emails are written to the log: ' + l.length);
  const office = l.find(x => x.p_kind === 'contact_office'), ack = l.find(x => x.p_kind === 'contact_ack');
  ok(office && office.p_to_email === 'office@test.invalid' && /Eve Enquirer/.test(office.p_subject) && office.p_ok === true,
     'the enquiry to the office, as sent');
  ok(ack && ack.p_to_email === 'eve@test.invalid' && ack.p_subject === 'AMI has your message' && ack.p_ok === true,
     'and the acknowledgement to the visitor');
  const sent = calls.filter(c => /smtp2go/.test(c.url)).map(c => JSON.parse(c.body));
  ok(ack && sent.some(m => m.html_body === ack.p_html), 'what is logged is exactly what was sent');
  ok(l.every(x => x._h.apikey === ENV.SUPABASE_SECRET), 'written with the service key, the only thing that may');
  ok(calls.findIndex(c => /smtp2go/.test(c.url)) < calls.findIndex(c => /log_direct_email/.test(c.url)),
     'sent first and logged after, so the log never says something went that did not');
}

console.log('\nwhen sending fails');
{
  calls = [];
  smtp = () => J({ data: { succeeded: 0, failed: 1, error: 'Sender domain not verified' } }, 400);
  await contact('fay@test.invalid');
  const l = logs();
  ok(l.length === 2 && l.every(x => x.p_ok === false && /Sender domain not verified/.test(x.p_error)),
     'a failed send is logged as failed, with SMTP2GO\'s reason');
  smtp = () => J({ data: { succeeded: 1, failed: 0 } });
}

console.log('\nwhen the log cannot be written');
{
  calls = [];
  logAnswer = () => J({ message: 'down' }, 500);
  const r = await contact('gil@test.invalid');
  ok(r.status === 200 && (await r.json()).ok, 'the visitor still gets their answer: a log is never a reason to fail them');
  logAnswer = () => { throw new TypeError('network down'); };
  const r2 = await contact('hal@test.invalid');
  ok(r2.status === 200, 'nor when the database cannot be reached at all');
  logAnswer = () => J('id-1');
}

console.log('\nthe drain');
{
  calls = [];
  const drain = h => W.default.fetch(new Request('https://staging.ami.uk.com/api/mail/drain', { method: 'POST', headers: h }), ENV);
  const r = await drain({ 'X-Drain-Key': 'drain-key-1' });
  ok(r.status === 200 && logs().length === 0, 'a letter from the outbox is not logged a second time: it is the log already');
}

console.log('\nwho may ask for queued mail to go (31 October: AMI staff only)');
{
  const drain = h => W.default.fetch(new Request('https://staging.ami.uk.com/api/mail/drain', { method: 'POST', headers: h }), ENV);
  calls = [];
  let r = await drain({});
  ok(r.status === 401 && !calls.some(c => /claim_email_batch/.test(c.url)), 'nobody signed in: refused, and nothing is claimed');
  r = await drain({ 'X-Drain-Key': 'wrong' });
  ok(r.status === 401, 'the wrong key: refused');
  r = await drain({ Authorization: 'Bearer MEMBER' });
  ok(r.status === 401, 'a signed in member who is not staff: refused');
  r = await drain({ Authorization: 'Bearer STAFF' });
  ok(r.status === 200, 'a member of staff, signed in: sent');
  r = await drain({ 'X-Drain-Key': 'drain-key-1' });
  ok(r.status === 200, 'the schedule, with the key: sent');
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
