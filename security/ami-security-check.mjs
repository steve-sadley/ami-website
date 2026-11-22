// =============================================================================
// AMI security check: an attacker suite, and an AI agent that looks further
//
// Run from your own computer against STAGING (or later, live):
//
//   node ami-security-check.mjs --config security.config.json
//   node ami-security-check.mjs --config security.config.json --agent
//   node ami-security-check.mjs --config security.config.json --compare security-report-<earlier>.json
//   node ami-security-check.mjs --config security.config.json --sign-in      (just tries the test accounts)
//
// Needs Node 18 or later. Nothing to install.
//
// PART 1, the attacker suite. A fixed list of checks, the same every run, so a
// run before loading the members and a run after can be compared line by line.
// It acts as four people in turn: nobody signed in; a forger with a made up
// sign in; a signed in member; a member of staff. It tries to read what they
// should not, write what they should not, become what they are not, and reach
// files and endpoints they should not, and it reads the site's own security
// settings. Every check says pass, fail, or review (worth a person's look).
//
// PART 2, the agent (--agent). Claude reads Part 1's results and then probes on
// its own, with READ-ONLY requests (GET, HEAD, OPTIONS) to the addresses in the
// config and nowhere else. It never sees a sign in token: it asks to send a
// request "as member" and this program adds the token. Email addresses and
// tokens in what comes back are blanked before Claude sees them. It writes up
// what it finds, and describes any write test it thinks worth trying for a
// person to do. It cannot change or delete anything, so it is safe after the
// real members are loaded.
//
// WHAT IT WILL NOT DO, by design: send a real contact form or application,
// sign anybody up, create or delete real records, or send load. Write attempts
// are aimed at rows that do not exist, so even a hole it finds changes nothing.
// =============================================================================

import fs from 'fs';
import crypto from 'crypto';

const NOBODY_ID = '00000000-0000-4000-8000-00000000dead';

// -----------------------------------------------------------------------------
// What the database is meant to look like (from the migrations, 0001 to 0066)
// -----------------------------------------------------------------------------
export const TABLES = `admin_settings app_roles application_documents application_events application_tokens audit_log
auth_events banned_words bootstrap_super_users card_issues consents cpd_activity_types cpd_adjustments cpd_ai_reviews
cpd_certificate_readings cpd_entries cpd_evidence cpd_evidence_uploads cpd_feed_links cpd_learning_attempts
cpd_learning_items cpd_monthly_log legacy_register cpd_reminder_log cpd_requirements cpd_review_guides cpd_year_summaries
dynamics_attendance dynamics_courses dynamics_feeds dynamics_grade_map dynamics_members_seen dynamics_runs
dynamics_sessions email_campaigns email_events email_outbox email_sends email_templates event_bookings events
feature_usage forum_categories forum_endorsements forum_post_revisions forum_posts forum_reports forum_subscriptions
forum_threads grade_fees guidance_documents hero_statements media_library member_preferences members
membership_applications membership_grades membership_years news_articles non_working_days organisation_slugs
organisations page_blocks people register_slugs role_grants suppression_list system_settings videos wallet_passes
wallet_registrations zoom_attendance zoom_sessions
email_change_requests interview_slots interview_invitations interview_bookings`.split(/\s+/).filter(Boolean);

export const VIEWS = `admin_application_documents admin_application_queue admin_campaigns admin_communication_log
admin_cpd_certificate_checks admin_cpd_evidence admin_cpd_feed_queue admin_cpd_queue admin_cpd_reminders
admin_digest_pending admin_dynamics_courses admin_dynamics_member_check admin_dynamics_sessions admin_email_queue
admin_held_posts admin_media_library admin_member_list cpd_feed_sessions forum_category_list forum_post_list
forum_thread_list my_card my_cpd my_cpd_summary my_learning my_posts my_profile my_recent public_article
public_content public_cpd_activities public_fees public_grades public_hero public_numbers public_page public_profile
public_register
admin_email_change_requests admin_member_changes admin_interview_slots public_guidance`.split(/\s+/).filter(Boolean);

// Meant to be readable by anybody, signed in or not.
export const PUBLIC_RELATIONS = ['public_article', 'public_content', 'public_cpd_activities', 'public_fees',
  'public_grades', 'public_hero', 'public_numbers', 'public_page', 'public_profile', 'public_register', 'public_guidance'];
// Meant to be callable by anybody.
export const PUBLIC_RPCS = ['fallback_picture', 'preferences_by_token', 'unsubscribe_all_by_token'];
// Shared with every signed in member (content, the forum, the scheme's own lists).
export const MEMBER_SHARED = ['forum_categories', 'forum_threads', 'forum_posts', 'forum_endorsements',
  'forum_category_list', 'forum_thread_list', 'forum_post_list', 'cpd_activity_types', 'membership_grades',
  'grade_fees', 'cpd_requirements', 'cpd_learning_items', 'news_articles', 'guidance_documents', 'events', 'videos',
  'page_blocks', 'hero_statements', 'media_library', 'organisations', 'organisation_slugs', 'register_slugs',
  'non_working_days', 'banned_words', 'cpd_feed_sessions', 'app_roles', ...PUBLIC_RELATIONS];
// Things a page must never show the public, whatever the view.
// storage_path since 0065: a document's address in the private bucket is the
// Worker's business, never a visitor's.
const PRIVATE_COLUMNS = ['email', 'alt_email', 'mobile', 'home_address', 'business_address', 'auth_user_id',
  'dynamics_contact_id', 'token', 'secret', 'password', 'raw', 'ip_address', 'storage_path'];
// Never readable by a member, not even rows that look like theirs: the office's
// own lists. Any row coming back is a failure, not something to review.
export const STAFF_ONLY = ['interview_slots', 'interview_invitations', 'interview_bookings'];
// A member's own actions (0062, 0065). Somebody signed out must be refused.
export const MEMBER_RPCS = ['request_my_email_change', 'withdraw_my_email_change', 'set_my_preferred_email',
  'can_read_member_documents'];
// Staff only. A member calling any of these must be refused.
export const STAFF_RPCS = ['review_cpd', 'take_application', 'refuse_application', 'send_campaign',
  'send_campaign_test', 'campaign_recipients_preview', 'campaign_count', 'hide_post', 'release_post', 'feed_link',
  'feed_dismiss', 'zoom_import_begin', 'ai_review_begin', 'ai_certificate_begin', 'dynamics_course_decide',
  'dynamics_grade_map_set', 'dynamics_members_load', 'next_membership_number', 'dynamics_sync_request', 'cpd_monthly_preview',
  'run_content_digest', 'run_cpd_reminders', 'set_member_active', 'member_activation', 'update_member_details',
  'email_change_decide', 'interview_invite', 'interview_office_cancel'];
// Never callable from a browser at all: the service role's alone.
export const SERVICE_RPCS = ['zoom_record_attendance', 'ai_review_record', 'ai_certificate_record',
  'cpd_evidence_record', 'dynamics_run_begin', 'dynamics_record', 'dynamics_run_finish', 'dynamics_members_record',
  'dynamics_members_close', 'log_direct_email', 'claim_email_batch', 'mark_email_sent', 'submit_application',
  'interview_page', 'interview_hold', 'interview_confirm', 'interview_release', 'interview_cancel', 'guidance_file'];
// The right named arguments, with harmless values, for the functions added
// since version 8. Called with an empty body, a function that takes arguments
// answers "no such function" whoever is asking, which proves nothing about who
// may call it. With its arguments the call reaches the permission check.
export const RPC_ARGS = {
  request_my_email_change: { p_work: 'zz-security-check@test.invalid', p_private: null },
  set_my_preferred_email: { p_choice: 'work' },
  email_change_decide: { p_id: NOBODY_ID, p_action: 'reject', p_note: null },
  interview_invite: { p_application_id: NOBODY_ID },
  interview_office_cancel: { p_booking: NOBODY_ID, p_reason: 'security check' },
  interview_page: { p_token: 'zz-security-check' },
  interview_hold: { p_token: 'zz-security-check', p_slot: NOBODY_ID },
  interview_confirm: { p_booking: NOBODY_ID, p_event_id: 'zz', p_join_url: 'https://example.invalid' },
  interview_release: { p_booking: NOBODY_ID, p_reason: 'security check' },
  interview_cancel: { p_token: 'zz-security-check' },
  guidance_file: { p_slug: 'zz-security-check' },
};
const argsFor = f => JSON.stringify(RPC_ARGS[f] || {});

const NOBODY = '00000000-0000-4000-8000-00000000dead';
const SECRET_PATTERNS = [
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, 'a private key'],
  [/sb_secret_[A-Za-z0-9_-]{10,}/, 'a Supabase secret key'],
  [/sk-ant-[A-Za-z0-9_-]{20,}/, 'an Anthropic key'],
  [/\[core\][\s\S]{0,200}repositoryformatversion/, 'a git repository'],
  [/(SUPABASE_SECRET|SERVICE_ROLE_KEY|CLIENT_SECRET|ZOOM_CLIENT_SECRET|SMTP2GO_KEY)\s*[=:]\s*['"]?[A-Za-z0-9._-]{12,}/, 'a secret in a config file'],
];

// -----------------------------------------------------------------------------
// Results
// -----------------------------------------------------------------------------
export function makeRun(config, fetchImpl = globalThis.fetch) {
  const results = [];
  let requests = 0;
  const hosts = new Set([config.siteUrl, config.adminUrl, config.supabaseUrl, config.syncUrl]
    .filter(Boolean).map(u => new URL(u).host));

  const rec = (area, check, verdict, detail = '') => results.push({ area, check, verdict, detail: String(detail).slice(0, 400) });

  async function http(url, opts = {}) {
    const u = new URL(url);
    if (!hosts.has(u.host)) throw new Error('Refused: ' + u.host + ' is not one of the configured addresses.');
    requests++;
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), opts.timeout || 15000);
    try {
      const res = await fetchImpl(url, { ...opts, redirect: 'manual', signal: ctl.signal });
      const text = opts.method === 'HEAD' ? '' : await res.text().catch(() => '');
      let json = null; try { json = JSON.parse(text); } catch {}
      return { status: res.status, headers: res.headers, text, json };
    } catch (e) {
      return { status: 0, headers: new Headers(), text: String(e.message || e), json: null };
    } finally { clearTimeout(t); }
  }

  const sb = config.supabaseUrl ? config.supabaseUrl.replace(/\/$/, '') : '';
  const authHeaders = who => {
    const h = { apikey: config.supabaseAnon };
    if (who === 'member' && config.memberToken) h.Authorization = 'Bearer ' + config.memberToken;
    if (who === 'staff' && config.staffToken) h.Authorization = 'Bearer ' + config.staffToken;
    if (who && who.startsWith('forged:')) h.Authorization = 'Bearer ' + who.slice(7);
    return h;
  };
  const refused = r => r.status === 401 || r.status === 403
    || (r.json && (r.json.code === '42501' || r.json.code === 'PGRST301' || r.json.code === 'PGRST302'));
  const notFound = r => r.status === 404 || (r.json && (r.json.code === 'PGRST202' || r.json.code === 'PGRST205' || r.json.code === '42P01'));
  // Supabase's sign in answers say why in error_code and msg (or error and
  // error_description), not in code and message, so those are read too.
  const why = r => {
    const j = r.json || {};
    const code = j.error_code || (typeof j.code === 'string' ? j.code : '') || j.error || '';
    const msg = j.message || j.msg || j.error_description || (r.status === 0 ? r.text : '');
    return `${r.status}${code ? ' ' + code : ''}${msg ? ': ' + msg : ''}`;
  };

  return { results, rec, http, sb, authHeaders, refused, notFound, why, get requests() { return requests; }, config };
}

// -----------------------------------------------------------------------------
// The checks
// -----------------------------------------------------------------------------
async function checkReach(R) {
  for (const [name, url] of [['site', R.config.siteUrl], ['admin app', R.config.adminUrl],
                             ['database', R.config.supabaseUrl && R.sb + '/rest/v1/']]) {
    if (!url) continue;
    const r = await R.http(url, { headers: name === 'database' ? R.authHeaders() : {} });
    R.rec('reach', `the ${name} answers`, r.status ? 'pass' : 'fail', `${url} ${R.why(r)}`);
  }
}

// The admin app sits behind Cloudflare Access: strangers get a redirect to the
// Access sign in page, not the app. That is a pass in itself, and the app's own
// headers cannot be read from outside it, so they are not marked as failures.
async function behindAccess(R, base) {
  const r = await R.http(base.replace(/\/$/, '') + '/');
  const loc = r.headers.get('location') || '';
  return (r.status === 302 || r.status === 303) && /cloudflareaccess\.com/.test(loc);
}

async function checkHeaders(R) {
  for (const [name, base, paths] of [['site', R.config.siteUrl, ['/', '/login.html', '/me.html', '/cpd.html']],
                                     ['admin app', R.config.adminUrl, ['/']]]) {
    if (!base) continue;
    if (name === 'admin app' && await behindAccess(R, base)) {
      R.rec('headers', 'the admin app is behind Cloudflare Access, so strangers never reach it', 'pass',
        'Its own headers are checked by the admin app\'s browser tests instead.');
      continue;
    }
    for (const p of paths) {
      const r = await R.http(base.replace(/\/$/, '') + p);
      const h = k => r.headers.get(k) || '';
      const csp = h('content-security-policy');
      const where = `${name} ${p}`;
      R.rec('headers', `${where}: has a Content-Security-Policy`, csp ? 'pass' : 'fail', csp.slice(0, 120));
      if (csp) {
        const script = (csp.match(/script-src([^;]*)/) || [, ''])[1];
        R.rec('headers', `${where}: scripts cannot run inline or from eval`,
          /'unsafe-inline'|'unsafe-eval'/.test(script) ? 'fail' : 'pass', 'script-src' + script);
        R.rec('headers', `${where}: cannot be framed by another site`,
          /frame-ancestors\s+('none'|'self')/.test(csp) || /deny|sameorigin/i.test(h('x-frame-options')) ? 'pass' : 'fail');
      }
      const hsts = (h('strict-transport-security').match(/max-age=(\d+)/) || [, 0])[1];
      R.rec('headers', `${where}: browsers are told to use HTTPS only`, +hsts >= 15552000 ? 'pass' : 'review',
        h('strict-transport-security') || 'no Strict-Transport-Security');
      R.rec('headers', `${where}: no content type sniffing`, /nosniff/i.test(h('x-content-type-options')) ? 'pass' : 'fail');
      R.rec('headers', `${where}: a referrer policy`, h('referrer-policy') ? 'pass' : 'review');
      R.rec('headers', `${where}: no server version given away`, /\d/.test(h('server') + h('x-powered-by')) ? 'review' : 'pass',
        h('server') + ' ' + h('x-powered-by'));
    }
  }
}

async function checkPaths(R) {
  const paths = ['/.git/config', '/.git/HEAD', '/.env', '/.env.local', '/_worker.js', '/_headers', '/wrangler.toml',
    '/package.json', '/db/', '/supabase/', '/README.md', '/backup.sql', '/dump.sql', '/.DS_Store', '/admin/',
    '/server-status', '/phpinfo.php', '/wp-admin/', '/.well-known/security.txt'];
  for (const [name, base] of [['site', R.config.siteUrl], ['admin app', R.config.adminUrl]]) {
    if (!base) continue;
    for (const p of paths) {
      const r = await R.http(base.replace(/\/$/, '') + p);
      const hit = SECRET_PATTERNS.find(([re]) => re.test(r.text));
      if (p === '/.well-known/security.txt') {
        // Behind Cloudflare Access nobody outside reaches it; the site's own
        // security.txt is the one people find.
        const gated = r.status >= 300 && r.status < 400 && /cloudflareaccess\.com/.test(r.headers.get('location') || '');
        const good = r.status === 200 && /^Contact:/mi.test(r.text) && /^Expires:/mi.test(r.text);
        R.rec('exposure', `${name}: says how to report a vulnerability (security.txt)`, good || gated ? 'pass' : 'review',
          good ? r.text.split('\n').find(l => /^Contact:/i.test(l)) : gated ? 'behind Cloudflare Access, so the site\'s one is what people find'
            : 'Optional, and good practice: a page saying who to tell about a security problem, with Contact and Expires lines.');
        continue;
      }
      R.rec('exposure', `${name} ${p} gives nothing away`, hit ? 'fail' : (r.status === 200 && /_worker\.js|_headers|wrangler/.test(p) && r.text.length > 50 ? 'fail'
        : r.status === 200 && /README\.md|package\.json/.test(p) && r.text.length > 50 ? 'review' : 'pass'),
        hit ? 'Contains ' + hit[1] : `${r.status}`);
    }
  }
}

function decodeJwt(t) {
  try { return JSON.parse(Buffer.from(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString()); }
  catch { return null; }
}

async function checkPageCode(R) {
  const pages = [];
  if (R.config.siteUrl) for (const p of ['/', '/login.html', '/me.html', '/cpd.html', '/apply.html', '/contact.html'])
    pages.push(R.config.siteUrl.replace(/\/$/, '') + p);
  if (R.config.adminUrl) pages.push(R.config.adminUrl.replace(/\/$/, '') + '/');
  const seen = new Set();
  for (const url of pages) {
    const r = await R.http(url);
    const scripts = [...r.text.matchAll(/<script[^>]+src="([^"]+)"/g)].map(m => new URL(m[1], url).href)
      .filter(s => { try { return new URL(s).host === new URL(url).host; } catch { return false; } });
    for (const s of [url, ...scripts]) {
      if (seen.has(s)) continue;
      seen.add(s);
      const body = s === url ? r.text : (await R.http(s)).text;
      const hit = SECRET_PATTERNS.find(([re]) => re.test(body));
      const jwts = [...body.matchAll(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g)].map(m => decodeJwt(m[0]));
      const service = jwts.find(j => j && j.role === 'service_role');
      R.rec('exposure', `no secret in the code of ${new URL(s).pathname}`, hit || service ? 'fail' : 'pass',
        hit ? hit[1] : service ? 'a service_role key' : '');
    }
  }
}

async function checkDatabaseAnon(R) {
  if (!R.sb) return;
  // What the database tells anybody who asks it about itself.
  const spec = await R.http(R.sb + '/rest/v1/', { headers: R.authHeaders() });
  const paths = spec.json && spec.json.paths ? Object.keys(spec.json.paths) : [];
  const listed = paths.filter(p => !p.startsWith('/rpc/') && p !== '/').map(p => p.slice(1));
  const rpcs = paths.filter(p => p.startsWith('/rpc/')).map(p => p.slice(5));
  if (paths.length) {
    const extraRel = listed.filter(t => !PUBLIC_RELATIONS.includes(t));
    R.rec('database, signed out', 'the tables and views anybody can see are only the public ones',
      extraRel.length ? 'review' : 'pass', extraRel.length ? 'Also listed: ' + extraRel.join(', ') : listed.join(', '));
    const extraRpc = rpcs.filter(f => !PUBLIC_RPCS.includes(f));
    R.rec('database, signed out', 'the functions anybody can call are only the public ones',
      extraRpc.length ? 'review' : 'pass', extraRpc.length ? 'Also callable: ' + extraRpc.join(', ') : rpcs.join(', '));
  } else {
    R.rec('database, signed out', 'the database does not describe itself to strangers', 'pass', R.why(spec));
  }

  for (const rel of [...new Set([...TABLES, ...VIEWS, ...listed])]) {
    const r = await R.http(`${R.sb}/rest/v1/${rel}?select=*&limit=5`, { headers: R.authHeaders() });
    const rows = Array.isArray(r.json) ? r.json : null;
    if (PUBLIC_RELATIONS.includes(rel)) {
      const bad = rows && rows.length ? Object.keys(rows[0]).filter(c => PRIVATE_COLUMNS.includes(c)) : [];
      R.rec('database, signed out', `public ${rel} shows nothing private`, bad.length ? 'fail' : 'pass',
        bad.length ? 'Shows ' + bad.join(', ') : `${rows ? rows.length : 0} rows, columns fine`);
      continue;
    }
    R.rec('database, signed out', `cannot read ${rel}`,
      rows && rows.length ? 'fail' : (rows || R.refused(r) || R.notFound(r)) ? 'pass' : 'review',
      rows && rows.length ? `${rows.length} rows came back` : R.why(r));
  }

  for (const t of TABLES) {
    const r = await R.http(`${R.sb}/rest/v1/${t}`, {
      method: 'POST', headers: { ...R.authHeaders(), 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({}) });
    R.rec('database, signed out', `cannot write to ${t}`,
      r.status >= 200 && r.status < 300 ? 'fail' : (R.refused(r) || R.notFound(r)) ? 'pass' : 'review',
      R.refused(r) || R.notFound(r) ? R.why(r) : 'The write reached the table\'s own checks: ' + R.why(r));
  }

  for (const f of [...STAFF_RPCS, ...SERVICE_RPCS, ...MEMBER_RPCS]) {
    const r = await R.http(`${R.sb}/rest/v1/rpc/${f}`, {
      method: 'POST', headers: { ...R.authHeaders(), 'Content-Type': 'application/json' }, body: argsFor(f) });
    R.rec('database, signed out', `cannot call ${f}`,
      r.status >= 200 && r.status < 300 ? 'fail' : (R.refused(r) || R.notFound(r)) ? 'pass' : 'review', R.why(r));
  }
}

function forged(alg) {
  const b = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const head = b({ alg, typ: 'JWT' });
  const body = b({ role: 'service_role', iss: 'supabase', sub: NOBODY, exp: Math.floor(Date.now() / 1000) + 3600 });
  const sig = alg === 'none' ? '' : crypto.createHmac('sha256', 'super-secret-jwt-token-with-at-least-32-characters-long')
    .update(head + '.' + body).digest('base64url');
  return `${head}.${body}.${sig}`;
}

async function checkForgery(R) {
  if (!R.sb) return;
  for (const [name, tok] of [['unsigned', forged('none')], ['signed with the well known default secret', forged('HS256')]]) {
    const r = await R.http(`${R.sb}/rest/v1/audit_log?select=id&limit=1`, { headers: R.authHeaders('forged:' + tok) });
    const rows = Array.isArray(r.json) ? r.json : null;
    R.rec('forgery', `a made up service sign in (${name}) is refused`, rows && rows.length ? 'fail' : 'pass', R.why(r));
  }
  if (R.config.memberToken) {
    const parts = R.config.memberToken.split('.');
    const p = decodeJwt(R.config.memberToken) || {};
    const tampered = parts[0] + '.' + Buffer.from(JSON.stringify({ ...p, role: 'service_role' })).toString('base64url') + '.' + parts[2];
    const r = await R.http(`${R.sb}/rest/v1/audit_log?select=id&limit=1`, { headers: R.authHeaders('forged:' + tampered) });
    const rows = Array.isArray(r.json) ? r.json : null;
    R.rec('forgery', 'a real member sign in, edited to say service role, is refused', rows && rows.length ? 'fail' : 'pass', R.why(r));
  }
}

async function checkStorage(R) {
  if (!R.sb) return;
  const buckets = await R.http(`${R.sb}/storage/v1/bucket`, { headers: R.authHeaders() });
  const list = Array.isArray(buckets.json) ? buckets.json : [];
  R.rec('files', 'the list of file buckets is not given to strangers', list.length ? 'review' : 'pass',
    list.length ? list.map(b => b.id + (b.public ? ' (public)' : '')).join(', ') : R.why(buckets));
  for (const b of ['member-photos', 'cpd-evidence', 'content-media']) {
    const r = await R.http(`${R.sb}/storage/v1/object/list/${b}`, {
      method: 'POST', headers: { ...R.authHeaders(), 'Content-Type': 'application/json' },
      body: JSON.stringify({ prefix: '', limit: 10 }) });
    const files = Array.isArray(r.json) ? r.json : [];
    R.rec('files', `nobody signed out can list ${b}`, files.length ? 'fail' : 'pass', files.length ? `${files.length} entries` : R.why(r));
    const pub = await R.http(`${R.sb}/storage/v1/object/public/${b}/anything.jpg`);
    R.rec('files', `${b} is not a public bucket`, pub.status === 200 ? 'fail' : 'pass', R.why(pub));
  }
  const up = await R.http(`${R.sb}/storage/v1/object/public-media/zz-security-check-${Date.now()}.txt`, {
    method: 'POST', headers: { ...R.authHeaders(), 'Content-Type': 'text/plain' }, body: 'security check' });
  R.rec('files', 'nobody signed out can upload to the public pictures', up.status >= 200 && up.status < 300 ? 'fail' : 'pass', R.why(up));
}

async function checkEndpoints(R) {
  const site = R.config.siteUrl && R.config.siteUrl.replace(/\/$/, '');
  if (!site) return;
  const evil = 'https://evil.example';
  const doors = [
    ['/api/zoom/attendance', 'POST', { session: NOBODY }],
    ['/api/cpd/ai-review', 'POST', {}],
    ['/api/cpd/evidence', 'POST', null],
    ['/api/dynamics/sync-now', 'POST', null],
    ['/api/photo', 'POST', null],
  ];
  for (const [p, method, body] of doors) {
    const r = await R.http(site + p, { method, headers: { 'Content-Type': 'application/json', Origin: evil },
                                       body: body ? JSON.stringify(body) : undefined });
    R.rec('endpoints', `${p} refuses somebody not signed in`, r.status === 401 || r.status === 403 || r.status === 503 ? 'pass' : 'fail', R.why(r));
    const acao = r.headers.get('access-control-allow-origin') || '';
    R.rec('endpoints', `${p} does not let another website read its answer`, acao === '*' || acao === evil ? 'fail' : 'pass', acao || 'no Allow-Origin');
    const r2 = await R.http(site + p, { method, headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + forged('HS256') },
                                        body: body ? JSON.stringify(body) : undefined });
    R.rec('endpoints', `${p} refuses a made up sign in`, r2.status === 401 || r2.status === 403 || r2.status === 503 ? 'pass' : 'fail', R.why(r2));
  }
  // Forms: only answers that must be refused. Nothing that could be sent on.
  for (const [p, body, what] of [
    ['/api/contact', { name: '', email: 'not-an-address', message: '' }, 'an empty enquiry'],
    ['/api/contact', { name: '<script>alert(1)</script>', email: 'x', message: 'x'.repeat(200000) }, 'an enormous enquiry with markup'],
    ['/api/apply', { email: 'not-an-address' }, 'an application with nothing in it'],
  ]) {
    const r = await R.http(site + p, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    R.rec('endpoints', `${p} refuses ${what}`, r.status >= 400 && r.status < 500 ? 'pass' : r.status >= 500 ? 'review' : 'fail', R.why(r));
  }
  const drain = await R.http(site + '/api/mail/drain', { method: 'POST' });
  R.rec('endpoints', '/api/mail/drain refuses somebody not signed in', drain.status === 401 ? 'pass' : 'fail', R.why(drain));
  const drain2 = await R.http(site + '/api/mail/drain', { method: 'POST', headers: { 'X-Drain-Key': 'guess' } });
  R.rec('endpoints', '/api/mail/drain refuses a guessed key', drain2.status === 401 ? 'pass' : 'fail', R.why(drain2));
  if (R.config.memberToken) {
    const d3 = await R.http(site + '/api/mail/drain', { method: 'POST', headers: { Authorization: 'Bearer ' + R.config.memberToken } });
    R.rec('endpoints', '/api/mail/drain refuses a member who is not staff', d3.status === 401 ? 'pass' : 'fail', R.why(d3));
  }
  await checkInterviewDoors(R, site, evil);
  await checkGuidanceDoor(R, site);
  const status = await R.http(site + '/api/pass/status');
  const hit = SECRET_PATTERNS.find(([re]) => re.test(status.text));
  // Only true or false values, saying which wallets are set up, is what it is
  // meant to give; anything more is for a person to look at.
  const onlyFlags = status.json && typeof status.json === 'object' && !Array.isArray(status.json)
    && Object.values(status.json).every(v => typeof v === 'boolean');
  R.rec('endpoints', '/api/pass/status gives no secret away', hit ? 'fail' : status.status === 200 && !onlyFlags ? 'review' : 'pass',
    hit ? hit[1] : status.status === 200 ? (onlyFlags ? 'only says which wallets are set up: ' : 'Answers anybody with: ') + status.text.slice(0, 200) : R.why(status));
  if (R.config.syncUrl) {
    const s = R.config.syncUrl.replace(/\/$/, '');
    const a = await R.http(s + '/run');
    R.rec('endpoints', 'the Dynamics sync cannot be started from an address', a.status === 405 ? 'pass' : 'fail', R.why(a));
    const b = await R.http(s + '/run', { method: 'POST' });
    R.rec('endpoints', 'the Dynamics sync refuses somebody not signed in', b.status === 401 || b.status === 503 ? 'pass' : 'fail', R.why(b));
    const c = await R.http(s + '/run', { method: 'POST', headers: { Authorization: 'Bearer ' + forged('HS256') } });
    R.rec('endpoints', 'the Dynamics sync refuses a made up sign in', c.status === 403 || c.status === 401 || c.status === 503 ? 'pass' : 'fail', R.why(c));
  }
}

// The professional interview (0064). The applicant's three doors carry only
// the token from their invitation; the office's carries a staff sign in.
async function checkInterviewDoors(R, site, evil) {
  const madeUp = 'zz-security-check-' + crypto.randomBytes(16).toString('hex');
  for (const [door, body] of [['slots', { token: madeUp }], ['book', { token: madeUp, slot: NOBODY }], ['cancel', { token: madeUp }]]) {
    const r = await R.http(`${site}/api/interview/${door}`, { method: 'POST',
      headers: { 'Content-Type': 'application/json', Origin: evil }, body: JSON.stringify(body) });
    const leaked = r.json && (r.json.slots || r.json.given_name || r.json.booking || r.json.join_url);
    R.rec('endpoints', `/api/interview/${door} refuses a made up invitation link`,
      leaked || (r.status >= 200 && r.status < 300) ? 'fail' : (r.status >= 400 && r.status < 500) || r.status === 503 ? 'pass' : 'review',
      leaked ? 'It answered with booking details' : R.why(r));
    const acao = r.headers.get('access-control-allow-origin') || '';
    R.rec('endpoints', `/api/interview/${door} does not let another website read its answer`,
      acao === '*' || acao === evil ? 'fail' : 'pass', acao || 'no Allow-Origin');
  }
  const get = await R.http(`${site}/api/interview/slots`);
  R.rec('endpoints', '/api/interview/slots cannot be opened as an address', get.status === 405 ? 'pass' : 'fail', R.why(get));
  const other = await R.http(`${site}/api/interview/zz-security-check`, { method: 'POST' });
  R.rec('endpoints', '/api/interview/ answers only its four doors', other.status === 404 ? 'pass' : 'fail', R.why(other));
  const oc = { method: 'POST', body: JSON.stringify({ booking: NOBODY, reason: 'security check' }) };
  const a = await R.http(`${site}/api/interview/office-cancel`, { ...oc, headers: { 'Content-Type': 'application/json', Origin: evil } });
  R.rec('endpoints', '/api/interview/office-cancel refuses somebody not signed in',
    a.status === 401 || a.status === 403 || a.status === 503 ? 'pass' : 'fail', R.why(a));
  const aAcao = a.headers.get('access-control-allow-origin') || '';
  R.rec('endpoints', '/api/interview/office-cancel does not let another website read its answer',
    aAcao === '*' || aAcao === evil ? 'fail' : 'pass', aAcao || 'no Allow-Origin');
  const b = await R.http(`${site}/api/interview/office-cancel`, { ...oc,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + forged('HS256') } });
  R.rec('endpoints', '/api/interview/office-cancel refuses a made up sign in',
    b.status === 401 || b.status === 403 || b.status === 503 ? 'pass' : 'fail', R.why(b));
  if (R.config.memberToken) {
    const c = await R.http(`${site}/api/interview/office-cancel`, { ...oc,
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + R.config.memberToken } });
    R.rec('endpoints', '/api/interview/office-cancel refuses a member who is not staff',
      c.status >= 200 && c.status < 300 ? 'fail' : c.status >= 400 && c.status < 500 ? 'pass' : 'review', R.why(c));
  }
}

// Guidance documents (0065), served by the Worker. A members only one must
// want a current member; nothing may be reached by a made up or crafted name.
async function checkGuidanceDoor(R, site) {
  for (const [slug, what] of [['zz-security-check-no-such-document', 'a document that does not exist'],
                              ['..%2F..%2Fsecurity.txt', 'a name that climbs out of its folder'],
                              ['documents%2Fanything.pdf', 'a storage address in place of a name']]) {
    const r = await R.http(`${site}/api/guidance/${slug}`);
    R.rec('endpoints', `/api/guidance refuses ${what}`, r.status === 404 ? 'pass' : r.status >= 200 && r.status < 300 ? 'fail' : 'review', R.why(r));
  }
  const post = await R.http(`${site}/api/guidance/zz-security-check`, { method: 'POST' });
  R.rec('endpoints', '/api/guidance takes nothing but a GET', post.status === 405 ? 'pass' : 'fail', R.why(post));
  if (!R.sb) return;
  const list = await R.http(`${R.sb}/rest/v1/public_guidance?select=slug,members_only,has_document&has_document=eq.true&limit=50`,
    { headers: R.authHeaders() });
  const rows = Array.isArray(list.json) ? list.json : [];
  const mo = rows.find(x => x.members_only);
  if (!mo) {
    R.rec('endpoints', '/api/guidance keeps a members only document from visitors', 'skip',
      'No members only document with a file is published, so there is nothing to try.');
    return;
  }
  const out = await R.http(`${site}/api/guidance/${encodeURIComponent(mo.slug)}`);
  R.rec('endpoints', '/api/guidance keeps a members only document from visitors', out.status === 401 ? 'pass' : out.status >= 200 && out.status < 300 ? 'fail' : 'review', R.why(out));
  const fake = await R.http(`${site}/api/guidance/${encodeURIComponent(mo.slug)}`, { headers: { Authorization: 'Bearer ' + forged('HS256') } });
  R.rec('endpoints', '/api/guidance refuses a made up sign in for a members only document',
    fake.status === 401 || fake.status === 403 ? 'pass' : fake.status >= 200 && fake.status < 300 ? 'fail' : 'review', R.why(fake));
  if (R.config.memberToken) {
    const ok = await R.http(`${site}/api/guidance/${encodeURIComponent(mo.slug)}`, { method: 'HEAD',
      headers: { Authorization: 'Bearer ' + R.config.memberToken } });
    R.rec('endpoints', '/api/guidance gives a current member the members only document', ok.status === 200 ? 'pass' : 'review', R.why(ok));
    const cc = ok.headers.get('cache-control') || '';
    R.rec('endpoints', 'a members only document is not kept in any shared cache', /private|no-store/.test(cc) ? 'pass' : 'fail', cc || 'no Cache-Control');
  }
}

async function checkAuthSettings(R) {
  if (!R.sb) return;
  const r = await R.http(`${R.sb}/auth/v1/settings`, { headers: R.authHeaders() });
  const s = r.json || {};
  if (!r.json) return R.rec('sign in', 'sign in settings could be read', 'review', R.why(r));
  R.rec('sign in', 'new accounts cannot sign themselves up without proving their email', s.mailer_autoconfirm ? 'fail' : 'pass',
    `disable_signup ${s.disable_signup}, mailer_autoconfirm ${s.mailer_autoconfirm}`);
  const ext = Object.entries(s.external || {}).filter(([k, v]) => v === true && k !== 'email').map(([k]) => k);
  R.rec('sign in', 'no other sign in providers are switched on by accident', ext.length ? 'review' : 'pass', ext.join(', ') || 'email only');
  R.rec('sign in', 'phone sign in is off', s.external && s.external.phone ? 'review' : 'pass');
}

async function whoami(R, who) {
  const r = await R.http(`${R.sb}/rest/v1/rpc/whoami`, {
    method: 'POST', headers: { ...R.authHeaders(who), 'Content-Type': 'application/json' }, body: '{}' });
  const row = Array.isArray(r.json) ? r.json[0] : r.json;
  return row && row.person_id ? row : null;
}

async function checkAsMember(R) {
  if (!R.sb || !R.config.memberToken) {
    R.rec('as a member', 'signed in member checks', 'skip', 'No memberToken in the config. See the README to add one.');
    return;
  }
  const me = await whoami(R, 'member');
  if (!me) return R.rec('as a member', 'the member token works', 'fail', 'whoami gave nobody: the token has probably expired (they last an hour).');
  if ((me.roles || []).length) R.rec('as a member', 'the member token belongs to somebody with no staff role', 'fail', 'Roles: ' + me.roles.join(', '));
  const mine = await R.http(`${R.sb}/rest/v1/members?select=id&person_id=eq.${me.person_id}`, { headers: R.authHeaders('member') });
  const myMember = Array.isArray(mine.json) && mine.json[0] ? mine.json[0].id : null;

  // 0059: a member's own row no longer carries who switched it on or off, or the
  // office's reason. Asked for by name, the database must refuse rather than
  // answer, and the columns the site needs must still come back.
  const office = await R.http(`${R.sb}/rest/v1/members?select=activated_by,deactivated_by,deactivation_reason&person_id=eq.${me.person_id}`,
    { headers: R.authHeaders('member') });
  const officeRows = Array.isArray(office.json) ? office.json : [];
  R.rec('as a member', "cannot read who switched their own membership, or the office's reason",
    officeRows.length ? 'fail' : R.refused(office) ? 'pass' : 'review',
    officeRows.length ? 'The three office columns came back' : R.why(office));
  const own = await R.http(`${R.sb}/rest/v1/members?select=membership_number,is_active,status&person_id=eq.${me.person_id}`,
    { headers: R.authHeaders('member') });
  R.rec('as a member', 'still reads their own membership number and status',
    Array.isArray(own.json) && own.json.length === 1 ? 'pass' : 'fail', R.why(own));

  for (const rel of [...TABLES, ...VIEWS]) {
    const r = await R.http(`${R.sb}/rest/v1/${rel}?select=*&limit=1000`, { headers: R.authHeaders('member') });
    const rows = Array.isArray(r.json) ? r.json : [];
    if (!rows.length) { R.rec('as a member', `sees nothing of anybody else in ${rel}`, 'pass', R.why(r)); continue; }
    if (MEMBER_SHARED.includes(rel) || rel.startsWith('my_')) {
      R.rec('as a member', `${rel} is shared with members, as intended`, 'pass', `${rows.length} rows`); continue;
    }
    const others = rows.filter(x =>
      (rel === 'people' && x.id !== me.person_id) ||
      ('person_id' in x && x.person_id !== me.person_id) ||
      ('member_id' in x && x.member_id !== myMember) ||
      (rel === 'members' && x.person_id !== me.person_id));
    if (STAFF_ONLY.includes(rel) || rel.startsWith('admin_')) {
      R.rec('as a member', `sees nothing of anybody else in ${rel}`, 'fail', `${rows.length} rows of an office list came back`);
      continue;
    }
    const ownable = rows.some(x => 'person_id' in x || 'member_id' in x) || rel === 'people';
    R.rec('as a member', `sees nothing of anybody else in ${rel}`,
      others.length ? 'fail' : ownable ? 'pass' : 'review',
      others.length ? `${others.length} rows belong to somebody else` : ownable ? `${rows.length} rows, all theirs` : `${rows.length} rows readable; confirm a member should see these`);
  }

  const tries = [
    ['give themselves super user', `${R.sb}/rest/v1/role_grants`, 'POST', { person_id: me.person_id, role_code: 'super_user' }],
    ['award themselves letters after their name', `${R.sb}/rest/v1/people?id=eq.${me.person_id}`, 'PATCH', { post_nominals: 'FAMI' }],
    ['change their own grade', `${R.sb}/rest/v1/members?person_id=eq.${me.person_id}`, 'PATCH', { grade_id: NOBODY }],
    ['switch their membership on or off', `${R.sb}/rest/v1/members?person_id=eq.${me.person_id}`, 'PATCH', { is_active: true }],
    ['change a system setting', `${R.sb}/rest/v1/system_settings?key=eq.zz-security-check-no-such-key`, 'PATCH', { value: 'x' }],
    ['award themselves CPD directly', `${R.sb}/rest/v1/cpd_entries`, 'POST', { member_id: myMember, points: 99, status: 'accepted', how_recorded: 'automatic', year: 2027 }],
    ['read the change history', `${R.sb}/rest/v1/audit_log?select=id&limit=1`, 'GET', null],
    ['offer themselves an interview time', `${R.sb}/rest/v1/interview_slots`, 'POST', { starts_at: '2030-01-07T10:00:00Z', minutes: 75 }],
    ['book an interview directly', `${R.sb}/rest/v1/interview_bookings`, 'POST', { slot_id: NOBODY, application_id: NOBODY }],
    ['file an email change for somebody else', `${R.sb}/rest/v1/email_change_requests`, 'POST', { person_id: NOBODY, work_email: 'zz-security-check@test.invalid' }],
  ];
  for (const [what, url, method, body] of tries) {
    const r = await R.http(url, { method, headers: { ...R.authHeaders('member'), 'Content-Type': 'application/json', Prefer: 'return=representation' },
                                  body: body ? JSON.stringify(body) : undefined });
    const rows = Array.isArray(r.json) ? r.json : null;
    const got = r.status >= 200 && r.status < 300 && rows && rows.length;
    R.rec('as a member', `cannot ${what}`, got ? 'fail' : (R.refused(r) || R.notFound(r) || (rows && !rows.length)) ? 'pass' : 'review', R.why(r));
  }
  for (const f of STAFF_RPCS) {
    const r = await R.http(`${R.sb}/rest/v1/rpc/${f}`, { method: 'POST',
      headers: { ...R.authHeaders('member'), 'Content-Type': 'application/json' }, body: argsFor(f) });
    R.rec('as a member', `cannot call staff function ${f}`,
      r.status >= 200 && r.status < 300 ? 'fail' : (R.refused(r) || R.notFound(r)) ? 'pass' : 'review', R.why(r));
  }
  // Since version 9: the service role's functions, the interview ones above
  // all, are the Worker's alone. A member must be refused them too.
  for (const f of SERVICE_RPCS) {
    const r = await R.http(`${R.sb}/rest/v1/rpc/${f}`, { method: 'POST',
      headers: { ...R.authHeaders('member'), 'Content-Type': 'application/json' }, body: argsFor(f) });
    R.rec('as a member', `cannot call service function ${f}`,
      r.status >= 200 && r.status < 300 ? 'fail' : (R.refused(r) || R.notFound(r)) ? 'pass' : 'review', R.why(r));
  }
  // 0066: content-media holds the guidance documents, members only ones
  // included, and is the office's alone. A member reaches a document through
  // the Worker, which checks the membership is current; straight from storage,
  // a lapsed member who can still sign in would not be checked at all.
  for (const prefix of ['', 'documents/']) {
    const r = await R.http(`${R.sb}/storage/v1/object/list/content-media`, { method: 'POST',
      headers: { ...R.authHeaders('member'), 'Content-Type': 'application/json' }, body: JSON.stringify({ prefix, limit: 100 }) });
    const files = Array.isArray(r.json) ? r.json : [];
    R.rec('as a member', `cannot list content-media${prefix ? ' ' + prefix : ''} (office only, 0066)`,
      files.length ? 'fail' : 'pass', files.length ? `${files.length} entries came back` : R.why(r));
  }
  for (const b of ['member-photos', 'cpd-evidence']) {
    const r = await R.http(`${R.sb}/storage/v1/object/list/${b}`, { method: 'POST',
      headers: { ...R.authHeaders('member'), 'Content-Type': 'application/json' }, body: JSON.stringify({ prefix: '', limit: 100 }) });
    const files = Array.isArray(r.json) ? r.json : [];
    const foreign = files.filter(f => f.name && !f.name.startsWith(me.person_id) && (!myMember || !f.name.startsWith(myMember)));
    R.rec('as a member', `sees only their own folder in ${b}`, foreign.length ? 'fail' : 'pass',
      foreign.length ? `${foreign.length} other entries` : `${files.length} entries`);
  }
}

async function checkAsStaff(R) {
  if (!R.sb || !R.config.staffToken) {
    R.rec('as staff', 'membership staff checks', 'skip', 'No staffToken in the config.'); return;
  }
  const me = await whoami(R, 'staff');
  if (!me) return R.rec('as staff', 'the staff token works', 'fail', 'whoami gave nobody: the token has probably expired.');
  if ((me.roles || []).includes('super_user'))
    return R.rec('as staff', 'staff checks need a membership staff account that is not a super user', 'skip', 'This token is a super user.');
  const r = await R.http(`${R.sb}/rest/v1/role_grants`, { method: 'POST',
    headers: { ...R.authHeaders('staff'), 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: JSON.stringify({ person_id: me.person_id, role_code: 'super_user' }) });
  R.rec('as staff', 'membership staff cannot make themselves super user', r.status >= 200 && r.status < 300 ? 'fail' : 'pass', R.why(r));
  const l = await R.http(`${R.sb}/rest/v1/rpc/dynamics_members_load`, { method: 'POST',
    headers: { ...R.authHeaders('staff'), 'Content-Type': 'application/json' }, body: JSON.stringify({ p_go: false }) });
  R.rec('as staff', 'membership staff cannot load members (super users only)', l.status >= 200 && l.status < 300 ? 'fail' : 'pass', R.why(l));
}

// The test accounts sign in themselves, with the email and password in the
// config, so nobody has to copy a token out of a browser.
async function signIn(R, who) {
  const email = R.config[who + 'Email'], password = R.config[who + 'Password'];
  if (R.config[who + 'Token'] || !email || !password || !R.sb) return;
  const r = await R.http(`${R.sb}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: R.config.supabaseAnon, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }) });
  if (r.json && r.json.access_token) {
    R.config[who + 'Token'] = r.json.access_token;
    R.rec('sign in', `the test ${who} account signs in`, 'pass', email);
  } else {
    R.rec('sign in', `the test ${who} account signs in`, 'fail', `${email}: ${R.why(r)}. Check the email and password in the config.`);
  }
}

export async function runSuite(R) {
  await signIn(R, 'member');
  await signIn(R, 'staff');
  for (const step of [checkReach, checkHeaders, checkPaths, checkPageCode, checkDatabaseAnon, checkForgery,
                      checkStorage, checkEndpoints, checkAuthSettings, checkAsMember, checkAsStaff]) {
    try { await step(R); }
    catch (e) { R.rec('the check itself', step.name + ' stopped', 'review', e.message); }
  }
  return R.results;
}

// -----------------------------------------------------------------------------
// Part 2: the agent
// -----------------------------------------------------------------------------
const redact = s => String(s)
  .replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/g, '[token]')
  .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]');

export async function runAgent(R, results, { fetchImpl = globalThis.fetch, maxSteps = 40, log = () => {} } = {}) {
  const key = R.config.anthropicKey || process.env.ANTHROPIC_API_KEY;
  if (!key) { R.rec('agent', 'the agent ran', 'skip', 'No anthropicKey in the config.'); return { findings: [], summary: '' }; }
  const model = R.config.agentModel || 'claude-sonnet-5-5';
  const findings = [];
  const tools = [
    { name: 'http_request', description: 'Send one READ-ONLY request (GET, HEAD or OPTIONS) to the AMI staging addresses. Say who to send it as; this program adds that sign in, you never see it. Responses have tokens and email addresses blanked.',
      input_schema: { type: 'object', properties: {
        method: { type: 'string', enum: ['GET', 'HEAD', 'OPTIONS'] },
        url: { type: 'string' },
        as: { type: 'string', enum: ['nobody', 'anon', 'member', 'staff'], description: 'nobody: no headers; anon: the public database key; member or staff: a signed in user of that kind, when configured.' },
        headers: { type: 'object', additionalProperties: { type: 'string' } } }, required: ['method', 'url', 'as'] } },
    { name: 'record_finding', description: 'Record one finding: something wrong or worth a person checking, with how you found it.',
      input_schema: { type: 'object', properties: {
        severity: { type: 'string', enum: ['high', 'medium', 'low', 'info'] },
        title: { type: 'string' }, detail: { type: 'string' },
        suggested_write_test: { type: 'string', description: 'If proving it needs a write, describe the test for a person to run. Do not attempt it.' } },
        required: ['severity', 'title', 'detail'] } },
    { name: 'finish', description: 'End the review with a short summary in plain English for the chief executive.',
      input_schema: { type: 'object', properties: { summary: { type: 'string' } }, required: ['summary'] } },
  ];
  const system = `You are a careful security tester reviewing the AMI (Asbestos Management Institute) website on its STAGING copy, at the owner's request.
You may only send read-only requests (GET, HEAD, OPTIONS), only to these addresses: ${[R.config.siteUrl, R.config.adminUrl, R.config.supabaseUrl, R.config.syncUrl].filter(Boolean).join(', ')}. You have at most ${maxSteps} requests. Do not attempt denial of service, guessing passwords, or anything that writes.
How it is built: a static site and an admin app on Cloudflare Pages; a Cloudflare Worker for /api routes; Supabase Postgres reached through PostgREST at /rest/v1 with row level security; Supabase Storage buckets public-media (public), member-photos and cpd-evidence (private); Supabase Auth with email magic links. Members read their own data through views named my_*; the public reads views named public_*; staff use admin_* views.
A fixed suite has already run; its results are below. Do not repeat what it checked. Look for what it would miss: views or columns that leak more than they should; filters that let a member read another member's row (try PostgREST filters, embedded resources with select=*,people(*), or/and filters, count headers); error messages that give away internals; caching of signed in answers (Cache-Control on /rest/v1 and /api); open redirects; information in HTML comments or source maps; CORS on the database; anything in public views a duty holder should not see.
Record each finding with record_finding, then call finish. Be specific and do not overstate: say what you saw.`;
  const failing = results.filter(r => r.verdict !== 'pass').map(r => `${r.verdict.toUpperCase()} [${r.area}] ${r.check}: ${r.detail}`);
  const messages = [{ role: 'user', content: `Fixed suite: ${results.length} checks, ${results.filter(r => r.verdict === 'pass').length} passed.\nNot passing:\n${failing.join('\n') || 'none'}\n\nMember sign in configured: ${!!R.config.memberToken}. Staff sign in configured: ${!!R.config.staffToken}.\nBegin.` }];
  let summary = '', steps = 0;
  for (let turn = 0; turn < maxSteps + 10; turn++) {
    const res = await fetchImpl('https://api.anthropic.com/v1/messages', { method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model, max_tokens: 2000, system, tools, tool_choice: { type: 'auto' }, messages }) });
    const out = await res.json();
    if (!res.ok) { R.rec('agent', 'the agent ran', 'review', 'Anthropic answered ' + res.status + ': ' + JSON.stringify(out).slice(0, 200)); break; }
    messages.push({ role: 'assistant', content: out.content });
    const uses = out.content.filter(c => c.type === 'tool_use');
    if (!uses.length) break;
    const answers = [];
    let done = false;
    for (const u of uses) {
      let content = '';
      if (u.name === 'http_request') {
        steps++;
        const i = u.input;
        if (steps > maxSteps) content = 'Request limit reached. Record findings and finish.';
        else if (!['GET', 'HEAD', 'OPTIONS'].includes(i.method)) content = 'Refused: read-only requests only.';
        else {
          const h = { ...(i.headers || {}) };
          delete h.Authorization; delete h.authorization; delete h.apikey;
          if (i.as === 'anon' || i.as === 'member' || i.as === 'staff') Object.assign(h, R.authHeaders(i.as === 'anon' ? undefined : i.as));
          try {
            const r = await R.http(i.url, { method: i.method, headers: h });
            const hdrs = [...r.headers.entries()].filter(([k]) => !/set-cookie/i.test(k)).map(([k, v]) => `${k}: ${v}`).join('\n');
            content = redact(`${r.status}\n${hdrs}\n\n${r.text.slice(0, 3500)}`);
            log(`agent ${i.method} ${i.url} as ${i.as}: ${r.status}`);
          } catch (e) { content = String(e.message); }
        }
      } else if (u.name === 'record_finding') {
        findings.push(u.input); content = 'Recorded.';
        log(`agent finding (${u.input.severity}): ${u.input.title}`);
      } else if (u.name === 'finish') {
        summary = u.input.summary; done = true; content = 'Done.';
      }
      answers.push({ type: 'tool_result', tool_use_id: u.id, content });
    }
    messages.push({ role: 'user', content: answers });
    if (done) break;
  }
  return { findings, summary, steps };
}

// -----------------------------------------------------------------------------
// Report
// -----------------------------------------------------------------------------
export function report(results, agent, compareWith) {
  const n = v => results.filter(r => r.verdict === v).length;
  const lines = [`# AMI security check, ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`, '',
    `${results.length} checks: ${n('pass')} passed, ${n('fail')} failed, ${n('review')} to review, ${n('skip')} skipped.`, ''];
  if (compareWith) {
    const before = new Map(compareWith.results.map(r => [r.area + '|' + r.check, r.verdict]));
    const changed = results.filter(r => before.has(r.area + '|' + r.check) && before.get(r.area + '|' + r.check) !== r.verdict);
    lines.push('## Changed since the earlier run', '', ...(changed.length
      ? changed.map(r => `- ${before.get(r.area + '|' + r.check)} to **${r.verdict}**: [${r.area}] ${r.check}. ${r.detail}`)
      : ['Nothing changed.']), '');
  }
  for (const v of ['fail', 'review']) {
    const rs = results.filter(r => r.verdict === v);
    if (!rs.length) continue;
    lines.push(`## ${v === 'fail' ? 'Failed' : 'To review'}`, '', ...rs.map(r => `- [${r.area}] ${r.check}. ${r.detail}`), '');
  }
  if (agent && (agent.findings.length || agent.summary)) {
    lines.push('## The agent', '', agent.summary || '', '',
      ...agent.findings.map(f => `- **${f.severity}**: ${f.title}. ${f.detail || ''}${f.suggested_write_test ? ` Write test for a person: ${f.suggested_write_test}` : ''}`), '');
  }
  lines.push('## Everything', '', '| Verdict | Area | Check | Detail |', '|---|---|---|---|',
    ...results.map(r => `| ${r.verdict} | ${r.area} | ${r.check.replace(/\|/g, '/')} | ${String(r.detail).replace(/\|/g, '/').replace(/\n/g, ' ')} |`));
  return lines.join('\n');
}

// -----------------------------------------------------------------------------
// Command line
// -----------------------------------------------------------------------------
async function main() {
  const args = process.argv.slice(2);
  const opt = k => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
  const cfgPath = opt('--config') || 'security.config.json';
  if (!fs.existsSync(cfgPath)) { console.error(`No config at ${cfgPath}. Copy security.config.example.json and fill it in.`); process.exit(2); }
  const config = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  if (/ami\.uk\.com$/.test(new URL(config.siteUrl).host) && !/staging/.test(config.siteUrl) && !args.includes('--live'))
    { console.error('That is the live site. Add --live if you mean it.'); process.exit(2); }
  const R = makeRun(config);
  if (args.includes('--sign-in')) {
    // Only tries the two test accounts, in a second, without a report.
    await signIn(R, 'member'); await signIn(R, 'staff');
    for (const r of R.results) console.log(`${r.verdict === 'pass' ? 'OK  ' : 'FAIL'} ${r.check}: ${r.detail}`);
    if (!R.results.length) console.log('No test accounts with an email and password in the config.');
    process.exit(R.results.some(r => r.verdict === 'fail') ? 1 : 0);
  }
  console.log('Running the attacker suite against ' + config.siteUrl + ' ...');
  const results = await runSuite(R);
  let agent = null;
  if (args.includes('--agent')) {
    console.log('Running the agent ...');
    agent = await runAgent(R, results, { log: m => console.log('  ' + m) });
  }
  const compare = opt('--compare') ? JSON.parse(fs.readFileSync(opt('--compare'), 'utf8')) : null;
  const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-');
  fs.writeFileSync(`security-report-${stamp}.json`, JSON.stringify({ when: new Date().toISOString(), site: config.siteUrl, results, agent }, null, 2));
  fs.writeFileSync(`security-report-${stamp}.md`, report(results, agent, compare));
  const n = v => results.filter(r => r.verdict === v).length;
  console.log(`\n${results.length} checks: ${n('pass')} passed, ${n('fail')} FAILED, ${n('review')} to review, ${n('skip')} skipped. ${R.requests} requests.`);
  for (const r of results.filter(r => r.verdict === 'fail')) console.log(`  FAIL [${r.area}] ${r.check}: ${r.detail}`);
  if (agent) console.log(`Agent: ${agent.findings.length} findings in ${agent.steps} requests.`);
  console.log(`\nReport: security-report-${stamp}.md (send it to Claude). Data: security-report-${stamp}.json (keep it to compare against).`);
  process.exit(n('fail') ? 1 : 0);
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) main();
