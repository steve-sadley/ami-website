/* The security check, checked. Run: node test-security-check.mjs
   A pretend AMI that does everything right must give no failures; a pretend
   AMI with holes must have each hole reported; the agent must stay read-only,
   inside the configured addresses, and never see a token or an email. */
import { makeRun, runSuite, runAgent, report } from './ami-security-check.mjs';

let pass = 0, fail = 0;
const ok = (c, what) => { if (c) pass++; else { fail++; console.log('  FAIL  ' + what); } };
const J = (b, s = 200, h = {}) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json', ...h } });
const T = (b, s = 200, h = {}) => new Response(b, { status: s, headers: h });
const SAFE_HEADERS = { 'content-security-policy': "default-src 'none'; script-src 'self'; frame-ancestors 'none'",
  'strict-transport-security': 'max-age=31536000', 'x-content-type-options': 'nosniff', 'referrer-policy': 'same-origin' };
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const MEMBER = b64({ alg: 'HS256' }) + '.' + b64({ sub: 'u1', role: 'authenticated' }) + '.sig';
const config = { siteUrl: 'https://staging.ami.test', adminUrl: 'https://admin.ami.test', supabaseUrl: 'https://db.ami.test',
  supabaseAnon: 'sb_publishable_x', syncUrl: 'https://sync.ami.test', memberToken: MEMBER, staffToken: '', anthropicKey: 'k' };

function server(holes = {}) {
  return async (url, opts = {}) => {
    const u = new URL(url), p = u.pathname, m = opts.method || 'GET';
    const auth = (opts.headers || {}).Authorization || '';
    if (u.host === 'staging.ami.test' || u.host === 'admin.ami.test') {
      if (p.startsWith('/api/')) {
        if (p === '/api/pass/status') return holes.passSecret ? J({ apple: true, key: 'x' }) : J({ apple: true, google: false });
        if (p === '/api/mail/drain') return holes.drain ? J({ sent: 0 }) : J({ error: 'staff' }, 401);
        if (p === '/api/contact' || p === '/api/apply') return J({ error: 'no' }, 400);
        // the interview doors (0064), as the Worker answers them
        if (p.startsWith('/api/interview/')) {
          const door = p.slice('/api/interview/'.length);
          if (!['slots', 'book', 'cancel', 'office-cancel'].includes(door)) return T('Not found', 404);
          if (m !== 'POST') return T('POST only', 405);
          if (door === 'office-cancel') return J({ error: 'staff' }, auth.includes(MEMBER) ? 403 : 401);
          return holes.interviewLeak ? J({ given_name: 'Applicant', slots: [{ id: 's1' }] })
                                     : J({ error: 'This booking link is not recognised.' }, 404);
        }
        // guidance documents (0065)
        const gd = p.match(/^\/api\/guidance\/([^/]+)$/);
        if (gd) {
          if (m !== 'GET' && m !== 'HEAD') return T('GET only', 405);
          if (gd[1] !== 'zz-members-guide') return J({ error: 'There is no such document.' }, 404);
          if (holes.guidanceOpen || auth.includes(MEMBER))
            return T('%PDF-1.7', 200, { 'content-type': 'application/pdf', 'cache-control': holes.guidanceCached ? 'public, max-age=300' : 'private, no-store' });
          return J({ error: 'This document is for members.' }, auth ? 403 : 401);
        }
        return J({ error: 'sign in' }, 401, holes.cors ? { 'access-control-allow-origin': '*' } : {});
      }
      if (p === '/.env' && holes.env) return T('SUPABASE_SECRET=abcdefghijklmnopqrstu', 200);
      if (/\.html$|\/$/.test(p)) return T(`<html><script src="/assets/site.js"></script>${holes.key ? 'eyJhbGciOiJIUzI1NiJ9.' + b64({ role: 'service_role', ref: 'x' }) + '.abcdefghijklmnop' : ''}</html>`, 200,
        holes.inline ? { ...SAFE_HEADERS, 'content-security-policy': "script-src 'self' 'unsafe-inline'" } : SAFE_HEADERS);
      if (p === '/assets/site.js') return T('const x = 1;', 200, SAFE_HEADERS);
      return T('not found', 404);
    }
    if (u.host === 'sync.ami.test') return p === '/run' && m === 'POST' ? J({ error: 'x' }, auth ? 403 : 401) : J({}, 405);
    // the database
    if (p === '/rest/v1/') return J({ paths: { '/public_register': {}, '/rpc/fallback_picture': {}, ...(holes.rpc ? { '/rpc/review_cpd': {} } : {}) } });
    if (p === '/rest/v1/rpc/whoami') return auth ? J([{ person_id: 'p-me', roles: [] }]) : J([]);
    if (p === '/rest/v1/rpc/interview_hold' && holes.serviceRpc && auth.includes(MEMBER)) return J({ booking: 'b1' });
    if (p.startsWith('/rest/v1/rpc/')) return J({ code: '42501', message: 'permission denied' }, auth ? 403 : 401);
    if (p === '/rest/v1/public_guidance') return J([{ slug: 'zz-members-guide', title: 'Members guide', members_only: true, has_document: true,
      ...(holes.storagePath ? { storage_path: 'documents/2026/members-guide.pdf' } : {}) }]);
    if (p === '/rest/v1/interview_slots' && m === 'GET' && holes.staffOnlyRead && auth.includes(MEMBER))
      return J([{ id: 's1', starts_at: '2027-01-07T10:00:00Z' }]);
    if (p === '/rest/v1/public_register') return J([{ display_name: 'A Member', ...(holes.leak ? { email: 'a@x.invalid' } : {}) }]);
    if (p === '/rest/v1/people' && m === 'GET') return auth.includes(MEMBER)
      ? J([{ id: 'p-me', email: 'me@x.invalid' }, ...(holes.idor ? [{ id: 'p-other', email: 'other@x.invalid' }] : [])])
      : holes.anonRead ? J([{ id: 'p-1' }]) : J([]);
    if (p === '/rest/v1/members' && m === 'GET') {
      if (!auth.includes(MEMBER)) return J([]);
      // since 0059 the office columns are refused to a member, as Postgres does
      if (/activated_by|deactivat/.test(u.searchParams.get('select') || '') && !holes.office)
        return J({ code: '42501', message: 'permission denied for table members' }, 403);
      return J([{ id: 'm-me', person_id: 'p-me', membership_number: 'TEST-1', is_active: true, status: 'current' }]);
    }
    if (p === '/rest/v1/audit_log' && holes.forgery && auth && !auth.includes(MEMBER)) return J([{ id: 1 }]);
    if (p.startsWith('/rest/v1/')) return m === 'GET' ? J([]) : J({ code: '42501', message: 'permission denied' }, 401);
    if (p === '/auth/v1/token') { const b = JSON.parse(opts.body); return b.password === 'right' ? J({ access_token: MEMBER }) : J({ code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials' }, 400); }
    if (p === '/auth/v1/settings') return J({ disable_signup: false, mailer_autoconfirm: !!holes.autoconfirm, external: { email: true } });
    if (p.startsWith('/storage/v1/bucket')) return J([]);
    if (p === '/storage/v1/object/list/content-media' && holes.contentMedia && auth.includes(MEMBER))
      return J([{ name: 'documents/2026/members-guide.pdf' }]);
    if (p.startsWith('/storage/v1/object/list/')) return holes.files ? J([{ name: 'someone-else/photo.jpg' }]) : J([]);
    if (p.startsWith('/storage/v1/object/')) return J({ error: 'not found' }, holes.publicEvidence && p.includes('cpd-evidence') ? 200 : 400);
    return J({}, 404);
  };
}

console.log('\na site that does everything right');
{
  const R = makeRun(config, server());
  const res = await runSuite(R);
  const fails = res.filter(r => r.verdict === 'fail');
  ok(fails.length === 0, 'no failures: ' + fails.map(f => f.check).join('; '));
  ok(res.length > 250, 'and hundreds of checks were made: ' + res.length);
  ok(res.some(r => r.area === 'as a member' && r.verdict === 'pass'), 'including as a signed in member');
}

console.log('\na site with holes');
const holes = { cors: 'CORS', env: '.env', key: 'service key in page', inline: 'unsafe-inline', rpc: 'staff function callable',
  leak: 'email in public register', idor: 'member reads another', anonRead: 'anon reads people', forgery: 'forged token accepted',
  autoconfirm: 'sign up without proving email', files: 'private files listed', publicEvidence: 'evidence public', drain: 'mail drain open to anybody',
  office: 'member reads who switched their membership',
  contentMedia: 'member lists the private documents (0066)', interviewLeak: 'a made up invitation link shows times',
  guidanceOpen: 'a members only document handed to a visitor', guidanceCached: 'a members only document cached publicly',
  storagePath: 'public guidance gives the storage address', staffOnlyRead: 'member reads the interview slots',
  serviceRpc: 'member calls an interview function directly' };
for (const [h, what] of Object.entries(holes)) {
  const R = makeRun(config, server({ [h]: true }));
  const res = await runSuite(R);
  const found = res.filter(r => r.verdict === 'fail' || (h === 'rpc' && r.verdict === 'review'));
  ok(found.length > 0, `${what} is caught (${found.map(f => f.check).slice(0, 2).join('; ')})`);
}

console.log('\nan admin app behind Cloudflare Access');
{
  const base = server();
  const R = makeRun(config, async (url, opts) => new URL(url).host === 'admin.ami.test'
    ? new Response('', { status: 302, headers: { location: 'https://ami.cloudflareaccess.com/cdn-cgi/access/login' } })
    : base(url, opts));
  const res = await runSuite(R);
  ok(res.some(r => /behind Cloudflare Access/.test(r.check) && r.verdict === 'pass')
     && !res.some(r => /^admin app \//.test(r.check) && r.verdict === 'fail'),
     'is a pass, not a list of missing headers');
}

console.log('\nsigning in with a password');
{
  const R = makeRun({ ...config, memberToken: '', memberEmail: 'm@x.invalid', memberPassword: 'right' }, server());
  const res = await runSuite(R);
  ok(res.some(r => r.check === 'the test member account signs in' && r.verdict === 'pass')
     && res.some(r => r.area === 'as a member' && r.check.startsWith('cannot give themselves') && r.verdict === 'pass'),
     'the member signs in from the config, and the member checks run');
  const R2 = makeRun({ ...config, memberToken: '', memberEmail: 'm@x.invalid', memberPassword: 'wrong' }, server());
  const res2 = await runSuite(R2);
  ok(res2.some(r => r.check === 'the test member account signs in' && r.verdict === 'fail'), 'a wrong password is reported, not ignored');
  ok(res2.some(r => r.check === 'the test member account signs in' && /invalid_credentials: Invalid login credentials/.test(r.detail)),
     "and the report gives Supabase's reason, not just 400");
}

console.log('\nthe wallet status');
{
  const res = await runSuite(makeRun(config, server()));
  ok(res.some(r => r.check === '/api/pass/status gives no secret away' && r.verdict === 'pass'), 'true or false for each wallet is a pass');
  const res2 = await runSuite(makeRun(config, server({ passSecret: true })));
  ok(res2.some(r => r.check === '/api/pass/status gives no secret away' && r.verdict === 'review'), 'anything more is for a person to look at');
}

console.log('\nthe agent');
{
  const sent = [];
  let turn = 0;
  const script = [
    [{ type: 'tool_use', id: 't1', name: 'http_request', input: { method: 'DELETE', url: 'https://db.ami.test/rest/v1/people', as: 'member' } }],
    [{ type: 'tool_use', id: 't2', name: 'http_request', input: { method: 'GET', url: 'https://evil.example/', as: 'nobody' } }],
    [{ type: 'tool_use', id: 't3', name: 'http_request', input: { method: 'GET', url: 'https://db.ami.test/rest/v1/people?select=*', as: 'member',
       headers: { Authorization: 'Bearer stolen' } } }],
    [{ type: 'tool_use', id: 't4', name: 'record_finding', input: { severity: 'low', title: 'Test finding', detail: 'x' } },
     { type: 'tool_use', id: 't5', name: 'finish', input: { summary: 'All good.' } }],
  ];
  const site = server();
  const fetchImpl = async (url, opts) => {
    if (String(url).startsWith('https://api.anthropic.com')) {
      sent.push(JSON.parse(opts.body));
      return J({ content: script[turn++] || [{ type: 'text', text: 'done' }] });
    }
    const r = await site(url, opts);
    if (String(url).includes('/rest/v1/people')) sent.push({ upstreamAuth: (opts.headers || {}).Authorization });
    return r;
  };
  const R = makeRun(config, fetchImpl);
  const out = await runAgent(R, [{ area: 'x', check: 'y', verdict: 'pass', detail: '' }], { fetchImpl });
  const toClaude = JSON.stringify(sent.filter(s => s.messages));
  ok(/Refused: read-only/.test(toClaude), 'a write is refused');
  ok(/not one of the configured addresses/.test(toClaude), 'and so is any address outside the configured ones');
  ok(!toClaude.includes(MEMBER) && !toClaude.includes('sb_publishable_x'), 'the agent never sees a token or the key');
  ok(!toClaude.includes('me@x.invalid') && toClaude.includes('[email]'), 'and email addresses are blanked before it sees them');
  ok(sent.some(s => s.upstreamAuth === 'Bearer ' + MEMBER), 'the request still goes as the member, and its own Authorization is ignored');
  ok(out.findings.length === 1 && out.summary === 'All good.', 'findings and the summary come back');
  const md = report(makeRun(config, server()).results.concat([{ area: 'a', check: 'b', verdict: 'fail', detail: 'd' }]), out,
    { results: [{ area: 'a', check: 'b', verdict: 'pass' }] });
  ok(/pass to \*\*fail\*\*: \[a\] b/.test(md), 'a comparison with an earlier run shows what changed');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
