/* =============================================================================
   My membership card

   The card is a claim about a person, so the only thing on it that matters is
   the code, because the code is what lets somebody check the claim rather than
   believe it. Everything else on the card is there to be read at a gate by a
   person in a hurry.

   The code is built here, in the browser, from location.origin. That means the
   same page produces a staging code on staging and a live code on ami.uk.com,
   with nothing to remember and nothing to change at cutover.

   Two wallets, and they are not the same thing, so they are not presented as
   though they are. Apple hands over a file, signed with a certificate AMI does
   not own yet. Google creates the pass through an API call and hands back a link.
   Both buttons say what they are waiting for rather than failing when pressed.
   ============================================================================= */

const out = document.getElementById('out');
let C = null;

// What is actually available is asked of the Worker rather than written here, so
// adding the bindings to Cloudflare is the whole deployment step. Until the
// answer arrives, both are assumed off, because a button that works for a moment
// and then stops is worse than one that was never offered.
let READY = { apple: false, google: false };

// What each wallet is waiting for, shown only while it is waiting.
const WAITING = {
  apple: 'AMI is waiting on an Apple Pass Type ID certificate, which is what signs '
       + 'the file Apple will accept. Nothing else is outstanding.',
  google: 'AMI is waiting on a Google Wallet issuer account. Google creates the pass '
        + 'at its end rather than handing over a file, so there is nothing to download '
        + 'until that exists.',
};

(async () => {
  await memberChrome('/card');
  READY = await fetch('/api/pass/status')
    .then(r => r.ok ? r.json() : READY)
    .catch(() => READY);
  const { data, error } = await sb.from('my_card').select('*').maybeSingle();
  if (error) return failed(out, error, 'Your membership card');
  if (!data)  return out.innerHTML = '<div class="state"><p>AMI holds no membership for '
    + 'this account yet.</p></div>';
  C = data;
  draw(await photoUrl(C.photo_strip_path));
})();

const verifyUrl = () => C.slug ? location.origin + '/m/' + encodeURIComponent(C.slug) : null;

function draw(strip){
  const url = verifyUrl();

  out.innerHTML = `
    <section class="pbanner" style="padding:10px 0 24px">
      <div class="eyebrow"><span class="tri"></span>Membership card</div>
      <h1>My card</h1>
      <p>Your card lives on your phone. Anyone who scans the code on it lands on a page
         that either confirms your membership or says plainly that it cannot.</p>
    </section>

    ${C.is_active ? '' : `<div class="note info" style="margin-bottom:22px">
      <b>A card can only be issued while the membership is active.</b> Yours is not
      currently active, so the buttons below are off and the code on any card you already
      hold now answers that you are not a current member. The office can tell you why, and
      <a href="/contact" style="color:var(--link);font-weight:700">they are the people to
      ask</a>.</div>`}

    <div class="cardgrid">
      <div>
        ${cardFace(strip)}
        <div class="callout" style="margin-top:16px">
          <b>One code only.</b> Apple shows a single barcode on a pass, so the card carries
          the verification link and nothing else. A second code, for sharing your CPD record,
          belongs in the members area rather than on the card.
        </div>
        ${C.serial_number ? `<div class="callout">
          <b>This card's number is ${esc(C.serial_number)}.</b> Issued
          ${esc(fmtDate(C.pass_issued_at))}${C.times_issued > 1
            ? ', and it is number ' + C.times_issued + ' you have had. Only the newest one works.'
            : '.'}
        </div>` : ''}
      </div>

      <div>
        <div class="head-left sec-head" style="margin-bottom:16px">
          <div class="eyebrow"><span class="tri"></span>Add it to your phone</div>
          <h2>Two wallets, two different things</h2>
        </div>

        ${wallet('apple', '&#63743;', 'Add to Apple Wallet',
          'Downloads a pass file that opens straight into Wallet. It works on iPhone and '
          + 'Apple Watch, and it updates on its own when AMI changes something.')}

        ${wallet('google', 'G', 'Save to Google Wallet',
          'Not a file. AMI creates the pass through Google and hands you a link, so this '
          + 'takes a moment and then opens Wallet for you.', 'g')}

        <div class="wbtn">
          <div class="wic" style="background:rgba(255,255,255,.1)">&#8681;</div>
          <div class="wt">
            <b>Print it</b>
            <span>For a site office that asks for a paper copy at the gate. It prints as a
              plain card on white rather than as a screenshot of this page.</span>
          </div>
          <button class="btn btn-g btn-s" type="button" id="print"
            ${url ? '' : 'disabled'}>Print</button>
        </div>

        <div class="callout">
          <b>${C.serial_number ? 'If you lose your phone, reissue the card.' : 'Issue your card.'}</b>
          ${C.serial_number
            ? 'You get a new card number, and the old card stops being the one AMI '
              + 'recognises. Installing the new pass and removing the old one from your '
              + 'wallet are both done by you, because Apple gives AMI no way to reach a '
              + 'pass once it is on a phone. You can reissue as often as you need to.'
            : 'It takes one press. The code on it is what lets anybody check your membership '
              + 'against the AMI record.'}
          <div style="margin-top:14px">
            <button class="btn btn-red btn-s" type="button" id="issue"
              ${C.is_active ? '' : 'disabled'}>
              ${C.serial_number ? 'Reissue my card' : 'Issue my card'}</button>
          </div>
          <div id="imsg"></div>
        </div>

        <div class="callout">
          <b>Your photograph is on the card by default.</b> Whether it also appears to
          somebody who scans it is a separate switch on
          <a href="/profile" style="color:var(--link);font-weight:700">your profile</a>, and
          it is off until you turn it on.
        </div>
      </div>
    </div>

    <section style="padding:36px 0 0">
      <div class="head-left sec-head">
        <div class="eyebrow"><span class="tri"></span>Three states</div>
        <h2>What the card looks like, and when</h2>
        <p style="max-width:70ch">Apple gives no design control over the back of a pass, so
           everything that matters has to be on the front. These are the three fronts, and
           which one you get depends on what AMI holds rather than on anything you choose
           here.</p>
      </div>
      <div class="states">
        ${state(strip && C.photo_strip_path, 'With a photograph',
          'The settled design. A person at a gate can match the face to the card without '
          + 'asking for a second document.',
          strip ? `background-image:url('${encodeURI(strip)}')` : '')}
        ${state(!C.photo_strip_path && C.scopes && C.scopes.length, 'Verified scopes',
          'Where there is no photograph, the verified scopes of practice fill the space. '
          + 'Still useful, still specific. Verified scope is deferred out of phase 1, so '
          + 'nobody has this one yet.',
          'background:linear-gradient(150deg,#232932,#12151b)',
          C.scopes && C.scopes.length ? C.scopes.join(' · ') : 'Licensed removal · Analysis')}
        ${state(!C.photo_strip_path && !(C.scopes && C.scopes.length), 'Brand only',
          'No photograph and no verified scopes. The card still works and still verifies. '
          + 'It just says less.',
          'background:#12151b', 'ami')}
      </div>
    </section>`;

  wire(url);
}

/* A logo that fails to load is hidden rather than shown as a broken image.
   This used to be onerror="" written into the markup, which the site's content
   security policy refuses to run, so the fallback had never worked on a
   deployed page. One listener, in this file, which the policy allows. Found by
   test 21 on 30 October. */
document.addEventListener('error', e => {
  const t = e.target;
  if (t && t.tagName === 'IMG' && t.closest('.mcard-face')) t.style.display = 'none';
}, true);

function cardFace(strip){
  const total = Number(C.cpd_core || 0) + Number(C.cpd_non_core || 0);
  return `
    <div class="mcard-face" id="face">
      <div class="cbrand">
        <img src="/assets/ami-logo-white.png?v=70" alt="AMI">
        <span class="st ${C.is_active ? '' : 'off'}">${C.is_active ? 'Active' : 'Not active'}</span>
      </div>

      <div class="strip" ${strip ? `style="background-image:url('${encodeURI(strip)}')"` : ''}>
        ${!strip ? (C.scopes && C.scopes.length
          ? `<div class="scopes">${esc(C.scopes.join(' · '))}</div>`
          : `<div class="brandonly"><img src="/assets/ami-logo-white.png?v=70" alt=""></div>`) : ''}
      </div>

      <!-- The name sits BELOW the picture rather than on it, because that is what
           the wallet pass does and the two have to be the same card. Apple draws
           its own lettering over the strip, at a size AMI does not control, and
           gives nothing a chance to sit between the two. -->
      <div class="cname">
        <span class="gr">${esc([C.grade, C.grade_post_nominals].filter(Boolean).join(' · '))}</span>
        <span class="nm">${esc(fullName(C))}</span>
      </div>

      <div class="crows">
        <div><span class="k">Membership no</span><span class="v">${esc(C.membership_number)}</span></div>
        <div><span class="k">Member since</span><span class="v">${esc(shortDate(C.joined_on))}</span></div>
        ${C.requires_cpd ? `<div><span class="k">CPD ${YEAR}</span>
          <span class="v">${total} of ${C.cpd_required_total}</span></div>` : ''}
        <div><span class="k">Card</span><span class="v">${
          C.serial_number ? 'Issued' : 'Not issued'}</span></div>
      </div>

      <div class="qr">
        <div class="box" id="qrbox"></div>
        <p>${C.slug
          ? 'Scan to check this membership against the AMI register<br>'
            + esc(location.host + '/m/' + C.slug)
          : 'This membership has no public address yet, so there is nothing for a code to '
            + 'point at. The office sets one.'}</p>
      </div>
    </div>`;
}

function wallet(key, icon, title, words, cls){
  const waiting = READY[key] ? null : WAITING[key];
  return `
    <div class="wbtn">
      <div class="wic ${cls || ''}">${icon}</div>
      <div class="wt">
        <b>${esc(title)}</b>
        <span>${esc(words)}${waiting ? ' ' + esc(waiting) : ''}</span>
      </div>
      <button class="btn ${waiting ? 'btn-g' : 'btn-p'} btn-s" type="button"
        data-wallet="${key}" ${waiting || !C.is_active ? 'disabled' : ''}>
        ${waiting ? 'Not yet' : (key === 'apple' ? 'Add' : 'Save')}</button>
    </div>`;
}

function state(isMine, title, words, style, label){
  return `
    <div class="state-c glass-soft">
      <div class="mini" style="${style};background-position:center 18%">${esc(label || '')}</div>
      <h5>${esc(title)}${isMine ? ' — yours' : ''}</h5>
      <p>${esc(words)}</p>
    </div>`;
}

const shortDate = v => {
  const d = new Date(v);
  return isNaN(d) ? '' : d.toLocaleDateString('en-GB', { month:'short', year:'numeric' });
};

/* ---------- the code ---------- */
/* Drawn rather than fetched. A QR code from an image service is a picture of a
   member's address held on somebody else's server, and it stops working the day
   that service does. This is 21KB and it works offline. */
function drawQr(url, box, dark){
  if (!url || !box) return;
  const q = qrcode(0, 'M');            // version 0 means pick the smallest that fits
  q.addData(url);
  q.make();
  const n = q.getModuleCount();
  const rects = [];
  for (let y = 0; y < n; y++)
    for (let x = 0; x < n; x++)
      if (q.isDark(y, x)) rects.push(`<rect x="${x}" y="${y}" width="1" height="1"/>`);
  box.innerHTML = `<svg viewBox="0 0 ${n} ${n}" xmlns="http://www.w3.org/2000/svg"
    shape-rendering="crispEdges" fill="${dark || '#0f1116'}"
    role="img" aria-label="Code linking to ${esc(url)}">${rects.join('')}</svg>`;
}

/* ---------- the wiring ---------- */
function wire(url){
  drawQr(url, document.getElementById('qrbox'));
  buildPrintCard(url);

  document.querySelectorAll('[data-wallet]').forEach(b => b.onclick = () => addToWallet(b));
  const pr = document.getElementById('print');
  if (pr) pr.onclick = () => window.print();
  document.getElementById('issue').onclick = issue;
}

/* Apple hands over a file, so this asks the Worker for one and lets the browser
   do what it does with a .pkpass, which on an iPhone is open Wallet. It is a POST
   because it issues a card: a GET that changes something is a GET a link checker
   or a mail client will fire on the member's behalf. */
async function addToWallet(btn){
  const key = btn.dataset.wallet;
  const msg = document.getElementById('imsg');
  if (!READY[key]) return;

  btn.disabled = true; btn.textContent = 'Preparing';
  try {
    const { data:{ session } } = await sb.auth.getSession();
    const r = await fetch('/api/pass/' + key, {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + session.access_token },
    });

    if (!r.ok) {
      const out = await r.json().catch(() => ({}));
      btn.disabled = false; btn.textContent = key === 'apple' ? 'Add' : 'Save';
      return said(msg, 'err', out.error || 'That could not be done just now.');
    }

    if (key === 'google') {
      const { saveUrl } = await r.json();
      location.href = saveUrl;
      return;
    }

    /* WHY THIS IS A NAVIGATION AND NOT A DOWNLOAD. 23 August 2026.

       This used to build an anchor with a `download` attribute, click it, and
       revoke the object URL on the next line. On a desktop that downloads a
       file. On an iPhone it does nothing you can see: the download attribute
       sends the file to Files rather than to Wallet, the click happens after two
       awaits so the user gesture that would have permitted it has expired, and
       revoking the URL immediately can pull the blob away before Safari has read
       it. Three faults, one silent outcome.

       It was found by AirDropping the identical file to the phone and watching it
       open into Wallet at once. The pass was never at fault.

       Navigating to the blob lets Safari treat it as what its type says it is,
       which for application/vnd.apple.pkpass means handing it to Wallet. The URL
       is revoked on a timer rather than immediately, because the browser reads it
       after this function has finished. */
    const blob = await r.blob();
    const href = URL.createObjectURL(blob);
    setTimeout(() => URL.revokeObjectURL(href), 60000);

    btn.disabled = false; btn.textContent = 'Add';
    said(msg, 'ok', 'Your card is on its way to Wallet. On an iPhone it opens by itself. '
      + 'On a computer it downloads as a file, and AirDropping that file to your phone '
      + 'installs it just as well.');

    location.href = href;
    return;

    const { data:fresh } = await sb.from('my_card').select('*').maybeSingle();
    if (fresh) { C = fresh; draw(await photoUrl(C.photo_strip_path)); }
  } catch (e) {
    btn.disabled = false; btn.textContent = key === 'apple' ? 'Add' : 'Save';
    said(msg, 'err', 'That could not be done just now. Please try again in a moment.');
  }
}

async function issue(){
  const btn = document.getElementById('issue');
  const msg = document.getElementById('imsg');
  const first = !C.serial_number;

  if (!first && !window.confirm('Reissue your card? You will get a new card number, and '
      + 'you then have to install the new pass and remove the old one from your wallet '
      + 'yourself.')) return;

  btn.disabled = true; btn.textContent = first ? 'Issuing' : 'Reissuing';
  const { data, error } = await sb.rpc('issue_my_card', { p_platform: 'apple' });
  btn.disabled = false;

  if (error) {
    btn.textContent = first ? 'Issue my card' : 'Reissue my card';
    return said(msg, 'err', /active/.test(String(error.message || ''))
      ? 'A card can only be issued while the membership is active.'
      : 'That could not be done just now. Please try again in a moment.');
  }

  /* What this message used to say was written before the certificate existed and
     was left behind when it arrived: it told a member the pass would go into
     their wallet once the certificate was in place, which it now is, and it does
     not. Issuing mints the record. Downloading the pass is a separate press.

     It also said any card you already had had stopped working, which is only
     half true and the wrong half. A pass already installed does not change and
     is not removed, because Apple only reaches an installed pass through the
     update service, which AMI has not built. What has stopped is the pass's own
     token. The QR code on the old card is an address to a public record and goes
     on resolving, so telling somebody their old card is dead when it is sitting
     on their phone looking perfectly alive is the sort of thing that gets AMI
     rung up. 23 August 2026. */
  const r = Array.isArray(data) ? data[0] : data;
  const note = (first ? 'Issued.' : 'Reissued.')
    + ` The card number is ${r.serial_number}.`
    + (READY.apple
        ? (first
            ? ' Press Add to Apple Wallet above to put it on your phone.'
            : ' The card already on your phone does NOT change by itself. Press Add to '
              + 'Apple Wallet above to install this one, then remove the old one from '
              + 'Wallet by hand: on the pass, tap the three dots, then Remove Pass.')
        : ' Apple Wallet is not switched on yet, so there is no file to install. The code '
          + 'on this page and the printed card both work.');

  // The page is redrawn because the card face now shows a serial and the button
  // now says reissue. Redrawing replaces #imsg with an empty one, so the message
  // is written AFTER the redraw rather than before it, or the member presses a
  // button and is told nothing.
  const { data:fresh } = await sb.from('my_card').select('*').maybeSingle();
  if (fresh) { C = fresh; draw(await photoUrl(C.photo_strip_path)); }
  said(document.getElementById('imsg'), 'ok', note);
}

/* The paper version. A dark card on white paper is a rectangle of ink and a code
   a scanner struggles with, so print gets a light card of its own. */
function buildPrintCard(url){
  const el = document.getElementById('printcard');
  const total = Number(C.cpd_core || 0) + Number(C.cpd_non_core || 0);
  el.innerHTML = `
    <div class="pc">
      <img class="brand" src="/assets/ami-logo.webp?v=70" alt="AMI">
      <div class="g">${esc([C.grade, C.grade_post_nominals].filter(Boolean).join(' · '))}</div>
      <h1>${esc(fullName(C))}</h1>
      <div class="row"><span>Membership number</span><b>${esc(C.membership_number)}</b></div>
      <div class="row"><span>Member since</span><b>${esc(fmtDate(C.joined_on))}</b></div>
      ${C.requires_cpd ? `<div class="row"><span>CPD ${YEAR}</span>
        <b>${total} of ${C.cpd_required_total} points</b></div>` : ''}
      <div class="row"><span>Status</span>
        <b>${C.is_active ? 'Current member' : 'Not a current member'}</b></div>
      <div class="qr" id="printqr"></div>
      <div class="foot">Scan to check this membership against the AMI register.<br>
        ${url ? esc(url.replace(/^https?:\/\//, '')) : ''}<br>
        Printed ${esc(fmtDate(new Date()))}. A printed card cannot be withdrawn, so check
        the code rather than the paper.</div>
    </div>`;
  drawQr(url, document.getElementById('printqr'), '#000');
}
