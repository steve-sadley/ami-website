
/* The preference page, reached two ways.

   From a link in an AMI email, with ?t=<token> and no session at all. That is
   the case that matters most: somebody who wants less email must not have to
   remember a password to say so, and a bulletin without a working way out is not
   lawful.

   Or signed in, from the profile page, with no token in the address. Then the
   member's own session finds their token and the same three functions do the
   work, so there is one page and not two that have to agree with each other.

   The token is a uuid, so enumerating one is not a thing that happens. What
   matters more is what a valid one gives back: a first name and five switches,
   and no email address, no membership number and no full name. A link can be
   forwarded, printed, or sit in a shared mailbox, and none of those should
   confirm to a stranger who it belongs to.

   The switch markup is the site's own: .switches, .sw, .st and a button with
   role="switch". A checkbox would have needed a stylesheet of its own, and a
   second way of drawing a switch is a second thing to keep in step. */

const panel = document.getElementById('panel').firstElementChild;

/* qs() is site.js's own query string helper. Declaring a second `qs` here threw
   "Identifier 'qs' has already been declared" and killed the whole file before
   a single line of it ran, so the page sat on its static fallback for ever. It
   looked exactly like a slow database. Every page script shares one global
   scope with site.js: check before naming anything at the top level. */
let token = qs('t');
let P     = null;

const SWITCHES = [
  { k:'bulletins',     h:'Bulletins and news from AMI',
    p:'Occasional news, guidance and things the institute wants members to know.' },
  { k:'events',        h:'Event announcements',
    p:'The AGM, seminars, regional meetings and webinars.' },
  /* The CPD reminder is not offered here any more. See the note in
     page-profile.js: it is a notice about the member's own standing rather than
     something they subscribe to, and 0034 turned it back on for everybody who
     had switched it off. */
  /* Nor is the CPD receipt, from 30 October 2026 (0039): every point earned is
     emailed, and a member cannot switch it off. */
];

const NOTIFY = [['off','Never'], ['immediate','Straight away'],
                ['daily','Once a day'], ['weekly','Once a week']];

function say(kind, text){
  const el = document.getElementById('msg');
  if (el) el.innerHTML = '<div class="note" style="color:'
    + (kind === 'err' ? 'var(--red,#E40613)' : 'inherit') + '">' + esc(text) + '</div>';
}

/* A page whose sections fade in on scroll shows nothing at all unless something
   starts the reveal. site.js calls revealSoon() at page start and calling it
   twice does nothing, but this panel is drawn long after that, once the database
   has answered. The privacy notice shipped blank for exactly this reason and
   eleven browser checks passed while it was invisible. */
function paint(html){
  panel.innerHTML = html;
  if (typeof revealSoon === 'function') revealSoon();
}

function notRecognised(){
  paint(`
    <h2 style="margin-bottom:10px">This link is not one AMI recognises</h2>
    <p class="note">Links in AMI emails are unique to the person they were sent to,
       and they stop working if the membership record they belong to is removed.
       If the link was copied by hand, something may have been left off the end.</p>
    <p class="note" style="margin-top:10px">You can change the same settings by
       signing in, and the office can change them for you if you would rather.</p>
    <div class="row-between" style="gap:10px;margin-top:20px">
      <a class="btn btn-g" href="/login">Sign in</a>
      <a class="btn btn-g" href="/contact">Ask the office</a>
    </div>`);
}

function draw(){
  paint(`
    <p class="note" style="margin-bottom:18px">${
      P.given_name
        ? 'These are the settings on ' + esc(P.given_name) + '&rsquo;s membership record.'
        : 'These are the settings on your membership record.'}</p>

    <div class="switches">
      ${SWITCHES.map(s => `
        <div class="sw">
          <div class="st"><h5>${esc(s.h)}</h5><p>${esc(s.p)}</p></div>
          <button class="toggle" role="switch" data-k="${s.k}"
                  aria-checked="${P[s.k] ? 'true' : 'false'}"
                  aria-label="${esc(s.h)}"></button>
        </div>`).join('')}

      <div class="sw">
        <div class="st">
          <h5>Forum emails</h5>
          <p>How often AMI tells you about replies in discussions you are following.</p>
        </div>
        <div style="flex:none;min-width:170px">
          <select id="notify" class="field" style="width:100%;padding:11px 14px;
            border-radius:10px;border:1px solid var(--input-bd);background:var(--input-bg);
            color:var(--txt);font-family:inherit;font-size:14px">
            ${NOTIFY.map(([v, t]) =>
              `<option value="${v}"${P.forum_notifications === v ? ' selected' : ''}>${t}</option>`
            ).join('')}
          </select>
        </div>
      </div>
    </div>

    <div class="callout" style="margin-top:24px">
      <b>Some things are not settings</b>
      <p>AMI will always write to you about your own membership and your own
         record: a decision on your application, a decision on a CPD entry you
         have logged, and anything AMI has to tell you as a member. Those are
         notices rather than mailings and there is no switch for them here.</p>
    </div>

    <div id="msg" style="margin-top:16px"></div>

    <div class="row-between" style="gap:10px;margin-top:18px">
      <button class="btn btn-g" id="all" type="button">Stop all of it</button>
      <a class="btn btn-g" href="/privacy">What AMI holds about you</a>
    </div>`);

  document.querySelectorAll('.toggle').forEach(t => t.onclick = () => flip(t));
  document.getElementById('notify').onchange = e => set({ p_forum: e.target.value });
  document.getElementById('all').onclick = stopAll;
}

/* Saved on the flip rather than behind a Save button. Somebody who has just
   pressed unsubscribe should not have to press a second thing for it to count,
   and a page that saves on change cannot be left half done in a closed tab. */
async function flip(t){
  const k = t.dataset.k;
  const was = t.getAttribute('aria-checked') === 'true';
  t.setAttribute('aria-checked', String(!was));
  t.disabled = true;
  const ok = await set({ ['p_' + k]: !was });
  t.disabled = false;
  if (!ok) { t.setAttribute('aria-checked', String(was)); return; }
  P[k] = !was;
}

/* Every argument is sent every time, with only the changed one different, so a
   partial payload can never be read as "leave the rest alone" by one version of
   the function and "clear the rest" by another. The database uses coalesce, so
   nulls would be safe anyway; this is belt and braces on the one call that
   decides whether somebody is emailed again. */
async function set(change){
  const body = Object.assign({
    p_token:         token,
    p_bulletins:     P.bulletins,
    p_events:        P.events,
    // p_cpd_reminders is deliberately not sent. 0034 makes the database ignore
    // it and hold the column true, so sending it would be a value with no
    // effect that somebody would later mistake for a working switch.
    // p_cpd_receipts is not sent either, from 0039, for the same reason.
    p_forum:         P.forum_notifications,
  }, change);

  const { data, error } = await sb.rpc('set_preferences_by_token', body);

  if (error) { say('err', 'That did not save. Please try again, or email the office.'); return false; }
  // false rather than an error means the token matched nothing, which is a
  // different answer and deserves different words. Somebody whose record has
  // gone should not be told to try again.
  if (!data)  { notRecognised(); return false; }

  if (change.p_forum !== undefined) P.forum_notifications = change.p_forum;
  say('ok', 'Saved. AMI will do that from now on.');
  return true;
}

async function stopAll(){
  const b = document.getElementById('all');
  b.disabled = true;
  const { data, error } = await sb.rpc('unsubscribe_all_by_token', { p_token: token });
  b.disabled = false;
  if (error) return say('err', 'That did not save. Please try again, or email the office.');
  if (!data) return notRecognised();

  SWITCHES.forEach(s => { P[s.k] = false; });
  P.forum_notifications = 'off';
  draw();
  say('ok', 'Everything is off. AMI will still write to you about your own '
          + 'membership, because that is a notice rather than a mailing.');
}

(async () => {
  /* No token in the address. If somebody is signed in we can find their own,
     which is what the link from the profile page relies on. If not, the link is
     simply not one AMI recognises, and saying so is a better answer than a sign
     in wall on a page whose whole point is not needing one. */
  if (!token) {
    try {
      const { data: s } = await sb.auth.getSession();
      if (s && s.session) {
        const { data } = await sb.from('member_preferences').select('unsubscribe_token').limit(1);
        if (data && data.length) token = data[0].unsubscribe_token;
      }
    } catch { /* falls through to the panel below */ }
  }
  if (!token) return notRecognised();

  const { data, error } = await sb.rpc('preferences_by_token', { p_token: token });
  if (error || !data || !data.length) return notRecognised();

  P = data[0];
  draw();
})();
