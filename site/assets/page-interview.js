/* Booking the professional interview (0064).

   Reached from the private link in the invitation email:
   /interview#t=<token>. The token is after the #, which a browser never sends
   to a server, so it does not end up in Cloudflare's logs or anybody else's.
   This script reads it and posts it to the Worker, which asks the database
   whether it is a real link and asks Outlook whether each time is still free.

   There is no sign in. An applicant is not a member yet and has no account,
   and the link already proves which application this is. It shows only the
   applicant's first name and their application reference.

   Every word the database writes for the applicant (link not recognised, time
   just taken, too close to change) is shown as it comes, through esc(), never
   as markup. */

const panel = document.getElementById('panel').firstElementChild;
const token = (location.hash.match(/(?:^#|&)t=([A-Za-z0-9_-]+)/) || [])[1] || '';
let P = null;          // what the page answered
let choosing = false;  // changing an existing booking

const LONDON = { timeZone: 'Europe/London' };
const ivDay  = iso => new Date(iso).toLocaleDateString('en-GB', { ...LONDON, weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).replace(',', '');
const ivTime = iso => new Date(iso).toLocaleTimeString('en-GB', { ...LONDON, hour: '2-digit', minute: '2-digit' });
const ivWhen = iso => ivDay(iso) + ' at ' + ivTime(iso);
const ivLength = m => {
  const h = Math.floor(m / 60), r = m % 60;
  return [h ? h + (h === 1 ? ' hour' : ' hours') : '', r ? r + ' minutes' : ''].filter(Boolean).join(' ');
};

function paint(html){
  panel.innerHTML = html;
  if (typeof revealSoon === 'function') revealSoon();
}

function say(kind, text){
  const el = document.getElementById('msg');
  if (el) el.innerHTML = '<div class="note" style="color:'
    + (kind === 'err' ? 'var(--red,#E40613)' : 'inherit') + '">' + esc(text) + '</div>';
}

// Read as text first and parse second, so a page that is not JSON (an outage
// page, say) still gives us something to say rather than a silent failure.
async function call(which, body){
  try {
    const res = await fetch('/api/interview/' + which, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.assign({ token }, body || {})) });
    const text = await res.text();
    let out = null; try { out = JSON.parse(text); } catch {}
    return { ok: res.ok, status: res.status, out: out || {} };
  } catch {
    return { ok: false, status: 0, out: { error: 'The site could not be reached. Please check your connection and try again.' } };
  }
}

function problem(text){
  paint(`
    <h2 style="margin-bottom:10px">We cannot show the interview times</h2>
    <p class="note">${esc(text)}</p>
    <p class="note" style="margin-top:10px">If this keeps happening, reply to your
       invitation email and the office will arrange a time with you.</p>
    <div class="row-between" style="gap:10px;margin-top:20px">
      <a class="btn btn-g" href="/contact">Contact the office</a>
    </div>`);
}

async function load(){
  if (!token) return problem('This link is not complete. Please open it again from your invitation email.');
  const r = await call('slots');
  if (!r.ok) return problem(r.out.error || 'Something went wrong. Please try again in a few minutes.');
  P = r.out;
  draw();
}

function draw(){
  const b = P.booking;
  if (b && !choosing) return drawBooked(b);

  const slots = P.slots || [];
  const days = [];
  slots.forEach(s => {
    const d = ivDay(s.starts_at);
    if (!days.length || days[days.length - 1].d !== d) days.push({ d, slots: [] });
    days[days.length - 1].slots.push(s);
  });

  paint(`
    <p class="note" style="margin-bottom:6px">${P.given_name ? 'Hello ' + esc(P.given_name) + '. ' : ''}Application
       <b>${esc(P.reference || '')}</b>.</p>
    <h2 style="margin:6px 0 4px">${b ? 'Choose a new time' : 'Choose a time'}</h2>
    <p class="note">All times are UK time. Each interview lasts about
       ${esc(ivLength((slots[0] && slots[0].minutes) || 75))}.</p>
    ${b ? `<p class="note" style="margin-top:8px">Your current time is <b>${esc(ivWhen(b.starts_at))}</b>. It stays booked until you confirm a new one.</p>` : ''}
    <div id="days" style="margin-top:18px">
      ${days.length ? days.map(g => `
        <div style="margin-bottom:18px">
          <h5 style="margin-bottom:8px">${esc(g.d)}</h5>
          <div style="display:flex;flex-wrap:wrap;gap:8px">
            ${g.slots.map(s => `<button class="btn btn-g btn-s" type="button" data-slot="${esc(s.id)}">${esc(ivTime(s.starts_at))}</button>`).join('')}
          </div>
        </div>`).join('')
      : `<p class="note">There are no times available just now. Please reply to your
           invitation email and we will find one with you.</p>`}
    </div>
    <div id="confirm"></div>
    <div id="msg" style="margin-top:12px"></div>
    ${b ? '<div style="margin-top:16px"><button class="btn btn-g" type="button" id="back">Keep my current time</button></div>' : ''}`);

  panel.querySelectorAll('[data-slot]').forEach(btn => btn.onclick = () => pick(btn.dataset.slot));
  const back = document.getElementById('back');
  if (back) back.onclick = () => { choosing = false; draw(); };
}

function pick(id){
  const s = (P.slots || []).find(x => x.id === id);
  if (!s) return;
  panel.querySelectorAll('[data-slot]').forEach(btn => btn.classList.toggle('on', btn.dataset.slot === id));
  document.getElementById('confirm').innerHTML = `
    <div class="callout" style="margin-top:6px">
      <b>${esc(ivWhen(s.starts_at))}</b>
      <p>${esc(ivLength(s.minutes))}, on Microsoft Teams.</p>
      <div style="margin-top:12px"><button class="btn btn-red" type="button" id="book">Book this time</button></div>
    </div>`;
  say('ok', '');
  document.getElementById('book').onclick = () => book(s);
}

async function book(s){
  const btn = document.getElementById('book');
  btn.disabled = true;
  btn.textContent = 'Booking';
  const r = await call('book', { slot: s.id });
  if (!r.ok) {
    btn.disabled = false;
    btn.textContent = 'Book this time';
    say('err', r.out.error || 'The booking did not go through. Please try again.');
    // A time somebody else has just taken: show the list as it is now.
    if (r.status === 409) {
      const again = await call('slots');
      if (again.ok) { P = again.out; draw(); say('err', r.out.error); }
    }
    return;
  }
  choosing = false;
  P.booking = { starts_at: r.out.starts_at, ends_at: r.out.ends_at, minutes: s.minutes,
                join_url: r.out.join_url, can_change: true };
  drawBooked(P.booking, true);
}

function drawBooked(b, justNow){
  const teams = b.join_url && /^https:\/\/teams\.(microsoft|live)\.com\//.test(b.join_url);
  paint(`
    <h2 style="margin-bottom:8px">${justNow ? 'Your interview is booked' : 'Your interview'}</h2>
    <p style="font-size:1.15em;margin:4px 0 8px"><b>${esc(ivWhen(b.starts_at))}</b></p>
    <p class="note">${esc(ivLength(b.minutes || 75))}, on Microsoft Teams. ${justNow
      ? 'We have emailed you to confirm, and a calendar invitation with the joining link is on its way.'
      : 'Your confirmation email and calendar invitation have the joining link.'}</p>
    ${teams ? `<div style="margin-top:14px"><a class="btn btn-g" href="${esc(b.join_url)}" rel="noopener" target="_blank">Join on Teams</a></div>` : ''}
    <div id="msg" style="margin-top:14px"></div>
    ${b.can_change ? `
      <div class="row-between" style="gap:10px;margin-top:20px">
        <button class="btn btn-g" type="button" id="change">Change the time</button>
        <button class="btn btn-g" type="button" id="cancel">Cancel the interview</button>
      </div>`
    : `<p class="note" style="margin-top:16px">It is too close to change online now. If you
         need to, please reply to your invitation email.</p>`}`);

  const ch = document.getElementById('change');
  if (ch) ch.onclick = async () => {
    const r = await call('slots');
    if (r.ok) P = r.out;
    choosing = true;
    draw();
  };
  const cn = document.getElementById('cancel');
  if (cn) cn.onclick = () => confirmCancel(cn);
}

// Asked twice on the page rather than with confirm(), which some phones block.
function confirmCancel(btn){
  if (btn.dataset.sure !== 'yes') {
    btn.dataset.sure = 'yes';
    btn.textContent = 'Yes, cancel it';
    say('ok', 'Press again to cancel your interview. You can book another time afterwards.');
    return;
  }
  btn.disabled = true;
  call('cancel').then(async r => {
    if (!r.ok) { btn.disabled = false; return say('err', r.out.error || 'The interview was not cancelled. Please try again.'); }
    const again = await call('slots');
    P = again.ok ? again.out : Object.assign(P, { booking: null });
    P.booking = null;
    choosing = false;
    draw();
    say('ok', 'Your interview has been cancelled and we have emailed you to confirm. Choose another time whenever you are ready.');
  });
}

window.addEventListener('hashchange', () => location.reload());
load();
