/* =============================================================================
   My AMI

   The landing page of the members area. It answers four questions in the order a
   member asks them: am I current, where is my CPD, what has happened since I was
   last here, and what is coming up.

   It reads five things at once rather than one after another. Five round trips in
   sequence is five times the latency for no reason; the page cannot draw until it
   has all of them anyway.
   ============================================================================= */

const out = document.getElementById('out');

(async () => {
  const me = await memberChrome('/me');
  const { data:{ user } } = await sb.auth.getUser();

  const [profile, summary, recent, events] = await Promise.all([
    sb.from('my_profile').select('*').maybeSingle(),
    sb.from('my_cpd_summary').select('*').eq('year', YEAR).maybeSingle(),
    sb.from('my_recent').select('*').limit(6),
    sb.from('public_content').select('*').eq('kind', 'event')
      .gte('starts_at', new Date().toISOString()).order('starts_at').limit(3),
  ]);

  if (profile.error) return failed(out, profile.error, 'Your record');
  const p = profile.data;

  if (!p) {
    out.innerHTML = `<div class="glass" style="padding:clamp(26px,3vw,44px);max-width:680px;margin:0 auto">
      <h1 style="font-size:28px;font-weight:800;margin-bottom:10px">Signed in, but no membership yet</h1>
      <p style="color:var(--muted)">AMI holds a record for you and no membership is attached to
        it. If you have applied recently, the office creates the membership when the
        application is approved.</p>
      <p style="margin-top:22px"><a class="btn btn-g" href="/">Back to the site</a></p>
    </div>`;
    return;
  }

  const s   = summary.data || { core_points:0, non_core_points:0, pending_count:0 };
  const req = { core: Number(s.core_required ?? p.cpd_required_core ?? 5),
                non:  Number(s.non_core_required ?? p.cpd_required_non_core ?? 5) };
  const pic = await photoUrl(p.photo_path);
  const got = Number(s.core_points || 0) + Number(s.non_core_points || 0);
  const need = req.core + req.non;

  out.innerHTML = `
    <div class="mwelcome glass">
      ${avatar(pic, p, 'mug')}
      <div class="who">
        <h1>${esc(greeting())}, ${esc(p.given_name || '')}</h1>
        <div class="sub">${esc(lastSeen(user))}</div>
        <div class="badges">
          <span class="badge-t red">${esc(p.grade || 'Member')}</span>
          ${p.grade_post_nominals ? `<span class="badge-t">${esc(p.grade_post_nominals)}</span>` : ''}
          <span class="badge-t ${p.is_active ? 'ok' : 'wait'}">
            ${p.is_active ? 'Membership active' : 'Membership not active'}</span>
        </div>
      </div>
      <div class="meta">
        <b>${esc(p.membership_number || '')}</b>
        ${p.joined_on ? 'Member since ' + esc(fmtDate(p.joined_on)) : ''}
      </div>
    </div>

    ${p.is_active ? '' : `<div class="note info" style="margin-top:18px">
      <b>Your membership is not currently active.</b> Your card will not verify and you are
      not listed on the public register. The office can tell you why, and
      <a href="/contact" style="color:var(--link);font-weight:700">they are the people to ask</a>.
    </div>`}

    <div class="tiles">
      ${tile('/cpd', icoChart, 'My CPD', cpdLine(s, req, got, need), 'Open my record')}
      ${tile('/card', icoCard, 'My membership card', cardLine(p), 'View or reissue')}
      ${tile('/forum', icoTalk, 'Members forum', 'Ask the question you would otherwise ring three people about. Every post carries a name and a grade.', 'Go to the forum')}
      ${tile('/profile', icoUser, 'My profile', profileLine(p), 'Edit my details')}
    </div>

    <!-- THREE children, not two, and that is the whole point of .me-layout.
         With the heading inside the left column the Coming up panel started
         level with the word "Recently" and sat a centimetre above the first
         panel of the record, which read as a mistake. The heading spans both
         columns on its own row, so the two panels start on the same line. -->
    <section style="padding:36px 0 0"><div class="me-layout">
      <div class="head-left sec-head">
        <div class="eyebrow"><span class="tri"></span>Recently</div>
        <h2>What has happened on your record</h2>
      </div>
      <div id="recent"></div>
      <div class="ev-side glass">
        <h3>Coming up</h3>
        <div class="subh">Events you can book from here</div>
        <div id="events"></div>
        <a href="/news" class="btn btn-red btn-s" style="margin-top:16px">See all events</a>
      </div>
    </div></section>`;

  drawRecent(recent.data || []);
  drawEvents(events.data || []);
})();

/* ---------- the tiles ---------- */
function tile(href, ico, title, body, more){
  return `<a class="tile glass" href="${href}">
    <div class="ic">${ico}</div>
    <h3>${esc(title)}</h3>
    <p>${esc(body)}</p>
    <span class="more">${esc(more)} &rsaquo;</span>
  </a>`;
}

// The words under each tile are the state of that thing, not a description of it.
// A member who reads "six of your 10 points are in" has been told something. A
// member who reads "track your CPD here" has been told where they already are.
function cpdLine(s, req, got, need){
  const short = Math.max(0, req.core - Number(s.core_points || 0))
              + Math.max(0, req.non  - Number(s.non_core_points || 0));
  const wait  = s.pending_count
    ? `, and ${s.pending_count} ${s.pending_count === 1 ? 'entry is' : 'entries are'} waiting to be reviewed`
    : '';
  if (!short) return `All ${need} points are in for ${YEAR}${wait}.`;
  return `${got} of your ${need} points are in for ${YEAR}. `
       + `${short} still to go${wait}.`;
}

function cardLine(p){
  if (!p.is_active) return 'Your card cannot be issued while the membership is not active.';
  return p.card_issued_at
    ? 'Your card is issued. Anyone can check it against the register by scanning the code on it.'
    : 'Your card has not been issued yet. It takes one press, and it goes straight into your wallet.';
}

function profileLine(p){
  const bits = [];
  bits.push(p.list_on_register ? 'You are on the public register' : 'You are not on the public register');
  bits.push(p.photo_path ? (p.photo_on_public_page ? 'and your photograph is shown'
                                                   : 'and your photograph is not')
                         : 'and you have not added a photograph yet');
  return bits.join(' ') + '.';
}

/* ---------- what has happened ---------- */
// Three kinds of thing land here: a point that arrived, an entry waiting, and a
// reply to something the member wrote. One row shape for all three, because the
// question being answered is the same one.
function drawRecent(rows){
  const el = document.getElementById('recent');
  if (!rows.length) {
    el.innerHTML = `<div class="callout">Nothing has happened on your record yet this year.
      Once you log an activity, attend an event or answer a set of questions, it appears here.</div>`;
    return;
  }
  el.innerHTML = rows.map(r => {
    const mark = { auto:['&#10003;','rgba(74,222,128,.16)','#9df3bd'],
                   wait:['&#8226;','rgba(255,201,120,.16)','#ffc978'],
                   ami: ['A','rgba(228,6,19,.2)','#fff'],
                   post:['&#9998;','rgba(255,255,255,.08)','var(--link)'] }[r.kind]
              || ['&#8226;','rgba(255,255,255,.08)','var(--link)'];
    const row = `<div class="tav" style="background:${mark[1]};color:${mark[2]}">${mark[0]}</div>
      <div class="tb"><h4>${esc(r.title)}</h4>
        <div class="tm">${esc(r.detail || '')} ${esc(fmtWhen(r.happened_at))}</div></div>`;
    return r.href
      ? `<a class="trow glass-soft" href="${esc(r.href)}">${row}</a>`
      : `<div class="trow glass-soft">${row}</div>`;
  }).join('');
}

function drawEvents(rows){
  const el = document.getElementById('events');
  if (!rows.length) {
    el.innerHTML = `<p style="font-size:14px;color:var(--muted)">Nothing is in the diary just
      yet. When AMI publishes an event it appears here first.</p>`;
    return;
  }
  el.innerHTML = rows.map(e => `
    <div class="evc">
      <div class="ed"><span class="d">${esc(dayOf(e.starts_at))}</span>
        <span class="m">${esc(monOf(e.starts_at))}</span></div>
      <div>
        <div class="et">${esc(e.category || 'Event')}</div>
        <h5>${esc(e.title)}</h5>
        <div class="em">${esc(timeOf(e.starts_at))}${e.location ? ', ' + esc(e.location) : ''}</div>
      </div>
    </div>`).join('');
}

/* ---------- small things ---------- */
function greeting(){
  const h = new Date().getHours();
  return h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
}

// Supabase records the last sign in on the ACCOUNT, not on the AMI record, which
// is why this reads the session user rather than whoami(). Showing it is a quiet
// way of letting somebody notice a sign in that was not theirs.
function lastSeen(user){
  return user && user.last_sign_in_at
    ? 'Last signed in ' + fmtWhen(user.last_sign_in_at)
    : 'Welcome to the members area';
}

const icoChart = '<svg viewBox="0 0 24 24"><path d="M3 17l5-5 4 3 8-8"/><path d="M21 7v6h-6"/></svg>';
const icoCard  = '<svg viewBox="0 0 24 24"><rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20"/></svg>';
const icoTalk  = '<svg viewBox="0 0 24 24"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>';
const icoUser  = '<svg viewBox="0 0 24 24"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>';
