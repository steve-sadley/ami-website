/* The ami-dynamics-sync Worker (0048), actually run, against a pretend
   Microsoft, a pretend Dynamics and a pretend database.

   Test 39 proves every decision, which is the database's. What is proved
   here: the Worker signs in with client credentials, finds each view by its
   exact name, reads every page, hands the rows over as Dynamics gave them with
   each record's id added, sends column names and never values as the list of
   columns, logs the run whatever happens, never writes to Dynamics, and that
   Sync now only runs for somebody the database says may. And the site's
   Sync now door passes the sign in through the binding and nothing else.

   Run:  node tests/40_dynamics_sync_worker.mjs [path-to-dynamics-sync] [path-to-site]
*/
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SYNC = process.argv[2] || path.resolve(HERE, '../../dynamics-sync');
const SITE = process.argv[3] || path.resolve(HERE, '../../site');
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ami-dyn-'));
fs.copyFileSync(path.join(SYNC, 'worker.js'), path.join(TMP, 'sync.mjs'));
fs.copyFileSync(path.join(SITE, '_worker.js'), path.join(TMP, 'site.mjs'));
globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };

const J = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const ORG = 'https://arca.crm11.dynamics.com';
const API = ORG + '/api/data/v9.2/';
const FV = '@OData.Community.Display.V1.FormattedValue';

// Two pages of regional meetings; the AGM view empty; training missing.
const page1 = { value: [
  { '@odata.etag': 'W/"1"', arca_attendanceid: 'g1', 'c.emailaddress1': 'a@test.invalid',
    _arca_meetingid_value: 'm-1', ['_arca_meetingid_value' + FV]: 'North West', '_arca_meetingid_value@Microsoft.Dynamics.CRM.lookuplogicalname': 'arca_meeting',
    arca_date: '2027-03-04' } ],
  '@odata.nextLink': API + 'arca_attendances?savedQuery=v-reg&$skiptoken=2' };
const page2 = { value: [ { arca_attendanceid: 'g2', 'c.emailaddress1': 'b@test.invalid', arca_date: '2027-03-04' } ] };

let calls = [], state;
const reset = () => { calls = []; state = { begin: { run: 'run-1', feeds: [
  { code: 'ami_members', view: 'AMI Sync: Members' },
  { code: 'arca_agm', view: 'AMI Sync: ARCA AGM' },
  { code: 'arca_training', view: 'AMI Sync: Training completions' },
  { code: 'regional_meetings', view: "AMI Sync: Regional meetings" } ] },
  token: () => J({ access_token: 'dyn-token' }), request: () => J('req-1') }; };

globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  const method = init.method || (typeof input === 'string' ? 'GET' : input.method) || 'GET';
  const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  const body = init.body ? String(init.body) : null;
  calls.push({ url: decodeURIComponent(url), method, headers, body });
  if (/login\.microsoftonline\.com/.test(url)) return state.token();
  if (url.startsWith(ORG)) {
    const u = decodeURIComponent(url);
    if (/savedqueries/.test(u)) {
      if (/AMI Sync: Regional meetings/.test(u)) return J({ value: [{ savedqueryid: 'v-reg', returnedtypecode: 'arca_attendance' }] });
      if (/AMI Sync: ARCA AGM/.test(u)) return J({ value: [{ savedqueryid: 'v-agm', returnedtypecode: 'arca_attendance' }] });
      if (/AMI Sync: Members/.test(u)) return J({ value: [{ savedqueryid: 'v-mem', returnedtypecode: 'contact' }] });
      return J({ value: [] });
    }
    if (/EntityDefinitions\(LogicalName='contact'\)/.test(u)) return J({ EntitySetName: 'contacts', PrimaryIdAttribute: 'contactid' });
    if (/EntityDefinitions/.test(u)) return J({ EntitySetName: 'arca_attendances', PrimaryIdAttribute: 'arca_attendanceid' });
    if (/savedQuery=v-mem/.test(u)) return J({ value: [{ contactid: 'c-1', lastname: 'One' }, { contactid: 'c-2', lastname: 'Two' }] });
    if (/savedQuery=v-reg&\$skiptoken=2/.test(u)) return J(page2);
    if (/savedQuery=v-reg/.test(u)) return J(page1);
    if (/savedQuery=v-agm/.test(u)) return state.agm403
      ? J({ error: { code: '0x80040220', message: "Principal user (Id=abc, type=8) is missing prvReadcore_course privilege (Id=def) on OTC=10234 for entity 'core_course'." } }, 403)
      : J({ value: [] });
    return new Response('unexpected ' + u, { status: 599 });
  }
  if (/rpc\/dynamics_sync_request/.test(url)) return state.request();
  if (/rpc\/dynamics_run_begin/.test(url)) return J(state.begin);
  if (/rpc\/dynamics_record/.test(url)) {
    const a = JSON.parse(body);
    return J({ feed: a.p_feed, ready: true, read: a.p_rows.length, unreadable: 0, decided: { awarded: a.p_rows.length } });
  }
  if (/rpc\/dynamics_run_finish/.test(url)) return J(null);
  if (/rpc\/dynamics_members_record/.test(url)) {
    const a = JSON.parse(body);
    return J({ feed: 'ami_members', ready: true, read: a.p_rows.length, unreadable: 0, decided: { linked: a.p_rows.length } });
  }
  if (/rpc\/dynamics_members_close/.test(url)) return J(state.closeAnswer || { switched_off: 1 });
  return new Response('unexpected ' + url, { status: 599 });
};

const W = await import(pathToFileURL(path.join(TMP, 'sync.mjs')).href);
const ENV = { DYNAMICS_ORG_URL: ORG, TENANT_ID: 'tenant-1', CLIENT_ID: 'client-ro', CLIENT_SECRET: 'shh',
  SUPABASE_URL: 'https://ttjvwxxtoidiiejyqmbc.supabase.co', SUPABASE_SECRET: 'service-key', SUPABASE_ANON: 'sb_publishable_x' };
const rpcs = n => calls.filter(c => c.url.includes('/rpc/' + n));
const dyn = () => calls.filter(c => c.url.startsWith(ORG));

console.log('\na scheduled run');
{
  reset();
  let wait;
  await W.default.scheduled({}, ENV, { waitUntil: p => { wait = p; } });
  await wait;
  const tok = calls.find(c => /login\.microsoftonline/.test(c.url));
  ok(tok && /tenant-1/.test(tok.url) && /grant_type=client_credentials/.test(tok.body)
     && tok.body.includes('scope=' + encodeURIComponent(ORG + '/.default')),
     'signs in to Microsoft with client credentials for this Dynamics');
  ok(dyn().every(c => c.method === 'GET'), 'never writes to Dynamics: every call is a read');
  ok(dyn().some(c => c.url.includes("name eq 'AMI Sync: Regional meetings'")), 'finds a view by its exact name');
  const recs = rpcs('dynamics_record').map(c => JSON.parse(c.body));
  const reg = recs.find(r => r.p_feed === 'regional_meetings');
  ok(reg && reg.p_rows.length === 2, 'reads every page of the view: ' + (reg && reg.p_rows.length));
  ok(reg && reg.p_rows[0]._ami_id === 'g1' && reg.p_rows[1]._ami_id === 'g2', 'with each record\'s own id added');
  ok(reg && reg.p_rows[0]['_arca_meetingid_value' + FV] === 'North West', 'keeps the words Dynamics gives for a lookup');
  ok(reg && !('@odata.etag' in reg.p_rows[0]) && !Object.keys(reg.p_rows[0]).some(k => /lookuplogicalname/.test(k)),
     'and drops Dynamics\' own bookkeeping');
  ok(reg && JSON.stringify(reg.p_meta.fields) === JSON.stringify(['_arca_meetingid_value', 'arca_attendanceid', 'arca_date', 'c.emailaddress1'])
     && !JSON.stringify(reg.p_meta).includes('a@test.invalid'),
     'the list of columns is names only, never a value');
  const agm = recs.find(r => r.p_feed === 'arca_agm');
  ok(agm && agm.p_rows.length === 0, 'an empty view is still reported');
  ok(!recs.some(r => r.p_feed === 'arca_training'), 'a view that does not exist sends nothing');
  const fin = rpcs('dynamics_run_finish').map(c => JSON.parse(c.body))[0];
  ok(fin && fin.p_run === 'run-1' && /No system view is called "AMI Sync: Training completions"/.test(fin.p_error)
     && fin.p_result.feeds.regional_meetings.read === 2,
     'the run is finished and logged, saying plainly which view is missing, and the others still ran');
  ok(rpcs('dynamics_record').every(c => c.headers.authorization === 'Bearer service-key'),
     'rows go to the database with the service key, the only thing that may write them');
}

console.log('\nthe AMI members view (0054)');
{
  reset();
  const out = await W.runSync(ENV, null);
  const rec = rpcs('dynamics_members_record').map(c => JSON.parse(c.body))[0];
  ok(rec && rec.p_rows.length === 2 && rec.p_rows[0]._ami_id === 'c-1' && !('p_feed' in rec),
     'members go to their own reader, each with its contact id');
  const closeCall = rpcs('dynamics_members_close').map(c => JSON.parse(c.body))[0];
  ok(closeCall && JSON.stringify(closeCall.p_ids) === JSON.stringify(['c-1', 'c-2']),
     'and after the whole view, the database is told every contact it held');
  const order = calls.map(c => c.url).filter(u => /rpc\/(dynamics_members_record|dynamics_members_close|dynamics_record)/.test(u));
  ok(/members_record/.test(order[0]) && /members_close/.test(order[1]) && /dynamics_record/.test(order[2]),
     'members are read and closed before any attendance');
  ok(out.feeds.ami_members.decided.switched_off === 1, 'and the run says who was switched off');
  reset();
  state.closeAnswer = { switched_off: 0, refused: 'The members view held 1 contacts against 40 linked members, so nobody was switched off. Check the view.' };
  const out2 = await W.runSync(ENV, null);
  ok(/nobody was switched off/.test(out2.error || ''), 'a refused close is reported as a problem with the run');
}

console.log('\nwhen Microsoft refuses');
{
  reset();
  state.token = () => J({ error: 'invalid_client' }, 401);
  const out = await W.runSync(ENV, null);
  ok(/Microsoft refused \(401, invalid_client\)/.test(out.error), 'it says so in words: ' + out.error);
  ok(rpcs('dynamics_run_finish').length === 1 && dyn().length === 0, 'the run is still logged as failed, and Dynamics is not asked');
}

console.log('\nwhen the role is short of a table');
{
  reset();
  state.agm403 = true;
  const out = await W.runSync(ENV, null);
  ok(/missing prvReadcore_course: give it Read, Organization/.test(out.feeds.arca_agm.error || ''),
     'a 403 names the privilege the role is missing: ' + (out.feeds.arca_agm.error || '').slice(0, 90));
  ok(out.feeds.regional_meetings.read === 2, 'and the other views still run');
}

console.log('\nwhen a run is going already');
{
  reset();
  state.begin = { skip: 'A sync is running already.' };
  const out = await W.runSync(ENV, null);
  ok(out.skipped && calls.length === 1, 'it does nothing at all');
}

console.log('\nSync now');
{
  reset();
  const run = (h = {}) => W.default.fetch(new Request('https://ami-dynamics-sync/run', { method: 'POST', headers: h }), ENV);
  let r = await run();
  ok(r.status === 401 && rpcs('dynamics_run_begin').length === 0, 'nobody signed in, no run');
  state.request = () => J({ code: '42501', message: 'Syncing ARCA\'s records is for membership staff.' }, 403);
  r = await run({ Authorization: 'Bearer member-token' });
  ok(r.status === 403 && rpcs('dynamics_run_begin').length === 0, 'a member is refused by the database, and nothing runs');
  const req = rpcs('dynamics_sync_request')[0];
  ok(req && req.headers.authorization === 'Bearer member-token' && req.headers.apikey === 'sb_publishable_x',
     'the database is asked as the person, not as the Worker');
  reset();
  r = await run({ Authorization: 'Bearer staff-token' });
  const begin = rpcs('dynamics_run_begin').map(c => JSON.parse(c.body))[0];
  ok(begin && begin.p_request === 'req-1', 'staff: the run the database recorded them asking for is the one begun');
  ok(r.status === 200 && (await r.json()).feeds.regional_meetings.read === 2, 'and the answer says what was read');
  r = await W.default.fetch(new Request('https://ami-dynamics-sync/run?key=anything'), ENV);
  ok(r.status === 405, 'no address with a key in it can start a sync');
  const missing = await run.call(null, { Authorization: 'Bearer x' }).then(() =>
    W.default.fetch(new Request('https://x/run', { method: 'POST', headers: { Authorization: 'Bearer x' } }), { ...ENV, CLIENT_SECRET: '' }));
  ok(missing.status === 503 && /CLIENT_SECRET/.test((await missing.json()).error), 'a missing secret is named');
}

console.log('\nthe site\'s Sync now door');
{
  const S = await import(pathToFileURL(path.join(TMP, 'site.mjs')).href);
  const SENV = { SITE_ORIGIN: 'https://staging.ami.uk.com', ASSETS: { fetch: async () => new Response('x') } };
  const ask = (env, h = {}) => S.default.fetch(new Request('https://staging.ami.uk.com/api/dynamics/sync-now',
    { method: 'POST', headers: { Origin: 'https://admin-staging.ami.uk.com', ...h } }), env);
  let r = await ask(SENV, { Authorization: 'Bearer t' });
  ok(r.status === 503 && /DYNAMICS_SYNC/.test((await r.json()).error), 'without the binding it says what to add');
  let seen = null;
  const bound = { ...SENV, DYNAMICS_SYNC: { fetch: async req => { seen = req; return J({ run: 'r', feeds: {} }); } } };
  r = await ask(bound);
  ok(r.status === 401 && !seen, 'nobody signed in is not passed on');
  r = await ask(bound, { Authorization: 'Bearer staff-token', Cookie: 'x=1' });
  ok(r.status === 200 && seen && seen.headers.get('Authorization') === 'Bearer staff-token' && !seen.headers.get('Cookie'),
     'the sign in, and only the sign in, goes through the binding');
  ok(r.headers.get('Access-Control-Allow-Origin') === 'https://admin-staging.ami.uk.com', 'and the admin app may read the answer');
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
