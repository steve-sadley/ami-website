
/* Signs a member in and sends them where they were going.

   The members pages send an unsigned in visitor here with ?next= carrying the
   address they wanted, so somebody who followed a link to their CPD record ends
   up at their CPD record rather than at a landing page having forgotten why they
   came. The value is checked before it is used: it has to be a path on this site,
   or a sign in link becomes a way of bouncing somebody to another site with AMI's
   name on the button.

   showRecord() is still here and still does its job. It is what a signed in
   person sees when their account is not attached to a membership, which is a
   real state and not an error. */

const out = document.getElementById('out');

// A path on this site, beginning with a single slash. Anything else, including
// //evil.example and https://evil.example, becomes /me. Browsers drop tabs and
// line breaks from an address, so /<tab>/evil.example would have become
// //evil.example after the check (found by the security check, 31 October):
// any control character or backslash is refused, and the address is read the
// way the browser will read it and must still be on this site.
function nextPath(){
  const raw = qs('next') || '';
  if (!/^\/[^/\\]/.test(raw) || /[\u0000-\u001f\u007f\\]/.test(raw)) return '/me';
  try {
    const u = new URL(raw, location.origin);
    return u.origin === location.origin ? u.pathname + u.search + u.hash : '/me';
  } catch (e) { return '/me'; }
}

/* SETTING A NEW PASSWORD (site 77, 1 November 2026). Found by Steve: the
   reset email's link came back here and simply signed the member in. Nothing
   ever asked for the new password, so "forgotten password" could not work even
   when the email arrived. The link now comes back with ?reset=1, and Supabase
   also announces PASSWORD_RECOVERY; either way the member is asked for the new
   password before going anywhere. */
const RESETTING = qs('reset') === '1';
try {
  sb.auth.onAuthStateChange(ev => { if (ev === 'PASSWORD_RECOVERY') showNewPassword(); });
} catch (e) { /* the page still works for an ordinary sign in */ }

sb.auth.getSession().then(({ data }) => {
  if (RESETTING) return data.session ? showNewPassword()
    : showForm('That link has expired or has already been used. Ask for a new one below.');
  return data.session ? arrive() : showForm();
});

let newPasswordShown = false;
function showNewPassword(){
  if (newPasswordShown) return;
  newPasswordShown = true;
  out.innerHTML = `
    <div class="login-wrap">
      <form class="login-card glass" id="npform" method="post">
        <h2>Set a new password</h2>
        <div class="lsub">At least 12 characters, with a capital letter, a small letter and
          a number. A few words strung together with a number is easier to remember than a
          short jumble, for example Kettle-Harbour-Lantern-42.</div>
        <div class="field">
          <label for="np1">New password</label>
          <input type="password" id="np1" autocomplete="new-password" required>
        </div>
        <div class="field">
          <label for="np2">The same again</label>
          <input type="password" id="np2" autocomplete="new-password" required>
        </div>
        <div id="msg"></div>
        <button class="btn btn-red" type="submit" id="npgo">Save my new password</button>
      </form>
    </div>`;
  document.getElementById('npform').onsubmit = async e => {
    e.preventDefault();
    const a = document.getElementById('np1').value, b = document.getElementById('np2').value;
    // The same rules Supabase is set to (Authentication, Email, 1 November 2026):
    // 12 characters, with a capital, a small letter and a digit. Checked here
    // first so the member is told which part is missing, in words.
    if (a.length < 12) return say('err', 'Please use at least 12 characters.');
    if (!/[A-Z]/.test(a) || !/[a-z]/.test(a) || !/[0-9]/.test(a))
      return say('err', 'Please include a capital letter, a small letter and a number.');
    if (a !== b) return say('err', 'The two do not match. Please type them again.');
    const btn = document.getElementById('npgo');
    btn.disabled = true; btn.textContent = 'Saving';
    const { error } = await sb.auth.updateUser({ password: a });
    btn.disabled = false; btn.textContent = 'Save my new password';
    // Leaked first: Supabase's words for it end "choose a different one", which
    // the same-password test would otherwise catch.
    const why = error ? error.message + ' ' + (error.code || '') : '';
    if (error) return say('err', /pwned|leak|breach|weak_password|known to be weak/i.test(why)
      ? 'That password has appeared in a data breach somewhere, so it is not safe to use. Please choose another.'
      : /different from the old|same_password/i.test(why)
      ? 'That is the password you already have. Please choose a new one.'
      : 'That could not be saved. The link may have expired: ask for a new one from the sign in page.');
    say('ok', 'Saved. Signing you in.');
    setTimeout(arrive, 700);
  };
}

/* Signed in. If AMI holds a membership for this account, go to the members area.
   If it does not, showRecord() explains why rather than bouncing them into a
   members area that would have nothing to show. */
async function arrive(){
  loading(out);
  await sb.rpc('link_account');
  const { data } = await sb.rpc('whoami');
  const me = Array.isArray(data) ? data[0] : data;
  if (me && me.member_id) { location.replace(nextPath()); return; }
  showRecord();
}

function showForm(msg){
  out.innerHTML = `
    <div class="login-wrap">
      <form class="login-card glass" id="form" method="post">
        <h2>Welcome back</h2>
        <div class="lsub">Sign in with the email address AMI holds for you</div>

        <div class="field">
          <label for="email">Email address</label>
          <input type="email" id="email" autocomplete="username" required>
        </div>
        <div class="field">
          <label for="pw">Password</label>
          <input type="password" id="pw" autocomplete="current-password" required>
        </div>

        <div class="row-between">
          <label><input type="checkbox" id="remember" checked> Keep me signed in</label>
          <a href="#" id="forgot">Forgotten your password?</a>
        </div>

        <div id="msg">${msg ? `<div class="note err">${esc(msg)}</div>` : ''}</div>
        <button class="btn btn-red" type="submit" id="go">Sign in</button>

        <div class="divider">or</div>
        <button class="btn btn-g" type="button" id="magic">Email me a sign in link</button>

        <div class="login-foot">Not a member yet? <a href="/apply">Apply to join</a></div>
      </form>
    </div>`;

  document.getElementById('form').onsubmit = e => { e.preventDefault(); signIn(); };
  document.getElementById('magic').onclick = magicLink;
  document.getElementById('forgot').onclick = e => { e.preventDefault(); reset(); };
}

const emailBox = () => document.getElementById('email').value.trim();
const say = (kind, text) =>
  document.getElementById('msg').innerHTML = `<div class="note ${kind}">${esc(text)}</div>`;

async function signIn(){
  const btn = document.getElementById('go');
  btn.disabled = true; btn.textContent = 'Signing in';
  const { error } = await sb.auth.signInWithPassword({
    email: emailBox(),
    password: document.getElementById('pw').value,
  });
  if (error) {
    // Deliberately not saying which of the two was wrong. Telling somebody the
    // address exists but the password does not is telling them the address exists.
    btn.disabled = false; btn.textContent = 'Sign in';
    say('err', 'That email address and password do not match an AMI account.');
    return;
  }
  arrive();
}

/* The same answer whether or not the address is one AMI holds, for the same
   reason: an answer that differs is a way of asking whether somebody is a member. */
async function magicLink(){
  const email = emailBox();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email))
    return say('err', 'Please put your email address in first.');
  // Answered at once, and sent in the background. The answer is the same
  // whatever happens (see above), and Supabase does not reply until its email
  // has been handed over, which took 45 seconds on 1 November. The button stays
  // off for a minute so it is not pressed again in the meantime.
  const btn = document.getElementById('magic');
  btn.disabled = true;
  sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + '/login?next=' + encodeURIComponent(nextPath()) } })
    .catch(() => {});
  setTimeout(() => { btn.disabled = false; }, 60000);
  say('ok', 'If that address is one AMI holds, a sign in link is on its way to it. It can take a minute or two.');
}

async function reset(){
  const email = emailBox();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email))
    return say('err', 'Please put your email address in first, then ask again.');
  // Answered at once and sent in the background, as magicLink() is.
  sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + '/login?reset=1' }).catch(() => {});
  say('ok', 'If that address is one AMI holds, a link to set a new password is on its way to it. It can take a minute or two.');
}

async function showRecord(){
  loading(out);
  // Joins the account to the person record the office created, if it has not
  // been joined already. Harmless to call twice.
  await sb.rpc('link_account');
  const { data } = await sb.rpc('whoami');
  const me = Array.isArray(data) ? data[0] : data;

  if (!me) {
    out.innerHTML = `<div class="login-wrap" style="max-width:640px">
      <div class="login-card glass">
        <h2>Signed in, but not on the AMI record</h2>
        <div class="lsub">This address is not one AMI holds.</div>
        <p style="color:var(--muted);margin-bottom:24px">If you have applied recently, the
          office creates the record when the application is approved.</p>
        <button class="btn btn-g" id="out2">Sign out</button>
      </div></div>`;
    document.getElementById('out2').onclick = signOutHere;
    return;
  }

  const { data:m } = await sb.from('members')
    .select('membership_number, joined_on, is_active, status, membership_grades(name, post_nominals)')
    .maybeSingle();

  out.innerHTML = `
    <div class="glass" style="padding:clamp(26px,3vw,44px);max-width:760px;margin:0 auto">
      <div class="eyebrow"><span class="tri"></span>Members</div>
      <h1 style="font-size:clamp(26px,4vw,38px);font-weight:800">
        ${esc([me.given_name, me.family_name].filter(Boolean).join(' ') || me.email)}</h1>
      ${m ? `
        <p style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap">
          <span class="badge-t red">${esc(m.membership_grades?.name || '')}</span>
          <span class="badge-t ${m.is_active ? 'ok' : ''}">${m.is_active ? 'Active' : 'Not active'}</span>
        </p>
        <ul class="facts">
          <li><b>Membership number</b><span>${esc(m.membership_number)}</span></li>
          <li><b>Member since</b><span>${esc(fmtDate(m.joined_on))}</span></li>
          <li><b>Status</b><span>${esc(String(m.status).replace(/_/g,' '))}</span></li>
        </ul>`
      : `<p style="color:var(--muted);margin-top:14px">AMI holds a record for you, but no
           membership is attached to it yet.</p>`}

      <div class="note info" style="margin-top:26px">
        <b>Your account is not attached to a membership.</b><br>
        AMI holds a record for you and no membership sits against it. If you have applied
        recently, the office creates the membership when the application is approved. If you
        think this is wrong, the office can put it right.
      </div>

      <p style="margin-top:8px">
        <a class="btn btn-g" href="/register">Check the register</a>
        <button class="btn btn-g" id="out2" style="margin-left:10px">Sign out</button></p>
    </div>`;
  document.getElementById('out2').onclick = signOutHere;
}

// Not signOut: site.js has one, and on this page the two shared a global scope,
// so this silently replaced it. Found by test 12 on 30 October.
async function signOutHere(){ await sb.auth.signOut(); location.reload(); }
