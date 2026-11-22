
/* This page is what the QR code on a membership card points at, so the thing it
   must never do is fail confusingly. Three outcomes, each said plainly:
   a current member, a slug nobody holds, and a read that failed.  */
const out = document.getElementById('out');
const slug = qs('slug') || location.pathname.replace(/^\/m\//, '');

(async () => {
  if (!slug) return notFound();
  loading(out);
  const { data, error } = await sb.from('public_profile').select('*').eq('slug', slug).maybeSingle();
  if (error) return failed(out, error, 'This member record');
  if (!data) return notFound();
  // 0026 changed this view so it answers for a membership that has been switched
  // off as well as for one that is current. A code already printed on a card
  // outlives the membership behind it, and the answer a duty holder needs is "not
  // a current member", not the same silence a mistyped address gets.
  if (!data.is_active) return notCurrent(data);
  render(data);
})();

function notFound(){
  document.title = 'Not found | AMI';
  document.getElementById('crumb').textContent = 'Not found';
  out.innerHTML = `
    <div class="glass" style="padding:40px">
      <div class="eyebrow"><span class="tri"></span>Membership</div>
      <h1 style="font-size:clamp(28px,4vw,42px);font-weight:800">This membership cannot be confirmed</h1>
      <p style="color:var(--muted);margin-top:16px;max-width:60ch">There is no current AMI member
        at this address. That means one of three things: the membership has lapsed, the link is
        mistyped, or it was never an AMI link at all.</p>
      <p style="margin-top:26px">
        <a class="btn btn-p" href="/register">Check the register</a></p>
      <p style="color:var(--muted);font-size:14px;margin-top:22px">If you are checking somebody's
        credentials and expected to find them here, the office can confirm a membership directly.</p>
    </div>`;
}

/* The membership exists, AMI holds it, and it is not current. Said as calmly as
   the yes, because a duty holder reading uncertainty into this page is the thing
   that makes it useless. The name, the number and the grade are here and nothing
   else: somebody who has left has not agreed to AMI publishing their photograph
   and their employer indefinitely. */
function notCurrent(r){
  const name = withPost(r);
  document.title = name + ' | AMI';
  document.getElementById('crumb').textContent = fullName(r);
  out.innerHTML = `
    <div class="glass" style="padding:clamp(28px,3vw,44px);max-width:720px">
      <div class="eyebrow"><span class="tri"></span>Membership</div>
      <h1 style="font-size:clamp(26px,3.6vw,40px);font-weight:800;letter-spacing:-1px">
        ${esc(name)} is not a current member of AMI</h1>
      <p style="color:var(--muted);margin-top:14px;max-width:62ch">AMI holds this membership
        number and it is not active today. That is a different answer from a code that leads
        nowhere, and it is deliberate: it means the card in your hand is a real AMI card
        rather than a forgery, and that the membership behind it has ended or lapsed.</p>
      <ul class="facts" style="margin-top:22px">
        <li><b>Membership number</b><span>${esc(r.membership_number)}</span></li>
        <li><b>Grade held</b><span>${esc(r.grade || '')}</span></li>
        <li><b>Status</b><span>Not a current member</span></li>
        <li><b>Checked</b><span>${esc(fmtDate(r.verified_at || new Date()))}</span></li>
      </ul>
      <p style="color:var(--muted);font-size:14px;margin-top:24px">AMI speaks about
        individuals. This page says what AMI holds about this person today. It is not a
        statement about their competence, their conduct or their employer.</p>
      <p style="margin-top:22px">
        <a class="btn btn-p" href="/register">Check the register</a>
        <a class="btn btn-g" href="/contact" style="margin-left:10px">Ask the office</a></p>
    </div>`;
}

function render(r){
  const name = withPost(r);
  document.title = name + ' | AMI';
  document.getElementById('crumb').textContent = fullName(r);
  const cpd = cpdLine(r);

  out.innerHTML = `
    <div class="glass profile">
      <div>
        <div class="photo blank" id="photo">${esc(initials(r))}</div>
        <p style="color:var(--muted);font-size:13px;margin-top:14px">Checked against the AMI
          record ${esc(fmtDate(r.verified_at || new Date()))}.</p>
      </div>
      <div>
        <div class="eyebrow"><span class="tri"></span>Confirmed AMI member</div>
        <h1 style="font-size:clamp(28px,4vw,44px);font-weight:800;letter-spacing:-1px">${esc(name)}</h1>
        <p style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap">
          <span class="badge-t red">${esc(r.grade || '')}</span>
          ${r.is_assessed ? '<span class="badge-t ok">Assessed grade</span>' : ''}
          ${cpd.badge}
        </p>
        <ul class="facts">
          <li><b>Membership number</b><span>${esc(r.membership_number)}</span></li>
          <li><b>Grade</b><span>${esc(r.grade || '')}${r.post_nominals ? ' (' + esc(r.post_nominals) + ')' : ''}</span></li>
          ${r.employer ? `<li><b>Employer</b><span>${esc(r.employer)}</span></li>` : ''}
          <li><b>Member since</b><span>${esc(fmtDate(r.joined_on))}</span></li>
          ${cpd.row}
        </ul>
        <p style="color:var(--muted);font-size:14px;margin-top:24px">This page is generated from
          the register and is not a copy of it.</p>
      </div>
    </div>`;

  if (r.photo_path) loadPhoto(r.photo_path, name);
}

// CPD is shown only for grades that require it. A grade that does not require it
// showing "not required" reads as a failing, which it is not.
function cpdLine(r){
  if (!r.requires_cpd) return { badge:'', row:'' };
  const met = /met|complete|up to date/i.test(r.cpd_status || '');
  return {
    badge: r.cpd_status ? `<span class="badge-t ${met ? 'ok' : ''}">${esc(r.cpd_status)}</span>` : '',
    row: `<li><b>Continuing development</b><span>${esc(r.cpd_status || 'Recorded with AMI')}${
      r.cpd_period ? ' &middot; ' + esc(r.cpd_period) : ''}</span></li>`,
  };
}

// Photographs live in a PRIVATE bucket and stay there. The member decided whether
// theirs appears here, and that decision is re-checked on every request.
//
// This asks AMI for it rather than signing a storage link in the browser, which
// is what it did until it turned out not to work for the one visitor this page
// exists for. Signing is a storage call, storage insists on a JWT, and a visitor
// with no session has only the publishable key, which is not one. A member
// looking at their own profile has a session token and signs perfectly well,
// so the switch appeared to work everywhere except where it mattered.
// The reasoning in full is above publicPhoto in _worker.js.
//
// The initials are drawn first and the photograph replaces them if it arrives, so
// a member whose photograph is switched off, or whose signing fails, gets a proper
// looking page rather than a broken image icon on their professional record.
function loadPhoto(_path, name){
  // The initials are already drawn. The picture replaces them only once it has
  // actually loaded, so a member whose photograph is switched off, or whose
  // record has just changed, gets a proper avatar rather than a broken image.
  const img = new Image();
  img.onload = () => { img.className = 'photo'; img.alt = name;
    document.getElementById('photo')?.replaceWith(img); };
  img.src = '/api/photo/p/' + encodeURIComponent(slug);
}
