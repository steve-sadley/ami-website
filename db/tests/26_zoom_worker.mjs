/* Zoom attendance in the Worker (0042), actually run.

   The database decides everything about attendance and test 25 proves it. What
   is left for the Worker is fetching, and fetching has its own ways to go
   wrong in silence: the wrong occurrence of a weekly meeting, a second page
   never asked for, a slash in a UUID read as a path, a missing scope that
   reads as "it did not work", or the staff member's say so being skipped. Each
   of those is a check here, against a stub Zoom and a stub database.

   Nothing mocked except the network.

   Run:  node tests/26_zoom_worker.mjs [path-to-site]
*/
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SITE = process.argv[2] || path.resolve(HERE, '../../site');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };
const section = t => console.log('\n' + t);

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-zoom-'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'worker.mjs'));

// ---- a stub Zoom and a stub database ----------------------------------------
const J = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json' } });

let calls = [];
let zoom = {};          // per test: overrides by key
const SESSION = '2e2e3333-0000-0000-0000-000000000001';
const PERSON  = '2e2e1111-0000-0000-0000-000000000009';
let begin = { kind: 'meeting', zoom_id: '81234567890', zoom_uuid: null, held_on: '2027-06-11', by: PERSON };

globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  const call = { url, method: init.method || 'GET', headers, body: init.body };
  calls.push(call);
  const u = new URL(url);

  if (u.host === 'zoom.us' && u.pathname === '/oauth/token')
    return zoom.token ? zoom.token(call) : J({ access_token: 'ZT', expires_in: 3600 });

  if (u.host === 'api.zoom.us') {
    const p = u.pathname.replace('/v2', '');
    if (/^\/past_(meeting|webinar)s\/[^/]+\/instances$/.test(p))
      return zoom.instances ? zoom.instances(call) : J({ meetings: [
        { uuid: 'older==', start_time: '2027-06-04T09:00:00Z' },
        // 23:30 UTC on the 10th is 00:30 on the 11th in London, in summer time.
        { uuid: 'abc//def==', start_time: '2027-06-10T23:30:00Z' },
      ] });
    if (/^\/report\/(meeting|webinar)s\/[^/]+$/.test(p))
      return zoom.details ? zoom.details(call) : J({ uuid: 'abc//def==', topic: 'Seminar',
        start_time: '2027-06-10T23:30:00Z', end_time: '2027-06-11T00:30:00Z' });
    if (/^\/report\/(meeting|webinar)s\/[^/]+\/participants$/.test(p)) {
      if (zoom.participants) return zoom.participants(call);
      return u.searchParams.get('next_page_token') === 'P2'
        ? J({ participants: [
            { user_email: '', name: 'Registered but anonymous', registrant_id: 'R1',
              join_time: '2027-06-10T23:30:00Z', leave_time: '2027-06-11T00:30:00Z', status: 'in_meeting' } ],
            next_page_token: '' })
        : J({ participants: [
            { id: 'zoom-user-1', user_id: '16778240', user_email: 'one@test.invalid', name: 'One',
              ip_address: '203.0.113.9', device: 'Mac', join_time: '2027-06-10T23:30:00Z',
              leave_time: '2027-06-11T00:30:00Z', status: 'in_meeting' },
            { user_email: 'one@test.invalid', name: 'One', join_time: '2027-06-10T23:20:00Z',
              leave_time: '2027-06-10T23:30:00Z', status: 'in_waiting_room' } ],
            next_page_token: 'P2' });
    }
    if (/^\/(meeting|webinar)s\/[^/]+\/registrants$/.test(p))
      return zoom.registrants ? zoom.registrants(call)
        : J({ registrants: [{ id: 'R1', email: 'registered@test.invalid' }], next_page_token: '' });
  }

  if (u.pathname === '/rest/v1/rpc/zoom_import_begin')
    return zoom.begin ? zoom.begin(call) : J(begin);
  if (u.pathname === '/rest/v1/rpc/zoom_record_attendance')
    return zoom.record ? zoom.record(call)
      : J({ length_minutes: 60, counts: { awarded: 2 }, before_scheme: false });

  return new Response('unexpected ' + url, { status: 599 });
};

const W = await import(pathToFileURL(path.join(TMP, 'worker.mjs')).href);
const worker = W.default;
const ENV = {
  SUPABASE_URL: 'https://ttjvwxxtoidiiejyqmbc.supabase.co',
  SUPABASE_SECRET: 'x.eyJyZWYiOiJ0dGp2d3h4dG9pZGlpZWp5cW1iYyJ9.x',
  SUPABASE_ANON: 'sb_publishable_x',
  ZOOM_ACCOUNT_ID: ' acct-1 \n', ZOOM_CLIENT_ID: 'client-1\n', ZOOM_CLIENT_SECRET: 'shh',
  ASSETS: { fetch: async () => new Response('x') },
};
const URL_ = 'https://staging.ami.uk.com/api/zoom/attendance';
const post = (body, { token = 'STAFF-TOKEN', env = ENV, origin = 'https://admin-staging.ami.uk.com' } = {}) =>
  worker.fetch(new Request(URL_, { method: 'POST',
    headers: Object.assign({ 'Content-Type': 'application/json', Origin: origin },
                           token ? { Authorization: 'Bearer ' + token } : {}),
    body: JSON.stringify(body) }), env);
const reset = () => { calls = []; zoom = {}; };
const zoomCalls = () => calls.filter(c => /zoom\.us/.test(c.url));
const recordCall = () => calls.find(c => /zoom_record_attendance/.test(c.url));

// ---- 1. The door ------------------------------------------------------------
section('the door');
{
  reset();
  let r = await worker.fetch(new Request(URL_), ENV);
  ok(r.status === 405 && r.headers.get('Allow') === 'POST', 'by GET is 405 and says POST');

  r = await worker.fetch(new Request(URL_, { method: 'OPTIONS',
    headers: { Origin: 'https://admin-staging.ami.uk.com' } }), ENV);
  ok(r.status === 204 && r.headers.get('Access-Control-Allow-Origin') === 'https://admin-staging.ami.uk.com'
     && /Authorization/.test(r.headers.get('Access-Control-Allow-Headers') || ''),
     'the admin app may ask, carrying its sign in');
  r = await worker.fetch(new Request(URL_, { method: 'OPTIONS', headers: { Origin: 'https://evil.example' } }), ENV);
  ok(!r.headers.get('Access-Control-Allow-Origin'), 'another site may not read the answer');

  const noZoom = Object.assign({}, ENV, { ZOOM_CLIENT_SECRET: '' });
  r = await post({ session: SESSION }, { env: noZoom });
  let j = await r.json();
  ok(r.status === 503 && j.at === 'zoom-bindings' && /ZOOM_CLIENT_SECRET/.test(j.error),
     'with a Zoom secret missing it says which, as a 503 and never a 502');
  ok(zoomCalls().length === 0, 'and asks Zoom nothing');

  r = await post({ session: SESSION }, { env: Object.assign({}, ENV, { SUPABASE_SECRET: '' }) });
  ok(r.status === 503, 'with no database key, 503');

  r = await post({ session: SESSION }, { token: null });
  ok(r.status === 401, 'with nobody signed in, 401');

  r = await post({ session: 'not-a-uuid' });
  ok(r.status === 400 && (await r.json()).at === 'input', 'with no session named, 400');
}

// ---- 2. The database decides who may ----------------------------------------
section('who may');
{
  reset();
  zoom.begin = () => J({ code: '42501', message: 'Reading attendance from Zoom is for membership staff.' }, 403);
  const r = await post({ session: SESSION });
  const j = await r.json();
  ok(r.status === 403 && /membership staff/.test(j.error), 'a refusal from the database is passed on in its words');
  ok(zoomCalls().length === 0, 'and Zoom is never asked');
  ok(!recordCall(), 'and nothing is recorded');
  const b = calls.find(c => /zoom_import_begin/.test(c.url));
  ok(b && b.headers.authorization === 'Bearer STAFF-TOKEN' && b.headers.apikey === 'sb_publishable_x',
     'begin is asked AS THE STAFF MEMBER, their token on Authorization and the public key on apikey');
}

// ---- 3. A good import -------------------------------------------------------
section('a good import');
{
  reset();
  const r = await post({ session: SESSION });
  const j = await r.json();
  ok(r.status === 200 && j.counts && j.counts.awarded === 2, 'answers 200 with what the database decided');

  const tok = calls.find(c => /oauth\/token/.test(c.url));
  const tu = new URL(tok.url);
  ok(tu.searchParams.get('grant_type') === 'account_credentials' && tu.searchParams.get('account_id') === 'acct-1',
     'the token is asked for with account credentials, the account id trimmed');
  ok(tok.headers.authorization === 'Basic ' + Buffer.from('client-1:shh').toString('base64'),
     'with the client id and secret as Basic, trimmed: a pasted newline would read as a wrong secret');

  const det = calls.find(c => /\/report\/meetings\/[^/]+$/.test(new URL(c.url).pathname));
  ok(det && det.url.includes('/report/meetings/abc%252F%252Fdef%253D%253D'),
     'the occurrence held on the session date IN LONDON is chosen, and a UUID with a double slash encoded twice: '
     + (det && det.url));
  ok(W.zoomPathId('abc/def==') === 'abc%2Fdef%3D%3D',
     'while a UUID with a single slash inside it is encoded once, which is Zoom\'s rule and not a slip');
  ok(zoomCalls().filter(c => /\/participants/.test(c.url)).length === 2
     && calls.some(c => /next_page_token=P2/.test(c.url)), 'both pages of participants are read');
  ok(zoomCalls().every(c => /zoom\.us\/oauth/.test(c.url) || c.headers.authorization === 'Bearer ZT'),
     'every Zoom call carries the Zoom token, and never the database key');

  const rec = recordCall();
  const body = JSON.parse(rec.body);
  ok(rec.headers.apikey === ENV.SUPABASE_SECRET && rec.headers.authorization === 'Bearer ' + ENV.SUPABASE_SECRET,
     'the attendance is recorded with the service key, which is the only thing that may');
  ok(body.p_session === SESSION && body.p_by === PERSON, 'for the session asked about, by the person who asked');
  ok(body.p_report.participants.length === 3, 'every line goes to the database, waiting room and all: it decides');
  ok(body.p_report.participants.some(p => p.status === 'in_waiting_room'), 'with the waiting room marked as such');
  ok(body.p_report.participants.every(p => Object.keys(p).sort().join() === 'join_time,leave_time,name,status,user_email'),
     'and nothing else: no Zoom user ids, no IP address, no device');
  ok(body.p_report.participants.some(p => p.user_email === 'registered@test.invalid'),
     'an email Zoom held back is filled in from the registrant list');
  ok(body.p_report.start_time === '2027-06-10T23:30:00Z' && body.p_report.uuid === 'abc//def==',
     'with when the session ran, from Zoom');
}

// ---- 4. Zoom saying no, in words somebody can act on ------------------------
section('zoom saying no');
{
  reset();
  zoom.participants = () => J({ code: 4711,
    message: 'Invalid access token, does not contain scopes:[report:read:list_meeting_participants:admin].' }, 400);
  let r = await post({ session: SESSION });
  let j = await r.json();
  ok(r.status === 422 && /missing a permission/.test(j.error)
     && /report:read:list_meeting_participants:admin/.test(j.error),
     'a missing scope is named, in Zoom\'s words, as a 422 and never a 502');
  ok(!recordCall(), 'and nothing is recorded');

  reset();
  zoom.details = () => J({ code: 3001, message: 'Meeting does not exist: 81234567890.' }, 404);
  r = await post({ session: SESSION });
  j = await r.json();
  ok(r.status === 422 && /half an hour/.test(j.error), 'a report not ready yet says to try again later');

  reset();
  zoom.token = () => J({ reason: 'Invalid client_id or client_secret', error: 'invalid_client' }, 400);
  r = await post({ session: SESSION });
  j = await r.json();
  ok(r.status === 422 && j.at === 'zoom-token' && /ZOOM_CLIENT_ID/.test(j.error),
     'wrong credentials say which settings to check');

  reset();
  zoom.token = () => { throw new TypeError('network down'); };
  r = await post({ session: SESSION });
  ok(r.status === 500 && !recordCall(), 'Zoom unreachable is a 500 that changes nothing');
}

// ---- 5. Which occurrence ----------------------------------------------------
section('which occurrence');
{
  reset();
  zoom.instances = () => J({ meetings: [
    { uuid: 'a==', start_time: '2027-06-11T09:00:00Z' }, { uuid: 'b==', start_time: '2027-06-11T14:00:00Z' } ] });
  let r = await post({ session: SESSION });
  let j = await r.json();
  ok(r.status === 409 && j.uuids && j.uuids.length === 2 && !recordCall(),
     'two sessions with one number on one day: it asks which, and lists them, rather than guess');

  reset();
  zoom.instances = () => J({ code: 4711, message: 'does not contain scopes:[meeting:read:list_past_instances:admin]' }, 400);
  r = await post({ session: SESSION });
  j = await r.json();
  ok(r.status === 200 && j.warnings.some(w => /most recent/.test(w))
     && calls.some(c => /\/report\/meetings\/81234567890$/.test(new URL(c.url).pathname)),
     'occurrences unreadable: the number is used and the answer says so');

  reset();
  const keep = begin;
  begin = Object.assign({}, begin, { zoom_uuid: '/given/uuid==', kind: 'webinar' });
  r = await post({ session: SESSION });
  ok(r.status === 200 && !calls.some(c => /instances/.test(c.url))
     && calls.some(c => c.url.includes('/report/webinars/%252Fgiven%252Fuuid%253D%253D')),
     'a UUID the office gave is used as it stands, for a webinar too');
  begin = keep;

  ok(W.londonDate('2027-01-15T23:30:00Z') === '2027-01-15' && W.londonDate('2027-06-15T23:30:00Z') === '2027-06-16',
     'a date is read in London: the same UTC time is the same day in winter and the next in summer');
}

// ---- 6. The database refusing the record ------------------------------------
section('the record');
{
  reset();
  zoom.record = () => J({ code: '42501', message: 'Nobody on the staff asked for this import just now.' }, 403);
  const r = await post({ session: SESSION });
  const j = await r.json();
  ok(r.status === 400 && /Nobody on the staff/.test(j.error), 'a refused record is said in the database\'s words');
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
