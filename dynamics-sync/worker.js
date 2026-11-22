// =============================================================================
// ami-dynamics-sync: CPD from ARCA's records in Dynamics (migration 0048)
//
// Modelled on AuditFlow's dynamics-supabase-sync, and deliberately smaller:
//
//   - signs in to Dynamics as its own read-only app registration
//   - finds each of three system views by its name, as AuditFlow finds
//     "AuditFlow Sync: Members"
//   - reads every row of each view and hands the rows to AMI's database
//     exactly as Dynamics gave them
//   - every run is logged in dynamics_runs, and the database refuses to begin
//     one on top of another
//
// This Worker decides NOTHING about the rows. Which column is the email, which
// is the date, who is matched, what earns points and whether anything is
// awarded twice are all in the database, in one place, and tested (test 39).
// It never writes to Dynamics: the registration it signs in with can only read.
//
// Two ways in:
//   scheduled()   the cron below, three times each weekday
//   POST /run     the office pressing Sync now in the admin app. It arrives
//                 through the site, carrying the staff member's own sign in,
//                 and the database decides whether they may (dynamics_sync_request).
//
// Cron trigger, set in wrangler.toml:  20 7,12,17 * * MON-FRI
//   (UTC, so 08:20, 13:20 and 18:20 in summer and an hour earlier in winter)
//
// Secrets (Settings, Variables and Secrets, type Secret). NEVER paste one into chat.
//   DYNAMICS_ORG_URL   https://<org>.crm11.dynamics.com  (no trailing slash; AuditFlow's value)
//   TENANT_ID          Microsoft Entra tenant (directory) id; AuditFlow's value
//   CLIENT_ID          the NEW read-only registration's application (client) id
//   CLIENT_SECRET      the NEW read-only registration's client secret VALUE
//   SUPABASE_URL       https://<ami project>.supabase.co, the same as the site's
//   SUPABASE_SECRET    AMI's service role key, the same as the site's
//   SUPABASE_ANON      AMI's publishable key, the same as the site's
// =============================================================================

const API_VERSION   = 'v9.2';
const PAGE_SIZE     = 500;
const MAX_PAGES     = 20;      // 10,000 rows a view. Each view should only hold the last 13 months.
const CHUNK         = 400;     // rows per call to the database
const FORMATTED     = '@OData.Community.Display.V1.FormattedValue';

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/run') {
      if (request.method !== 'POST')
        return json({ error: 'This address runs the sync, by POST, for signed in membership staff.' }, 405);
      return officeRun(request, env);
    }
    // Nothing else is served. No secret in an address can start a sync.
    return new Response('ami-dynamics-sync', { status: 200, headers: { 'Content-Type': 'text/plain' } });
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(runSync(env, null).catch(err => console.error('dynamics: scheduled run threw', err)));
  },
};

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

function configured(env){
  const missing = ['DYNAMICS_ORG_URL', 'TENANT_ID', 'CLIENT_ID', 'CLIENT_SECRET',
                   'SUPABASE_URL', 'SUPABASE_SECRET', 'SUPABASE_ANON'].filter(k => !env[k]);
  return missing;
}

// The office: the database says whether this person may, as them.
async function officeRun(request, env){
  const missing = configured(env);
  if (missing.length)
    return json({ error: 'The Dynamics sync is not set up yet. Missing on the Worker: ' + missing.join(', ') + '.',
                  at: 'bindings' }, 503);
  const m = /^Bearer\s+(.+)$/i.exec(request.headers.get('Authorization') || '');
  if (!m) return json({ error: 'Sign in to the admin app first.', at: 'auth' }, 401);

  const res = await rpc(env, 'dynamics_sync_request', {}, m[1]);
  const text = await res.text();
  let out = null; try { out = JSON.parse(text); } catch {}
  if (!res.ok) {
    const refused = res.status === 401 || res.status === 403 || (out && out.code === '42501');
    return json({ error: (out && out.message) || 'The database refused.', at: 'request' }, refused ? 403 : 409);
  }
  const requestId = typeof out === 'string' ? out : null;
  if (!requestId) return json({ error: 'The database gave no run to begin.', at: 'request' }, 500);
  const result = await runSync(env, requestId);
  // A run that happened answers 200 even when part of it failed: the failure is
  // in the body, in words, and a 5xx can reach the browser as no answer at all.
  return json(result, 200);
}

// -----------------------------------------------------------------------------
// One run
// -----------------------------------------------------------------------------
export async function runSync(env, requestId){
  const missing = configured(env);
  if (missing.length) {
    console.error('dynamics: not configured', missing);
    return { error: 'not configured: ' + missing.join(', ') };
  }

  const begun = await rpcJson(env, 'dynamics_run_begin', { p_request: requestId });
  if (begun.skip) return { skipped: begun.skip };
  const run = begun.run;
  const result = { feeds: {} };
  const errors = [];

  let token;
  try {
    token = await dynamicsToken(env);
  } catch (err) {
    errors.push('Signing in to Dynamics: ' + err.message);
  }

  if (token) {
    for (const feed of begun.feeds || []) {
      try {
        const view = await findView(env, token, feed.view);
        const rows = await readView(env, token, view);
        const fields = fieldNames(rows);
        let last = null;
        // An empty view is still reported, so its column names, none, are known.
        const chunks = rows.length ? chunk(rows, CHUNK) : [[]];
        const total = { read: 0, unreadable: 0, decided: {} };
        // The AMI members view (0054) has its own reader, and is read first
        // (the database lists it first) so attendance sees today's links.
        const members = feed.code === 'ami_members';
        for (const part of chunks) {
          last = await rpcJson(env, members ? 'dynamics_members_record' : 'dynamics_record', members
            ? { p_run: run, p_meta: { entity: view.entity, fields }, p_rows: part }
            : { p_run: run, p_feed: feed.code, p_meta: { entity: view.entity, fields }, p_rows: part });
          total.read += last.read || 0;
          total.unreadable += last.unreadable || 0;
          for (const [k, n] of Object.entries(last.decided || {})) total.decided[k] = (total.decided[k] || 0) + n;
        }
        // Whoever has left the members view is no longer a member. Only after a
        // whole, successful read, and the database refuses if it looks broken.
        if (members && last && last.ready) {
          const closed = await rpcJson(env, 'dynamics_members_close',
            { p_run: run, p_ids: rows.map(r => r._ami_id).filter(Boolean) });
          total.decided.switched_off = closed.switched_off || 0;
          if (closed.refused) { total.refused = closed.refused; errors.push(`${feed.view}: ${closed.refused}`); }
        }
        result.feeds[feed.code] = { ready: !!(last && last.ready), ...total, pages: view.pages };
      } catch (err) {
        result.feeds[feed.code] = { error: err.message };
        errors.push(`${feed.view}: ${err.message}`);
      }
    }
  }

  const error = errors.length ? errors.join(' | ') : null;
  try {
    await rpcJson(env, 'dynamics_run_finish', { p_run: run, p_result: result, p_error: error });
  } catch (err) {
    console.error('dynamics: finish threw', err);
  }
  return { run, ...result, error };
}

function chunk(a, n){ const out = []; for (let i = 0; i < a.length; i += n) out.push(a.slice(i, i + n)); return out; }

// The names of the columns, for the office to choose from. Annotations are not
// columns, and a value is never sent here.
export function fieldNames(rows){
  const seen = new Set();
  for (const r of rows.slice(0, 50))
    for (const k of Object.keys(r)) if (!k.includes('@') && k !== '_ami_id') seen.add(k);
  return [...seen].sort();
}

// -----------------------------------------------------------------------------
// Dynamics
// -----------------------------------------------------------------------------
async function dynamicsToken(env){
  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: env.CLIENT_ID,
    client_secret: env.CLIENT_SECRET,
    scope: `${env.DYNAMICS_ORG_URL}/.default`,
  });
  const res = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(env.TENANT_ID)}/oauth2/v2.0/token`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || !out.access_token)
    throw new Error(`Microsoft refused (${res.status}${out.error ? ', ' + out.error : ''}). Check CLIENT_ID, CLIENT_SECRET and TENANT_ID.`);
  return out.access_token;
}

const dynHeaders = (token, extra = {}) => ({
  Authorization: `Bearer ${token}`, Accept: 'application/json',
  'OData-MaxVersion': '4.0', 'OData-Version': '4.0', ...extra });

async function dynGet(env, token, path, prefer){
  const url = path.startsWith('https://') ? path : `${env.DYNAMICS_ORG_URL}/api/data/${API_VERSION}/${path}`;
  const res = await fetch(url, { headers: dynHeaders(token, prefer ? { Prefer: prefer } : {}) });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    if (res.status === 401 || res.status === 403) {
      // Dynamics names the missing privilege, such as prvReadcore_course, and
      // that is the one thing the person fixing the role needs.
      let said = '';
      try { said = (JSON.parse(text).error || {}).message || ''; } catch {}
      const priv = (said.match(/prv[A-Za-z_]+/) || [])[0];
      throw new Error(`Dynamics refused (${res.status}).`
        + (priv ? ` The AMI read only role is missing ${priv}: give it Read, Organization, on that table.`
                : ' The app registration needs an application user in Dynamics with the AMI read only role.')
        + (said ? ` Dynamics said: ${said.slice(0, 300)}` : ''));
    }
    throw new Error(`Dynamics answered ${res.status}: ${text.slice(0, 200)}`);
  }
  return res.json();
}

// A system view, by its exact name, and the table it reads.
async function findView(env, token, name){
  const filter = encodeURIComponent(`name eq '${String(name).replace(/'/g, "''")}'`);
  const out = await dynGet(env, token, `savedqueries?$select=savedqueryid,name,returnedtypecode&$filter=${filter}`);
  const rows = out.value || [];
  if (!rows.length)
    throw new Error(`No system view is called "${name}". It must be a system view, not a personal one, with exactly that name.`);
  if (rows.length > 1)
    throw new Error(`${rows.length} system views are called "${name}". Rename the spare ones.`);
  const entity = rows[0].returnedtypecode;
  const def = await dynGet(env, token,
    `EntityDefinitions(LogicalName='${encodeURIComponent(entity)}')?$select=EntitySetName,PrimaryIdAttribute`);
  return { id: rows[0].savedqueryid, entity, set: def.EntitySetName, pk: def.PrimaryIdAttribute };
}

// Every row of the view, each with its own id added as _ami_id. Formatted
// values (the words for a lookup or a choice) are kept; other annotations are
// dropped, being Dynamics' bookkeeping and nothing a person would read.
async function readView(env, token, view){
  let next = `${view.set}?savedQuery=${view.id}`;
  const rows = [];
  view.pages = 0;
  while (next && view.pages < MAX_PAGES) {
    view.pages++;
    const out = await dynGet(env, token, next,
      `odata.maxpagesize=${PAGE_SIZE},odata.include-annotations="OData.Community.Display.V1.FormattedValue"`);
    for (const r of out.value || []) rows.push(tidy(r, view.pk));
    next = out['@odata.nextLink'] || null;
  }
  if (next) throw new Error(`The view holds more than ${MAX_PAGES * PAGE_SIZE} rows. Limit it to the last 13 months.`);
  return rows;
}

export function tidy(r, pk){
  const out = {};
  for (const [k, v] of Object.entries(r)) {
    if (k.startsWith('@')) continue;
    if (k.includes('@') && !k.endsWith(FORMATTED)) continue;
    out[k] = v;
  }
  out._ami_id = r[pk] != null ? String(r[pk]) : null;
  return out;
}

// -----------------------------------------------------------------------------
// AMI's database
// -----------------------------------------------------------------------------
function rpc(env, fn, args, userToken){
  return fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: userToken ? env.SUPABASE_ANON : env.SUPABASE_SECRET,
      Authorization: `Bearer ${userToken || env.SUPABASE_SECRET}`,
    },
    body: JSON.stringify(args),
  });
}

async function rpcJson(env, fn, args){
  const res = await rpc(env, fn, args);
  const text = await res.text();
  let out = null; try { out = JSON.parse(text); } catch {}
  if (!res.ok) throw new Error(`The database refused ${fn}: ${(out && out.message) || text.slice(0, 200)}`);
  return out || {};
}
