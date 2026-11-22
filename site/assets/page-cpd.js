/* =============================================================================
   My CPD

   Two numbers decide whether a member has met the requirement, so they are the
   two largest things on the page and everything else explains them.

   The column that matters most is how each point arrived. A scheme that cannot
   say where a line came from is a list of claims, and the whole argument for
   publishing a CPD figure on a public register is being able to answer that
   question for every line.

   Nothing here can make a point count. A member logs an activity and it arrives
   pending; the office accepts it. That is enforced by the policies in 0007 and by
   log_cpd taking is_core from the activity type rather than from the member, and
   this page could not get around either of them if it tried.
   ============================================================================= */

const out = document.getElementById('out');
let P = null, TYPES = [], YEARS = [], showing = YEAR;

(async () => {
  await memberChrome('/cpd');

  const [profile, types, summaries] = await Promise.all([
    sb.from('my_profile').select('*').maybeSingle(),
    sb.from('cpd_activity_types')
      .select('id, code, name, is_core, sort_order, points, min_words, member_can_log, needs_evidence, guidance')
      .eq('active', true).order('sort_order'),
    sb.from('my_cpd_summary').select('*').order('year', { ascending: false }),
  ]);

  if (profile.error) return failed(out, profile.error, 'Your CPD record');
  P = profile.data;
  if (!P) return out.innerHTML = '<div class="state"><p>AMI holds no membership for this '
    + 'account yet.</p></div>';

  // Only what a member can log by hand. Seminars, AMI events, ARCA meetings and
  // training, Technical Reviews and ARCA News all arrive another way, and
  // offering them here would be offering a second route to the same points.
  TYPES = (types.data || []).filter(t => t.member_can_log !== false && t.points != null);
  YEARS = summaries.data || [];
  if (YEARS.length && !YEARS.some(y => y.year === showing)) showing = YEARS[0].year;

  await drawYear();
})();

async function drawYear(){
  const sum = YEARS.find(y => y.year === showing) || {
    year: showing, core_points: 0, non_core_points: 0, core_required: 5,
    non_core_required: 5, pending_count: 0, points_automatic: 0, points_awarded: 0,
    points_self: 0, requires_cpd: true,
  };
  const { data:log, error } = await sb.from('my_cpd').select('*')
    .eq('year', showing).order('occurred_on', { ascending: false });
  if (error) return failed(out, error, 'Your CPD log');

  const core = Number(sum.core_points || 0),     needCore = Number(sum.core_required || 5);
  const non  = Number(sum.non_core_points || 0), needNon  = Number(sum.non_core_required || 5);

  out.innerHTML = `
    <section class="pbanner" style="padding:10px 0 24px">
      <div class="eyebrow"><span class="tri"></span>${esc(String(showing))} record</div>
      <h1>My CPD</h1>
      <p>${sum.requires_cpd
           ? `${needCore} core points and ${needNon} non core points are needed each calendar
              year. Most of them arrive on their own. Anything you log yourself is looked at
              by the office before it counts.`
           : `Your grade does not carry a CPD requirement. Anything recorded here is on your
              record because you chose to record it, and it still counts as evidence.`}</p>
      ${YEARS.length > 1 ? `<div class="msub glass-soft" style="margin-top:18px" id="years">
        ${YEARS.map(y => `<a href="#" data-y="${y.year}"
          class="${y.year === showing ? 'on' : ''}">${y.year}</a>`).join('')}
      </div>` : ''}
    </section>

    <div class="rings glass">
      ${ring('core', core, needCore, '#E40613', 'Core points')}
      ${ring('non',  non,  needNon,  '#ff8f97', 'Non core points')}
      <div class="ring-side">
        ${line('Recorded automatically', pts(sum.points_automatic))}
        ${line('Awarded by AMI',         pts(sum.points_awarded))}
        ${line('Logged by you and accepted', pts(sum.points_self))}
        ${line('Waiting to be reviewed',
               (sum.pending_count || 0) + (sum.pending_count === 1 ? ' entry' : ' entries'))}
        ${line(showing === YEAR ? 'Year ends' : 'Year ended', '31 December ' + showing)}
        <div style="display:flex;gap:10px;flex-wrap:wrap;margin-top:18px">
          <button class="btn btn-red btn-s" type="button" id="logbtn">Log an activity</button>
          <button class="btn btn-g btn-s" type="button" id="dlbtn">Download my record</button>
        </div>
      </div>
    </div>

    <section style="padding:34px 0 0">
      <div class="head-left sec-head">
        <div class="eyebrow"><span class="tri"></span>Through the year</div>
        <h2>When your points arrived</h2>
      </div>
      <div class="glass">
        ${chart(log || [])}
        <div class="legend">
          <span><i style="background:#E40613"></i>Core</span>
          <span><i style="background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.3)"></i>Non core</span>
          <span>Only accepted points are shown. Anything still waiting appears once the
            office has reviewed it.</span>
        </div>
      </div>
    </section>

    <section style="padding:34px 0 0">
      <div class="head-left sec-head">
        <div class="eyebrow"><span class="tri"></span>Your log</div>
        <h2>Every point, and how it arrived</h2>
        <p style="max-width:70ch">The how recorded column is the one that matters. A point
           that arrived on its own carries its own evidence. A point you logged yourself
           carries whatever you attached to it.</p>
      </div>
      ${table(log || [])}
    </section>

    <section style="padding:34px 0 0"><div class="mgrid">
      <div>
      <div id="formslot"></div>
      <div id="formprompt" class="glass" style="padding:30px 28px">
        <h3 style="font-size:20px;font-weight:800;margin-bottom:8px">Done something AMI does
          not know about?</h3>
        <p style="font-size:15px;color:var(--muted);margin-bottom:18px">A toolbox talk, a
          course, an hour with a piece of guidance. Log it and the office looks at it. Most
          entries are accepted within five working days.</p>
        <button class="btn btn-red" type="button" id="logbtn2">Log an activity</button>
      </div>
        <div class="callout">
          <b>Core and non core are decided by the activity, not by you.</b> Choose what you
          did and the type follows, so nobody has to guess which column their afternoon
          belongs in.
        </div>
      </div>

      <div>
        <div class="aside glass">
          <h3>How points arrive</h3>
          <ul>
            <li>Answering the questions on a change alert</li>
            <li>The code beside a technical article in ARCA News</li>
            <li>Watching a webinar or an AGM recording through to the end</li>
            <li>A published site audit appeal decision</li>
            <li>Conforming answers from an unannounced site assessment</li>
            <li>Attending an AMI event, recorded by the office</li>
            <li>Anything you log yourself, once reviewed</li>
          </ul>
        </div>
        <div class="callout">
          <b>Nothing negative is recorded here.</b> A wrong answer, a failed attempt or an
          unfavourable finding does not appear on your record, on the register, or anywhere
          an employer or a client can see it. It becomes a private training need for your
          employer and nothing else.
        </div>
      </div>
    </div></section>`;

  const yb = document.getElementById('years');
  if (yb) yb.querySelectorAll('a').forEach(a => a.onclick = e => {
    e.preventDefault(); showing = Number(a.dataset.y); drawYear();
  });
  document.getElementById('logbtn').onclick  = drawForm;
  document.getElementById('logbtn2').onclick = drawForm;
  document.getElementById('dlbtn').onclick  = download;
  if (showing !== YEAR) document.getElementById('logbtn').disabled = false;
}

/* ---------- the pieces ---------- */
const pts = n => {
  const v = Number(n || 0);
  return v + (v === 1 ? ' point' : ' points');
};
const line = (k, v) => `<div class="line"><span>${esc(k)}</span><b>${esc(String(v))}</b></div>`;

// A ring that is over the requirement fills completely and turns green rather
// than drawing past itself. Somebody with 7 of 5 has met it, and that is the
// thing worth saying.
function ring(id, got, need, colour, label){
  const C = 389.6;
  const frac = need > 0 ? Math.min(1, got / need) : (got > 0 ? 1 : 0);
  const done = need > 0 && got >= need;
  const left = Math.max(0, need - got);
  return `<div class="ring">
    <div class="mid">
      <svg viewBox="0 0 150 150" aria-hidden="true">
        <circle class="track" cx="75" cy="75" r="62"></circle>
        <circle class="fill" cx="75" cy="75" r="62" stroke="${done ? '#4ade80' : colour}"
                stroke-dasharray="${C}" stroke-dashoffset="${(C * (1 - frac)).toFixed(1)}"></circle>
      </svg>
      <div class="val"><span class="n">${got}</span>
        <span class="of">of ${need}</span></div>
    </div>
    <h4>${esc(label)}</h4>
    <p>${done ? 'Requirement met' : left + (left === 1 ? ' point still to go' : ' points still to go')}</p>
  </div>`;
}

// Twelve months, accepted points only, core below and non core above. The tallest
// month sets the scale so a year with one point a month does not draw twelve
// invisible stubs.
function chart(log){
  const months = Array.from({ length: 12 }, () => ({ core: 0, non: 0 }));
  log.filter(r => r.status === 'accepted').forEach(r => {
    const m = new Date(r.occurred_on).getMonth();
    if (isNaN(m)) return;
    months[m][r.is_core ? 'core' : 'non'] += Number(r.points || 0);
  });
  const peak = Math.max(1, ...months.map(m => m.core + m.non));
  const H = 130;
  const names = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return `<div class="bars">${months.map((m, i) => {
    const total = m.core + m.non;
    return `<div class="col">
      ${total ? `<div class="stack" style="height:${(total / peak * H).toFixed(1)}px">
        ${m.non  ? `<div class="seg" style="flex:${m.non}"><span class="cnt">${total}</span></div>` : ''}
        ${m.core ? `<div class="seg core" style="flex:${m.core}">${
          m.non ? '' : `<span class="cnt">${total}</span>`}</div>` : ''}
      </div>` : ''}
      <div class="lbl">${names[i]}</div>
    </div>`;
  }).join('')}</div>`;
}

function table(log){
  if (!log.length) return `<div class="callout">Nothing is recorded for ${showing} yet.
    Points arrive on their own as you take part, and anything else you can log below.</div>`;

  return `<div class="glass tblwrap"><table class="ltable">
    <thead><tr>
      <th>Date</th><th>Activity</th><th>Type</th><th>Points</th>
      <th>How recorded</th><th>Evidence</th><th>Status</th>
    </tr></thead>
    <tbody>${log.map(r => `<tr>
      <td class="when">${esc(fmtDate(r.occurred_on))}</td>
      <td>${esc(r.title)}${r.provider ? '<br><span style="color:var(--muted);font-size:13px">'
          + esc(r.provider) + '</span>' : ''}
        ${r.status === 'rejected' && r.review_note
          ? '<br><span style="color:var(--muted);font-size:13px">' + esc(r.review_note) + '</span>' : ''}</td>
      <td><span class="badge-t">${r.is_core ? 'Core' : 'Non core'}</span></td>
      <td class="pts">${esc(String(Number(r.points)))}</td>
      <td>${how(r.how_recorded)}${r.ai_assisted
          ? '<br><span style="color:var(--muted);font-size:13px">reviewed with AI help</span>' : ''}</td>
      <td class="ev">${esc(r.evidence_ref || (r.evidence_count ? r.evidence_count
          + (r.evidence_count === 1 ? ' file' : ' files') : '—'))}</td>
      <td>${status(r)}</td>
    </tr>`).join('')}</tbody>
  </table></div>`;
}

const how = v => ({
  automatic:      '<span class="howp auto">Automatic</span>',
  awarded_by_ami: '<span class="howp ami">Awarded by AMI</span>',
  self_declared:  '<span class="howp">Logged by you</span>',
}[v] || '<span class="howp">' + esc(String(v || '')) + '</span>');

function status(r){
  if (r.status === 'accepted') return '<span class="badge-t ok">Accepted</span>';
  if (r.status === 'pending')  return '<span class="badge-t wait">Awaiting review</span>';
  return '<span class="badge-t">Not accepted</span>';
}

/* ---------- logging one ---------- */
function drawForm(){
  const slot = document.getElementById('formslot');
  document.getElementById('formprompt').style.display = 'none';
  slot.innerHTML = `
    <div class="formcard glass">
      <h3>Log an activity</h3>
      <div class="fsub">Anything you have done that AMI has not recorded for you. The office
        looks at it before it counts.</div>

      <div class="two">
        <div class="field">
          <label for="on">Date</label>
          <input type="date" id="on" max="${new Date().toISOString().slice(0,10)}"
                 value="${new Date().toISOString().slice(0,10)}">
        </div>
        <div class="field">
          <label>What it is worth</label>
          <div class="worth" id="worth">Choose what you did, and this says what it counts for.</div>
        </div>
      </div>

      <div class="field">
        <label for="type">What did you do</label>
        <select id="type">
          <option value="">Choose one</option>
          ${TYPES.map(t => `<option value="${t.id}" data-core="${t.is_core}">
            ${esc(t.name)}</option>`).join('')}
        </select>
        <div class="hint" id="corehint">What it is worth, and whether it is core or non core,
          follow from this rather than being yours to choose.</div>
      </div>

      <div class="field" id="reflbox" style="display:none">
        <label for="refl">Your reflection</label>
        <textarea id="refl" rows="10" maxlength="40000"
          placeholder="What did you learn, and how does it change the way you work?"></textarea>
        <div class="hint" id="wc"></div>
      </div>

      <div class="field">
        <label for="title">A short title</label>
        <input type="text" id="title" maxlength="200"
               placeholder="For example, face fit testing refresher">
      </div>

      <div class="field">
        <label for="provider">Who ran it</label>
        <input type="text" id="provider" maxlength="200" placeholder="Optional">
      </div>

      <div class="field">
        <label for="file" id="filelabel">Evidence</label>
        <div class="drop">
          <input type="file" id="file" accept="application/pdf,image/jpeg,image/png,image/webp">
          <div class="picked"><span id="filehint">A certificate, a register or a photograph of one.
            PDF, JPEG, PNG or WebP, up to 20MB. Optional, and it makes the office's job
            quicker.</span></div>
        </div>
      </div>

      <div class="field" id="certbox" style="display:none">
        <label for="certtype">The certificate is for</label>
        <select id="certtype"></select>
        <div class="note" id="certnote" style="margin-top:6px"></div>
      </div>

      <div id="fmsg"></div>
      <div style="display:flex;gap:10px;flex-wrap:wrap">
        <button class="btn btn-red" type="button" id="send">Send for review</button>
        <button class="btn btn-g" type="button" id="cancel">Cancel</button>
      </div>
    </div>`;

  slot.scrollIntoView({ behavior: 'smooth', block: 'start' });
  document.getElementById('type').onchange = () => { chosenType(); countWords(); };
  document.getElementById('file').addEventListener('change', certChoice);
  document.getElementById('refl').oninput = countWords;
  document.getElementById('cancel').onclick = () => {
    slot.innerHTML = '';
    document.getElementById('formprompt').style.display = 'block';
  };
  document.getElementById('send').onclick = submit;
}

/* The type decides the value, the category and whether a reflection is needed.
   Said on the form the moment it is chosen, so nobody finds out on submitting. */
function chosen(){
  const id = document.getElementById('type').value;
  return TYPES.find(t => t.id === id) || null;
}

function chosenType(){
  const t = chosen();
  const worth = document.getElementById('worth');
  const hint  = document.getElementById('corehint');
  document.getElementById('reflbox').style.display = t && t.min_words > 0 ? 'block' : 'none';
  certChoice();
  if (!t) {
    worth.textContent = 'Choose what you did, and this says what it counts for.';
    hint.textContent = 'What it is worth, and whether it is core or non core, follow from this '
      + 'rather than being yours to choose.';
    return;
  }
  const n = Number(t.points);
  worth.innerHTML = `<b>${esc(String(n))} ${n === 1 ? 'point' : 'points'}</b>, `
    + (t.is_core ? 'core' : 'non core');
  hint.textContent = (t.guidance || '')
    + (t.needs_evidence ? ' Evidence is needed for this one.' : '');
}

/* 0044. A reflection sent with its course certificate earns both: the
   reflection's points, and the course's as an external training course or a
   formal qualification. The member says which. The two are logged together
   and each is decided on its own merits. An ARCA course is not offered: its
   point arrives from ARCA's records, and logging it here would count it twice. */
const CERT_CODES = ['external_training', 'qualification'];
const isReflection = t => !!(t && t.min_words > 0);

function certChoice(){
  const t = chosen();
  const refl = isReflection(t);
  const file = document.getElementById('file').files[0];
  document.getElementById('filelabel').textContent = refl ? 'Course certificate' : 'Evidence';
  document.getElementById('filehint').textContent = refl
    ? 'Attach the certificate for the course and it counts as well as the reflection, '
      + 'as a second entry. PDF, JPEG, PNG or WebP, up to 20MB. Optional.'
    : 'A certificate, a register or a photograph of one. PDF, JPEG, PNG or WebP, up to 20MB. '
      + 'Optional, and it makes the office\'s job quicker.';
  const box = document.getElementById('certbox');
  const certs = TYPES.filter(x => CERT_CODES.includes(x.code));
  box.style.display = refl && file && certs.length ? 'block' : 'none';
  const sel = document.getElementById('certtype');
  if (!sel.options.length) {
    certs.forEach(x => {
      const o = document.createElement('option');
      const n = Number(x.points);
      o.value = x.id;
      o.textContent = `${x.name}, ${n} ${n === 1 ? 'point' : 'points'} ${x.is_core ? 'core' : 'non core'}`;
      sel.appendChild(o);
    });
  }
  document.getElementById('certnote').textContent =
    'If it was an ARCA course, leave the certificate off: ARCA\'s records give you that point automatically.';
}

/* Words counted as the database counts them in app.word_count: runs of letters
   or digits, an apostrophe inside a word not splitting it. If the two disagreed
   a member would be told 500 and then refused. */
function wordsIn(t){
  return (String(t || '').match(/[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)*/gu) || []).length;
}

function countWords(){
  const t = chosen();
  const send = document.getElementById('send');
  const wc = document.getElementById('wc');
  if (!t || !(t.min_words > 0)) { send.disabled = false; return; }
  const n = wordsIn(document.getElementById('refl').value);
  const need = t.min_words;
  wc.textContent = n >= need
    ? `${n} words. That is enough.`
    : `${n} of ${need} words. ${need - n} more before it can be sent.`;
  wc.style.color = n >= need ? '' : '#ff9ba2';
  send.disabled = n < need;
}

async function submit(){
  const btn = document.getElementById('send');
  const msg = document.getElementById('fmsg');
  const on    = document.getElementById('on').value;
  const type  = document.getElementById('type').value;
  const title = document.getElementById('title').value.trim();
  const file  = document.getElementById('file').files[0];

  if (!on)    return said(msg, 'err', 'Please say when you did it.');
  if (!type)  return said(msg, 'err', 'Please say what you did.');
  if (title.length < 3) return said(msg, 'err', 'Please give it a short title.');
  const t = chosen();
  const refl = document.getElementById('refl').value.trim();
  if (t && t.min_words > 0 && wordsIn(refl) < t.min_words)
    return said(msg, 'err', `The reflection needs at least ${t.min_words} words.`);
  if (t && t.needs_evidence && !file)
    return said(msg, 'err', 'Please attach evidence for this one: a certificate, a register '
      + 'or a confirmation.');
  if (file && file.size > 20 * 1024 * 1024)
    return said(msg, 'err', 'That file is larger than 20MB.');

  btn.disabled = true; btn.textContent = 'Sending';

  if (file && await usedBefore(file)) {
    btn.disabled = false; btn.textContent = 'Send for review';
    return said(msg, 'err', USED);
  }

  // A reflection with its certificate: both entries in one go, the file on
  // the course entry, which is the one it proves.
  const certType = isReflection(t) && file ? document.getElementById('certtype').value : '';
  if (certType) {
    const { data:pair, error:perr } = await sb.rpc('log_reflection_with_certificate', {
      p_occurred_on: on, p_reflection_type: type, p_certificate_type: certType,
      p_title: title, p_provider: document.getElementById('provider').value.trim() || null,
      p_reflection: refl,
    });
    if (perr) {
      btn.disabled = false; btn.textContent = 'Send for review';
      return said(msg, 'err', friendly(perr));
    }
    const stored = await attach(pair.certificate_id, file);
    btn.disabled = false; btn.textContent = 'Send for review';
    said(msg, stored === true ? 'ok' : 'err', stored === true
      ? 'Sent as two entries, the reflection and the course with its certificate. Both appear in '
        + 'your log as awaiting review, and each is decided on its own.'
      : 'Both entries are logged, but the certificate was not attached: ' + stored);
    setTimeout(async () => {
      const { data } = await sb.from('my_cpd_summary').select('*').order('year', { ascending: false });
      YEARS = data || YEARS;
      await drawYear();
    }, 1200);
    return;
  }

  // is_core is deliberately not sent. log_cpd takes it from the activity type, so
  // a member cannot log a non core afternoon as core, whatever this page posts.
  const { data:id, error } = await sb.rpc('log_cpd', {
    p_occurred_on:      on,
    p_activity_type_id: type,
    p_title:            title,
    p_provider:         document.getElementById('provider').value.trim() || null,
    p_reflection:       t && t.min_words > 0 ? refl : null,
  });

  if (error) {
    btn.disabled = false; btn.textContent = 'Send for review';
    return said(msg, 'err', friendly(error));
  }

  if (file) {
    const stored = await attach(id, file);
    if (stored !== true) {
      btn.disabled = false; btn.textContent = 'Send for review';
      return said(msg, 'err', 'Your entry is logged, but the file was not attached: ' + stored);
    }
  }

  said(msg, 'ok', 'Sent. It appears in your log as awaiting review, and the office normally '
    + 'looks at these within five working days.');
  setTimeout(async () => {
    const { data } = await sb.from('my_cpd_summary').select('*')
      .order('year', { ascending: false });
    YEARS = data || YEARS;
    await drawYear();
  }, 1200);
}

/* Evidence goes through the site's Worker (0045), which checks the file is
   really a PDF or a picture, takes its fingerprint, and refuses a certificate
   that has already been used for CPD, by anybody. Members can no longer write
   to the evidence bucket themselves. Returns true, or a sentence saying why not. */
async function attach(entryId, file){
  try {
    const { data } = await sb.auth.getSession();
    const token = data && data.session && data.session.access_token;
    if (!token) return 'You were signed out, so the file was not attached.';
    const fd = new FormData();
    fd.append('entry', entryId);
    fd.append('file', file);
    const res = await fetch('/api/cpd/evidence', { method: 'POST',
      headers: { Authorization: 'Bearer ' + token }, body: fd });
    if (res.ok) return true;
    const text = await res.text();
    let out = null; try { out = JSON.parse(text); } catch {}
    return (out && out.error) || 'The file could not be attached.';
  } catch (e) { console.error('cpd evidence threw', e); return 'The file could not be attached.'; }
}

/* The same check, asked before anything is logged, so a member who picks a
   certificate already used is told at once rather than after two entries
   exist. A courtesy only: the Worker's check on the stored bytes is the rule. */
async function usedBefore(file){
  try {
    const d = new Uint8Array(await crypto.subtle.digest('SHA-256', await file.arrayBuffer()));
    const hex = [...d].map(x => x.toString(16).padStart(2, '0')).join('');
    const { data } = await sb.rpc('cpd_evidence_seen', { p_sha256: hex });
    return data === true;
  } catch { return false; }
}

const USED = 'That certificate has already been used for CPD, on your record or somebody '
  + 'else\'s. A certificate counts once, so it cannot be sent again.';

// The database raises with a message written for a person. Anything else gets one
// written here, because a member should never read a Postgres error.
function friendly(error){
  const m = String(error.message || '');
  if (/CPD entry cannot be dated in the future|more than three years ago|say what the activity was|not an activity type|recorded for you automatically|valued item by item|reflection needs at least|once a year/i.test(m))
    return m.replace(/^.*?:\s*/, '');
  return 'That could not be sent just now. Please try again in a moment.';
}

/* ---------- the record as a file ---------- */
/* The printable personal CPD record is a separate piece of work with its own
   layout. This is the honest interim: the same rows, as a spreadsheet anybody can
   open, with the how recorded column intact so it is evidence rather than a list. */
function download(){
  sb.from('my_cpd').select('*').order('occurred_on', { ascending: false })
    .then(({ data, error }) => {
      if (error || !data) return;
      const head = ['Date','Activity','Provider','Type','Points','How recorded','Reviewed with AI help','Status','Year'];
      const rows = data.map(r => [
        r.occurred_on, r.title, r.provider || '', r.is_core ? 'Core' : 'Non core',
        r.points, r.how_recorded.replace(/_/g, ' '), r.ai_assisted ? 'Yes' : '', r.status, r.year,
      ]);
      const csv = [head, ...rows]
        .map(cols => cols.map(c => `"${String(c ?? '').replace(/"/g, '""')}"`).join(','))
        .join('\r\n');
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }));
      a.download = `AMI-CPD-${fullName(P).replace(/\s+/g, '-')}-${showing}.csv`;
      a.click();
      URL.revokeObjectURL(a.href);
    });
}
