/* The interview booking doors in the Worker (0064), actually run.

   Test 64 proves the database's rules. What is proved here is the part only
   the Worker does: Outlook is asked, a clash in the diary takes a slot off the
   page and stops a booking, the event goes into the calendar as a Teams
   meeting with the applicant invited and cannot be written twice, a failure
   after the event exists takes it out again, a changed time cancels the old
   event, and the database's own words reach the applicant.

   Nothing mocked except the network.

   Run:  node tests/65_interview_worker.mjs [path-to-site]
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

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-iv-'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'worker.mjs'));

const J = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const T0 = Date.parse('2030-03-04T10:00:00Z');
const at = h => new Date(T0 + h * 3600e3).toISOString();
const SLOTS = [
  { id: 's1', starts_at: at(0),  ends_at: at(1.25),  minutes: 75 },
  { id: 's2', starts_at: at(24), ends_at: at(25.25), minutes: 75 },
  { id: 's3', starts_at: at(48), ends_at: at(49.25), minutes: 75 },
];
const HELD = { booking: 'bk-1', slot: 's1', starts_at: at(0), ends_at: at(1.25), minutes: 75,
  given_name: 'Ann', family_name: 'Applicant', email: 'ann@test.invalid', reference: 'AMI-2030-0001',
  grade: 'Member', previous: null };
const graphEvent = (startH, endH, showAs = 'busy') => ({
  start: { dateTime: at(startH).replace('Z', '') + '0000', timeZone: 'UTC' },
  end:   { dateTime: at(endH).replace('Z', '') + '0000',   timeZone: 'UTC' },
  showAs, isCancelled: false });

let calls = [], over = {}, busy = [];
globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  const call = { url, method: init.method || 'GET', headers, body: init.body };
  calls.push(call);
  const u = new URL(url);
  let key = u.pathname.replace('/rest/v1/rpc/', '');
  if (u.host === 'login.microsoftonline.com') key = 'ms-login';
  if (u.host === 'graph.microsoft.com') {
    if (u.pathname.endsWith('/calendarView')) key = 'ms-view';
    else if (/\/events$/.test(u.pathname) && call.method === 'POST') key = 'ms-create';
    else if (/\/cancel$/.test(u.pathname)) key = 'ms-cancel';
    else if (call.method === 'DELETE') key = 'ms-delete';
    else key = 'ms-get';
  }
  if (over[key]) return over[key](call);
  switch (key) {
    case 'ms-login':  return J({ access_token: 'MS-TOKEN', expires_in: 3600 });
    case 'ms-view':   return J({ value: busy });
    case 'ms-create': return J({ id: 'EVT-NEW', onlineMeeting: { joinUrl: 'https://teams.microsoft.com/l/meetup-join/x' } }, 201);
    case 'ms-cancel': return new Response(null, { status: 202 });
    case 'ms-delete': return new Response(null, { status: 204 });
    case 'interview_page': return J({ given_name: 'Ann', reference: 'AMI-2030-0001', notice_hours: 24, booking: null, slots: SLOTS });
    case 'interview_hold': return J(HELD);
    case 'interview_confirm': return J({ booked: true, starts_at: HELD.starts_at, previous_event_id: null });
    case 'interview_release': return new Response(null, { status: 204 });
    case 'interview_cancel': return J({ cancelled: true, event_id: 'EVT-OLD' });
    case 'interview_office_cancel': return J({ cancelled: true, event_id: 'EVT-OFF' });
    case 'claim_email_batch': return J([]);
  }
  return new Response('unexpected ' + url, { status: 599 });
};

const W = await import(pathToFileURL(path.join(TMP, 'worker.mjs')).href);
const worker = W.default;
const ENV = {
  SUPABASE_URL: 'https://ttjvwxxtoidiiejyqmbc.supabase.co',
  SUPABASE_SECRET: 'x.eyJyZWYiOiJ0dGp2d3h4dG9pZGlpZWp5cW1iYyJ9.x',
  SUPABASE_ANON: 'sb_publishable_x',
  SMTP2GO_KEY: 'k', CONTACT_TO: 'info@ami.uk.com', CONTACT_FROM: 'no-reply@ami.uk.com',
  MS_TENANT_ID: 'tenant-1', MS_CLIENT_ID: 'client-1', MS_CLIENT_SECRET: 'secret-1',
  MS_CALENDAR: 'steve.sadley@arca.org.uk',
  ASSETS: { fetch: async () => new Response('x') },
};
const post = (which, body, { env = ENV, headers = {} } = {}) => worker.fetch(new Request(
  'https://staging.ami.uk.com/api/interview/' + which,
  { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }), env);
const reset = () => { calls = []; over = {}; busy = []; };
const find = k => calls.find(c => c.url.includes(k));
const all = k => calls.filter(c => c.url.includes(k));
const rpcBody = fn => JSON.parse(find('/rpc/' + fn).body);

// ---- 1. The doors ---------------------------------------------------------------
section('the doors');
{
  reset();
  let r = await worker.fetch(new Request('https://staging.ami.uk.com/api/interview/slots'), ENV);
  ok(r.status === 405 && r.headers.get('Allow') === 'POST', 'by GET is 405 and says POST');
  r = await post('anything', {});
  ok(r.status === 404, 'an address that is not one of the four is 404');
  const { MS_CLIENT_SECRET, ...noMs } = ENV;
  r = await post('slots', { token: 'x' }, { env: noMs });
  const b = await r.json();
  ok(r.status === 503 && /not open yet/.test(b.error) && calls.length === 0,
     'without the Microsoft settings it says booking is not open, and asks nothing of anybody');
  ok(r.status !== 502 && r.status !== 504, 'and never answers 502 or 504, which Cloudflare would swallow');
}

// ---- 2. The page ------------------------------------------------------------------
section('the page');
{
  reset();
  busy = [graphEvent(24.5, 25), graphEvent(48, 49, 'free'), graphEvent(1.25, 2)];
  const r = await post('slots', { token: 'TOKEN-A' });
  const b = await r.json();
  ok(r.status === 200, 'answers 200');
  ok(b.slots.map(s => s.id).join(',') === 's1,s3',
     'a slot with something busy in Outlook is taken off; a free entry and one ending as the slot starts are not clashes');
  ok(rpcBody('interview_page').p_token === 'TOKEN-A', 'the database is asked with the applicant\'s token');
  const view = find('/calendarView');
  ok(view && view.headers.authorization === 'Bearer MS-TOKEN' && /outlook\.timezone="UTC"/.test(view.headers.prefer),
     'Outlook is read with the Microsoft token, in UTC');
  ok(view.url.includes('/users/steve.sadley%40arca.org.uk/'), 'and only the calendar MS_CALENDAR names');
  ok(find('/rest/v1/rpc/interview_page').headers.authorization === 'Bearer ' + ENV.SUPABASE_SECRET,
     'the database is asked as the service role');
  ok(new URL(view.url).searchParams.get('startDateTime') === SLOTS[0].starts_at
     && new URL(view.url).searchParams.get('endDateTime') === SLOTS[2].ends_at,
     'over exactly the span of the slots offered');

  // nextLink is followed
  reset();
  let page = 0;
  over['ms-view'] = () => (page++ === 0
    ? J({ value: [], '@odata.nextLink': 'https://graph.microsoft.com/v1.0/users/x/calendarView?$skip=250' })
    : J({ value: [graphEvent(0, 1)] }));
  const r2 = await post('slots', { token: 'TOKEN-A' });
  ok((await r2.json()).slots.map(s => s.id).join(',') === 's2,s3', 'a busy entry on the second page of the calendar counts too');
  ok(!all('login.microsoftonline').length, 'and the Microsoft token from before is reused, not asked for again');
}

// ---- 3. Booking ---------------------------------------------------------------------
section('booking');
{
  reset();
  const r = await post('book', { token: 'TOKEN-A', slot: 's1' });
  const b = await r.json();
  ok(r.status === 200 && b.booked && b.join_url === 'https://teams.microsoft.com/l/meetup-join/x', 'books, and hands back the Teams link');
  const ev = JSON.parse(find('/events').body);
  ok(ev.isOnlineMeeting === true && ev.onlineMeetingProvider === 'teamsForBusiness', 'the event is a Teams meeting');
  ok(ev.attendees.length === 1 && ev.attendees[0].emailAddress.address === 'ann@test.invalid',
     'with the applicant invited, so they get a calendar invitation');
  ok(ev.transactionId === 'ami-interview-bk-1', 'carrying the booking as its transactionId, so a retry cannot write it twice');
  ok(ev.start.dateTime === '2030-03-04T10:00:00.000' && ev.start.timeZone === 'UTC', 'at the slot\'s time');
  ok(rpcBody('interview_confirm').p_event_id === 'EVT-NEW', 'the database is told the Outlook event');
  ok(!!find('claim_email_batch'), 'and the two emails are sent straight away');
  const order = calls.map(c => c.url.includes('interview_hold') ? 'hold' : c.url.includes('/calendarView') ? 'view'
    : c.url.endsWith('/events') ? 'create' : c.url.includes('interview_confirm') ? 'confirm' : '').filter(Boolean);
  ok(order.join(',') === 'hold,view,create,confirm', 'in the order hold, check the diary, write, confirm');
}
{
  reset();
  busy = [graphEvent(0.5, 1)];
  const r = await post('book', { token: 'TOKEN-A', slot: 's1' });
  ok(r.status === 409 && !find('/events') && rpcBody('interview_release').p_booking === 'bk-1',
     'something in the diary at that time: the hold is let go and nothing is written');
}
{
  reset();
  over['interview_confirm'] = () => J({ message: 'boom' }, 500);
  const r = await post('book', { token: 'TOKEN-A', slot: 's1' });
  const b = await r.json();
  ok(r.status === 500 && !!find('/events/EVT-NEW/cancel'),
     'the database fails after the event exists: the event is cancelled again');
  ok(!!find('interview_release'), 'and the hold is let go');
  ok(!/boom/.test(b.error), 'and the applicant is not shown the database\'s internal words');
}
{
  reset();
  over['interview_confirm'] = () => J({ booked: true, starts_at: HELD.starts_at, previous_event_id: 'EVT-PREV' });
  await post('book', { token: 'TOKEN-A', slot: 's1' });
  ok(!!find('/events/EVT-PREV/cancel'), 'a changed time cancels the old Outlook event');
}
{
  reset();
  over['ms-create'] = () => J({ id: 'EVT-NEW', onlineMeeting: null }, 201);
  over['ms-get'] = () => J({ onlineMeeting: { joinUrl: 'https://teams.microsoft.com/l/late' } });
  const r = await post('book', { token: 'TOKEN-A', slot: 's1' });
  ok((await r.json()).join_url === 'https://teams.microsoft.com/l/late' && rpcBody('interview_confirm').p_join_url === 'https://teams.microsoft.com/l/late',
     'a Teams link that arrives a moment late is read again');
}
{
  reset();
  over['interview_hold'] = () => J({ code: '23505', message: 'Somebody has just booked that time. Please choose another.' }, 409);
  const r = await post('book', { token: 'TOKEN-A', slot: 's1' });
  const b = await r.json();
  ok(r.status === 409 && b.error === 'Somebody has just booked that time. Please choose another.' && !find('graph.microsoft'),
     'the database\'s own words reach the applicant, and Outlook is not touched');
  reset();
  over['interview_hold'] = () => J({ code: 'P0002', message: 'This booking link is not recognised.' }, 400);
  const r2 = await post('book', { token: 'TOKEN-OLD', slot: 's1' });
  ok(r2.status === 404, 'a link the database does not recognise is 404');
}
{
  reset();
  over['ms-view'] = () => J({ error: { code: 'ErrorAccessDenied', message: 'Access is denied.' } }, 403);
  const r = await post('book', { token: 'TOKEN-A', slot: 's1' });
  const b = await r.json();
  ok(r.status === 500 && /diary could not be reached/.test(b.error) && !!find('interview_release'),
     'Outlook refusing: the applicant is told the diary could not be reached, and the hold is let go');
  ok(/Access is denied/.test(b.reason), 'with Microsoft\'s reason kept for whoever looks');
}

// ---- 4. Cancelling ---------------------------------------------------------------------
section('cancelling');
{
  reset();
  const r = await post('cancel', { token: 'TOKEN-A' });
  ok(r.status === 200 && !!find('/events/EVT-OLD/cancel') && !!find('claim_email_batch'),
     'the applicant cancels: the Outlook event is cancelled and the emails go');
}
{
  reset();
  let r = await post('office-cancel', { booking: 'bk-9', reason: 'Unwell' });
  ok(r.status === 401 && !find('interview_office_cancel'), 'the office door wants a staff sign in');
  reset();
  r = await post('office-cancel', { booking: 'bk-9', reason: 'Unwell' },
    { headers: { Authorization: 'Bearer STAFF', Origin: 'https://admin-staging.ami.uk.com' } });
  const c = find('interview_office_cancel');
  ok(r.status === 200 && c.headers.authorization === 'Bearer STAFF' && c.headers.apikey === 'sb_publishable_x',
     'and asks the database as that member of staff, so the database decides whether they may');
  ok(r.headers.get('Access-Control-Allow-Origin') === 'https://admin-staging.ami.uk.com', 'answering the admin app across origins');
  ok(JSON.parse(find('/events/EVT-OFF/cancel').body).Comment === 'Unwell', 'the cancellation carries the office\'s reason');
  const pre = await worker.fetch(new Request('https://staging.ami.uk.com/api/interview/office-cancel',
    { method: 'OPTIONS', headers: { Origin: 'https://admin-staging.ami.uk.com' } }), ENV);
  ok(pre.status === 204 && /Authorization/.test(pre.headers.get('Access-Control-Allow-Headers')), 'the preflight is answered');
  reset();
  const r3 = await post('slots', { token: 'x' }, { headers: { Origin: 'https://admin-staging.ami.uk.com' } });
  ok(!r3.headers.get('Access-Control-Allow-Origin'), 'the applicant doors are not opened to other origins');
}

console.log(`\n${pass} passed, ${fail} failed`);
fs.rmSync(TMP, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
