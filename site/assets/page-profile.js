/* =============================================================================
   My profile

   Three lists, kept visibly apart.

   The AMI record: name, grade, membership number, employer, joined date. Shown,
   and not editable here. A member cannot update their own membership row at all,
   by policy rather than by this page choosing not to offer it, and that is the
   line the whole scheme sits on: a member who can edit their own grade can award
   themselves one.

   What the member owns: how to reach them, and their addresses. That is the
   whole list, and it is short because most of what a member might want to change
   is a fact about their membership rather than about them.

   Their emails (0062): both are shown, a change is asked for rather than made,
   because ARCA's records own them, and the member chooses which one AMI uses.

   What the public sees: five switches, each labelled with what it does rather
   than with a noun. "Public profile" tells nobody anything. "Your name, grade and
   employer appear in the register" tells them exactly what they are agreeing to.
   ============================================================================= */

const out = document.getElementById('out');

/* Each switch names a real column on member_preferences and a real consequence.
   There is no switch here for anything the site does not actually do, which is
   why there is no "let members message me": there is no messaging. */
const SWITCHES = [
  { k:'list_on_register', h:'List me on the public register',
    p:'Your name, grade, employer and the year you joined appear in the searchable '
      + 'register at ami.uk.com/register. Off means the register does not list you. '
      + 'The link on your card still works either way.' },
  { k:'public_profile', h:'Let my own page be looked up',
    p:'This is the page a card leads to when somebody scans it. Off means the code on '
      + 'your card cannot confirm your membership to anybody, so most members leave it on.' },
  { k:'photo_on_public_page', h:'Show my photograph on that page',
    p:'Off by default. Your photograph is on your card whichever way this sits, and this '
      + 'decides only whether somebody who scans it also sees your face. It is also what '
      + 'decides whether other members see your picture in the forum.' },
  { k:'email_events', h:'Email me about events',
    p:'Webinars, regional meetings and the AGM.' },
  { k:'email_newsletter', h:'Email me the newsletter',
    p:'Occasional. Nothing about your own membership is ever a preference: a notice '
      + 'about your record reaches you whatever these say.' },
  /* THE CPD REMINDER IS NOT A PREFERENCE AND NO LONGER APPEARS HERE.
     23 August 2026, Steve's decision.

     CPD is a condition of the grade rather than something AMI sends for
     interest, so a member who is short in October is told, the same way a
     decision about their own record reaches them whatever these switches say.
     It was removed from /preferences in the same change and 0034 switched it
     back on for everybody who had turned it off, because a setting nobody can
     see and nobody can undo is worse than either having it or not.

     The CPD receipt went the same way on 30 October 2026 (0039): Steve decided
     every point earned is emailed and members cannot switch it off, so it is
     no longer offered here either. */
];

const NOTIFY = [
  ['off',       'Never'],
  ['immediate', 'As they happen'],
  ['daily',     'Once a day'],
  ['weekly',    'Once a week'],
];

let P = null;
let SIGNIN = '';   // the account's own address, which is what signing in uses

(async () => {
  await memberChrome('/profile');
  const { data, error } = await sb.from('my_profile').select('*').maybeSingle();
  if (error) return failed(out, error, 'Your profile');
  if (!data)  return out.innerHTML = '<div class="state"><p>AMI holds no membership for '
    + 'this account yet.</p></div>';
  P = data;
  try { const { data:u } = await sb.auth.getUser(); SIGNIN = (u && u.user && u.user.email) || ''; } catch (_) {}
  if (!SIGNIN) SIGNIN = P.email || '';
  draw(await photoUrl(P.photo_path));
})();

function draw(pic){
  out.innerHTML = `
  <div class="prof-grid">

    <div>
      <div class="photo-box glass">
        ${P.photo_path && pic
          ? `<div class="pimg" style="background-image:url('${encodeURI(pic)}')"></div>`
          : `<div class="pimg">${esc(initials(P))}</div>`}
        <a href="/photo" class="btn btn-red btn-s">
          ${P.photo_path ? 'Change photograph' : 'Add a photograph'}</a>
        <p style="font-size:13px;color:var(--muted);margin-top:14px;line-height:1.5">
          Head and shoulders, looking at the camera. It goes on your card. It goes on your
          public page only if you switch that on.</p>
      </div>
      <div class="callout">
        <b>Held privately.</b> Member photographs sit in a private store. Nothing there can
        be reached by an address alone, and every view is a signed link that expires.
      </div>
      ${P.slug ? `<div class="callout">
        <b>Your public page.</b>
        <a href="/m/${esc(P.slug)}" style="color:var(--link);font-weight:700">ami.uk.com/m/${esc(P.slug)}</a>
        is what the code on your card leads to. Have a look at it: it is what a duty holder
        sees.</div>` : ''}
    </div>

    <div>
      <div class="formcard glass">
        <h3>The AMI record</h3>
        <div class="fsub">What AMI holds about your membership. The office changes these,
          because a member who can edit their own grade can award themselves one.</div>
        <div class="two">
          ${ro('Given name', P.given_name)}
          ${ro('Family name', P.family_name)}
        </div>
        <div class="two">
          ${ro('Grade', [P.grade, P.grade_post_nominals && '(' + P.grade_post_nominals + ')']
                 .filter(Boolean).join(' '))}
          ${ro('Membership number', P.membership_number)}
        </div>
        <div class="two">
          ${ro('Employer', P.employer || 'Not recorded')}
          ${ro('Member since', fmtDate(P.joined_on))}
        </div>
        <div class="note info" style="margin-bottom:0">
          Something wrong here? <a href="/contact" style="color:var(--link);font-weight:700">Tell
          the office</a> and they will put it right.
        </div>
      </div>

      <div class="formcard glass" style="margin-top:26px">
        <h3>Your details</h3>
        <div class="fsub">The short list of things you can change yourself.</div>

        <div class="field">
          <label for="email">Sign-in email</label>
          <input type="email" id="email" autocomplete="email" value="${esc(SIGNIN || '')}">
          <div class="hint">The address you sign in with. It is not where AMI writes to you:
            that is set under Your emails. Changing it sends a confirmation to the old address
            and the new one, and nothing changes until you follow the link in the new one.</div>
        </div>

        <div class="field">
          <label for="mobile">Telephone</label>
          <input type="tel" id="mobile" autocomplete="tel" value="${esc(P.mobile || '')}">
        </div>

        <div class="two">
          <div class="field">
            <label for="home">Home address</label>
            <textarea id="home" rows="3" maxlength="300">${esc(addr(P.home_address))}</textarea>
          </div>
          <div class="field">
            <label for="work">Work address</label>
            <textarea id="work" rows="3" maxlength="300">${esc(addr(P.business_address))}</textarea>
          </div>
        </div>

        <div id="msg"></div>
        <button class="btn btn-red" type="button" id="save">Save changes</button>
      </div>

      ${emailsCard()}

      <div class="head-left sec-head" style="margin:34px 0 16px">
        <div class="eyebrow"><span class="tri"></span>What the public sees</div>
        <h2>Your switches</h2>
      </div>

      <div class="switches glass">
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
              ${NOTIFY.map(([v,t]) =>
                `<option value="${v}"${P.forum_notifications===v?' selected':''}>${t}</option>`
              ).join('')}
            </select>
          </div>
        </div>
      </div>
      <div id="swmsg"></div>

      ${!P.photo_path ? `<div class="callout">
        <b>The photograph switch does nothing until there is a photograph.</b>
        <a href="/photo" style="color:var(--link);font-weight:700">Add one</a> and it takes
        effect straight away.</div>` : ''}

      <div class="mgrid" style="margin-top:26px">
        <div class="callout">
          <b>Signing in.</b> Set a new password, and turn on a second step if you have not
          already. Your card and your CPD record are worth protecting.
          <div style="margin-top:14px"><button class="btn btn-g btn-s" type="button" id="pw">
            Email me a link to change my password</button></div>
          <div id="pwmsg"></div>
        </div>
        <div class="callout">
          <b>Your data.</b> Everything AMI holds about you on this site, as a file you can
          keep. Membership records and CPD are kept indefinitely, and the
          <a href="/privacy">privacy notice</a> says so plainly rather than leaving you to
          find out.
          <div style="margin-top:14px"><button class="btn btn-g btn-s" type="button" id="dl">
            Download my data</button></div>
          <div id="dlmsg"></div>
        </div>
      </div>
    </div>

  </div>`;

  wire();
}

/* ---------- Your emails (0062) ----------
   Both emails come from ARCA's records in Dynamics, so a member cannot simply
   overwrite them here: the next sync would put the old ones back. A change is
   a REQUEST. The office makes it in Dynamics, the sync brings it in, and the
   request closes itself. Which of the two AMI writes to is the website's own
   setting, so that changes at once. */
function emailsCard(){
  const pending = P.email_request_status === 'pending';
  const lastWord = {
    pending:  () => `<div class="note info" id="ereq"><b>Waiting for the AMI office.</b> You asked on
                     ${esc(fmtDate(P.email_request_at))} for work: ${esc(P.email_request_work || 'unchanged')},
                     private: ${esc(P.email_request_private || 'none')}. It shows here once ARCA's records
                     are updated, usually within a working day.
                     <div style="margin-top:10px"><button class="btn btn-g btn-s" type="button" id="ewd">
                     Withdraw this request</button></div></div>`,
    done:     () => `<div class="note info" id="ereq"><b>Done.</b> Your emails were changed as you asked.</div>`,
    declined: () => `<div class="note info" id="ereq"><b>The office did not make your last change.</b>
                     ${esc(P.email_request_note || '')}</div>`,
  }[P.email_request_status];
  const hasPrivate = !!(P.alt_email && String(P.alt_email).trim());
  const choice = hasPrivate && P.preferred_email === 'private' ? 'private' : 'work';
  return `
      <div class="formcard glass" style="margin-top:26px">
        <h3>Your emails</h3>
        <div class="fsub">AMI holds a work email and a private email for you, from ARCA's records.
          Ask for a change here and the office makes it.</div>
        ${lastWord ? lastWord() : ''}
        <div class="two">
          <div class="field">
            <label for="ework">Work email</label>
            <input type="email" id="ework" autocomplete="off" value="${esc(P.email || '')}">
          </div>
          <div class="field">
            <label for="eprivate">Private email</label>
            <input type="email" id="eprivate" autocomplete="off" value="${esc(P.alt_email || '')}"
                   placeholder="None held">
          </div>
        </div>
        <div id="emsg"></div>
        <button class="btn btn-red" type="button" id="ereqbtn">${pending ? 'Replace my request' : 'Ask for this change'}</button>

        <div class="field" style="margin-top:22px">
          <label for="epref">Send AMI emails to</label>
          <select id="epref" style="width:100%;padding:11px 14px;border-radius:10px;
            border:1px solid var(--input-bd);background:var(--input-bg);color:var(--txt);
            font-family:inherit;font-size:14px">
            <option value="work"${choice === 'work' ? ' selected' : ''}>My work email${P.email ? ': ' + esc(P.email) : ''}</option>
            ${hasPrivate ? `<option value="private"${choice === 'private' ? ' selected' : ''}>My private email: ${esc(P.alt_email)}</option>` : ''}
          </select>
          <div class="hint">Every email from AMI goes here: decisions about your membership, CPD,
            the newsletter and events.${hasPrivate ? '' : ' Add a private email above to be able to choose it.'}</div>
        </div>
        <div id="epmsg"></div>
      </div>`;
}

async function askEmailChange(){
  const msg = document.getElementById('emsg');
  const work = document.getElementById('ework').value.trim();
  const priv = document.getElementById('eprivate').value.trim();
  const looks = v => !v || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v);
  if (!work && !priv) return said(msg, 'err', 'Give at least one email address.');
  if (!looks(work) || !looks(priv)) return said(msg, 'err', 'That does not look like an email address.');
  const btn = document.getElementById('ereqbtn');
  btn.disabled = true;
  const { data, error } = await sb.rpc('request_my_email_change', { p_work: work || null, p_private: priv || null });
  btn.disabled = false;
  if (error) return said(msg, 'err', /already holds|same|five requests|look like/i.test(error.message)
    ? error.message : 'That could not be sent just now. Please try again.');
  P.email_request_status = 'pending';
  P.email_request_work = data.work_email; P.email_request_private = data.private_email;
  P.email_request_at = new Date().toISOString();
  redrawEmails();
  said(document.getElementById('emsg'), 'ok', 'Sent to the AMI office. You will see it here once it is done.');
}

async function withdrawEmailChange(){
  const { error } = await sb.rpc('withdraw_my_email_change');
  if (error) return said(document.getElementById('emsg'), 'err', 'That could not be withdrawn just now.');
  P.email_request_status = null;
  redrawEmails();
  said(document.getElementById('emsg'), 'ok', 'Withdrawn. Nothing will change.');
}

async function choosePreferred(e){
  const msg = document.getElementById('epmsg');
  const was = P.preferred_email || 'work';
  const { data, error } = await sb.rpc('set_my_preferred_email', { p_choice: e.target.value });
  if (error) { e.target.value = was; return said(msg, 'err', /no private email/i.test(error.message)
    ? error.message : 'That could not be changed just now. It has been put back.'); }
  P.preferred_email = e.target.value;
  said(msg, 'ok', 'Saved. AMI now writes to ' + data + '.');
}

/* Redraws only the emails card, so nothing typed elsewhere on the page is lost. */
function redrawEmails(){
  const card = document.getElementById('ework').closest('.formcard');
  card.outerHTML = emailsCard();
  wireEmails();
}
function wireEmails(){
  document.getElementById('ereqbtn').onclick = askEmailChange;
  document.getElementById('epref').onchange = choosePreferred;
  const wd = document.getElementById('ewd'); if (wd) wd.onclick = withdrawEmailChange;
}

const ro = (label, value) => `
  <div class="field">
    <label>${esc(label)}</label>
    <input type="text" value="${esc(value || '')}" disabled>
  </div>`;

/* An address is held as jsonb, because one day a form will want the lines apart.
   A member types it as a block of text, because that is how people write an
   address. One function each way, in one place, so the two never disagree. */
function addr(v){
  if (!v) return '';
  if (typeof v === 'string') return v;
  if (Array.isArray(v.lines)) return v.lines.join('\n');
  return [v.line1, v.line2, v.town, v.county, v.postcode].filter(Boolean).join('\n');
}
function toAddr(text){
  const lines = String(text || '').split('\n').map(s => s.trim()).filter(Boolean);
  return lines.length ? { lines } : null;
}

/* ---------- the wiring ---------- */
function wire(){
  document.getElementById('save').onclick = save;
  document.querySelectorAll('.toggle').forEach(t => t.onclick = () => flip(t));
  document.getElementById('notify').onchange = e => setPrefs({ forum_notifications: e.target.value });
  document.getElementById('pw').onclick = changePassword;
  document.getElementById('dl').onclick = downloadData;
  wireEmails();
}

async function save(){
  const btn = document.getElementById('save');
  const msg = document.getElementById('msg');
  const email  = document.getElementById('email').value.trim();
  const mobile = document.getElementById('mobile').value.trim();

  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email))
    return said(msg, 'err', 'That email address does not look like an address.');

  btn.disabled = true; btn.textContent = 'Saving';
  const { error } = await sb.rpc('update_my_profile', {
    p_mobile:           mobile || null,
    p_home_address:     toAddr(document.getElementById('home').value),
    p_business_address: toAddr(document.getElementById('work').value),
  });
  btn.disabled = false; btn.textContent = 'Save changes';
  if (error) return said(msg, 'err', 'That could not be saved just now. Please try again.');

  // The address you sign in with is not a field on a record. It changes through
  // the account, with a confirmation to both addresses, or it is a way of taking
  // over somebody else's sign in.
  if (email && email.toLowerCase() !== String(SIGNIN || '').toLowerCase()) {
    const { error:e2 } = await sb.auth.updateUser({ email });
    if (e2) return said(msg, 'err', 'Your details are saved. The email address could not '
      + 'be changed: it may already be in use on another account.');
    return said(msg, 'ok', 'Saved. To finish changing your email address, follow the link '
      + 'AMI has just sent to ' + email + '. Until you do, keep signing in with the old one.');
  }
  P.mobile = mobile;
  said(msg, 'ok', 'Saved.');
}

/* A switch moves on screen first and puts itself back if the write fails. The
   alternative is a switch that does nothing for 300ms, which people press twice. */
async function flip(t){
  const k = t.dataset.k;
  const was = t.getAttribute('aria-checked') === 'true';
  t.setAttribute('aria-checked', String(!was));
  t.disabled = true;
  const ok = await setPrefs({ [k]: !was });
  t.disabled = false;
  if (!ok) { t.setAttribute('aria-checked', String(was)); return; }
  P[k] = !was;
}

/* Straight at member_preferences rather than through a function, because
   prefs_update_own already says a member may change their own row and nobody
   else's. A wrapper here would be a second rule to keep in step with that one. */
async function setPrefs(patch){
  const msg = document.getElementById('swmsg');
  const { error } = await sb.from('member_preferences').update(patch)
    .eq('member_id', P.member_id);
  if (error) {
    said(msg, 'err', 'That could not be changed just now. It has been put back.');
    return false;
  }
  msg.innerHTML = '';
  return true;
}

async function changePassword(){
  const msg = document.getElementById('pwmsg');
  const { error } = await sb.auth.resetPasswordForEmail(SIGNIN || P.email,
    { redirectTo: location.origin + '/login?reset=1' });
  said(msg, error ? 'err' : 'ok', error
    ? 'That could not be sent just now. Please try again in a moment.'
    : 'A link to set a new password is on its way to ' + (SIGNIN || P.email) + '.');
}

/* Built in the browser from the same views the member can already read, so there
   is nothing new to protect and no server side assembly that could hand back
   somebody else's record. */
async function downloadData(){
  const btn = document.getElementById('dl');
  const msg = document.getElementById('dlmsg');
  btn.disabled = true; btn.textContent = 'Gathering';
  const [profile, cpd, posts] = await Promise.all([
    sb.from('my_profile').select('*').maybeSingle(),
    sb.from('my_cpd').select('*').order('occurred_on', { ascending: false }),
    sb.from('my_posts').select('*').order('created_at', { ascending: false }),
  ]);
  btn.disabled = false; btn.textContent = 'Download my data';
  if (profile.error) return said(msg, 'err', 'That could not be gathered just now.');

  const blob = new Blob([JSON.stringify({
    exported_at: new Date().toISOString(),
    note: 'Everything the Asbestos Management Institute holds about you on the website. '
        + 'Records the office keeps elsewhere, such as correspondence, are not in here. '
        + 'Ask the office for those.',
    profile: profile.data,
    cpd:     cpd.data   || [],
    forum:   posts.data || [],
  }, null, 2)], { type: 'application/json' });

  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'AMI-my-data-' + new Date().toISOString().slice(0, 10) + '.json';
  a.click();
  URL.revokeObjectURL(a.href);
  said(msg, 'ok', 'Downloaded.');
}
