/* =============================================================================
   /learn  Earn CPD on the site (0041)

   Something to read or a recording to watch, then questions. The database
   marks them: this page never holds the right answers, because my_learning
   does not send them. 80% passes, one retake, and a pass puts the points on
   the member's record at once, with an email.

   Two rules this page keeps, both learned elsewhere on this site:

   EVERYTHING FROM THE DATABASE IS TEXT unless it is the reading itself, which
   goes through bodyHtml and so through the same sanitiser as a news article.
   A question and its answers go in with textContent.

   THE VIDEO GATE IS A NUDGE, NOT A LOCK. The questions open once most of the
   recording has played, counted second by second so jumping to the end does
   not count. A determined person can get round anything in a browser; the
   questions are the evidence, and they are marked where nobody can see them.
   ============================================================================= */
const out = document.getElementById('out');
let ITEMS = [], ITEM = null;

(async () => {
  await memberChrome('/learn');
  const { data, error } = await sb.from('my_learning').select('*').order('published_at', { ascending: false });
  if (error) return failed(out, error, 'The CPD you can earn here');
  ITEMS = data || [];
  const slug = new URLSearchParams(location.search).get('i');
  if (slug) {
    ITEM = ITEMS.find(x => x.slug === slug);
    if (!ITEM) {
      out.innerHTML = `<div class="state"><p>That item is not available. It may have been taken
        down, or the address may be wrong.</p><p><a class="btn btn-g btn-s" href="/learn">All of them</a></p></div>`;
      return revealSoon();
    }
    return drawItem();
  }
  drawList();
})();

const pts = n => { const v = Number(n); return String(v) + (v === 1 ? ' point' : ' points'); };
const done = it => it.passed || it.already_counted;
const left = it => Math.max(Number(it.max_attempts) - Number(it.attempts_used), 0);

/* ---------- the list ---------- */
function card(it){
  const state = done(it) ? '<span class="badge-t">Done</span>'
    : left(it) === 0 ? '<span class="badge-t">No attempts left</span>'
    : it.attempts_used > 0 ? '<span class="badge-t wait">One more try</span>' : '';
  return `<a class="scard glass-soft learn-card" href="/learn?i=${encodeURIComponent(it.slug)}">
    <div class="eyebrow" style="margin-bottom:6px">${it.kind === 'watch' ? 'Watch and answer' : 'Read and answer'}
      · ${esc(it.activity_type)}</div>
    <h4>${esc(it.title)}</h4>
    ${it.summary ? `<p>${esc(it.summary)}</p>` : ''}
    <p style="margin-top:10px"><b>${esc(pts(it.points))}</b>, ${it.is_core ? 'core' : 'non core'} ${state}</p>
  </a>`;
}

function drawList(){
  const todo = ITEMS.filter(it => !done(it) && left(it) > 0);
  const rest = ITEMS.filter(it => !todo.includes(it));
  out.innerHTML = `
    <section class="reveal">
      <div class="sec-head"><div class="head-left">
        <div class="eyebrow"><span class="tri"></span>Earn CPD</div>
        <h2>Read it, watch it, answer the questions</h2>
        <p>Technical Reviews, ARCA News updates and the recordings of seminars and regional
          meetings. Score ${ITEMS[0] ? esc(String(ITEMS[0].pass_mark)) : 80}% or more and the points go
          straight onto your record. If you do not, you have one more try.</p>
      </div></div>
      ${todo.length ? `<div class="support-grid">${todo.map(card).join('')}</div>`
        : `<div class="glass" style="padding:22px"><p>There is nothing new to do just now. New items
            appear here as AMI publishes them.</p></div>`}
    </section>
    ${rest.length ? `<section class="reveal"><div class="sec-head"><div class="head-left">
        <h2 style="font-size:22px">Done</h2></div></div>
        <div class="support-grid">${rest.map(card).join('')}</div></section>` : ''}`;
  revealSoon();
}

/* ---------- one item ---------- */
function drawItem(){
  const it = ITEM;
  out.innerHTML = `
    <section class="reveal"><div class="glass learn-item" style="padding:clamp(20px,3vw,36px)">
      <div class="eyebrow"><span class="tri"></span>${it.kind === 'watch' ? 'Watch and answer' : 'Read and answer'}
        · ${esc(it.activity_type)} · ${esc(pts(it.points))}, ${it.is_core ? 'core' : 'non core'}</div>
      <h2 id="ltitle"></h2>
      <div id="material" style="margin-top:16px"></div>
      <div id="quiz" style="margin-top:28px"></div>
      <p style="margin-top:22px"><a class="btn btn-g btn-s" href="/learn">All of them</a></p>
    </div></section>`;
  document.getElementById('ltitle').textContent = it.title;

  const material = document.getElementById('material');
  if (it.body) material.innerHTML = '<div class="article">' + bodyHtml(it.body) + '</div>';
  if (it.kind === 'watch' && it.vimeo_id) {
    const frame = document.createElement('div');
    frame.className = 'vframe';
    frame.style.cssText = 'position:relative;padding-top:56.25%;margin-top:16px;border-radius:14px;overflow:hidden';
    frame.innerHTML = `<iframe id="vid" title="" allow="fullscreen; picture-in-picture"
      style="position:absolute;inset:0;width:100%;height:100%;border:0"
      src="https://player.vimeo.com/video/${encodeURIComponent(it.vimeo_id)}?dnt=1&amp;api=1"></iframe>`;
    frame.querySelector('iframe').title = it.title;
    material.appendChild(frame);
  }
  drawQuizArea();
  revealSoon();
}

function drawQuizArea(){
  const it = ITEM, box = document.getElementById('quiz');
  if (it.passed) { box.innerHTML = note('ok', 'You have passed this one and the points are on your record.'); return; }
  if (it.already_counted) {
    box.innerHTML = note('ok', 'This already counts on your record, because you attended it. '
      + 'You are welcome to watch it again; there are no further points for it.');
    return;
  }
  if (left(it) === 0) {
    box.innerHTML = note('err', 'You have used both attempts at this one, so it cannot earn points now.');
    return;
  }
  if (it.kind === 'watch' && Number(it.min_watch_percent) > 0) {
    box.innerHTML = `<div class="note" id="gate">The questions open once you have watched
      ${esc(String(it.min_watch_percent))}% of the recording. <b id="seen">0%</b> so far.</div>`;
    watchGate(Number(it.min_watch_percent), () => drawQuestions());
    return;
  }
  drawQuestions();
}

function note(kind, text){ return `<div class="note ${kind}">${esc(text)}</div>`; }

/* The Vimeo player speaks postMessage. No Vimeo script is loaded, so nothing
   changes in the content security policy, which allows the player's frame and
   nothing else from Vimeo. Seconds are counted once each, so seeking to the end
   is not watching to the end. */
function watchGate(need, open){
  const frame = document.getElementById('vid');
  if (!frame) return open();
  const seen = new Set();
  let duration = 0, opened = false;
  const send = msg => frame.contentWindow && frame.contentWindow.postMessage(JSON.stringify(msg), 'https://player.vimeo.com');
  window.addEventListener('message', e => {
    if (e.origin !== 'https://player.vimeo.com' || opened) return;
    let d; try { d = typeof e.data === 'string' ? JSON.parse(e.data) : e.data; } catch { return; }
    if (!d) return;
    if (d.event === 'ready') send({ method: 'addEventListener', value: 'timeupdate' });
    if (d.event === 'timeupdate' && d.data) {
      duration = Number(d.data.duration) || duration;
      seen.add(Math.floor(Number(d.data.seconds) || 0));
      const pct = duration ? Math.min(100, Math.round(100 * seen.size / Math.ceil(duration))) : 0;
      const el = document.getElementById('seen');
      if (el) el.textContent = pct + '%';
      if (pct >= need) { opened = true; open(); }
    }
  });
  frame.addEventListener('load', () => send({ method: 'addEventListener', value: 'timeupdate' }));
}

/* A NEW ORDER EVERY TIME THE QUESTIONS OPEN (Steve, 30 October). The
   questions are shuffled, and so are the answers within each one, so "number
   three is B" is no use to the next person, or to the same person on their
   retake. ORDER holds where each shown question and answer came from, and the
   answers are turned back into the stored order before they are sent, so the
   database marks them exactly as before and knows nothing about the shuffle.

   crypto.getRandomValues rather than Math.random, and a proper Fisher Yates
   rather than sort(() => Math.random() - 0.5), which is biased and leaves
   some orders far likelier than others. */
let ORDER = [];

function shuffled(n){
  const a = Array.from({ length: n }, (_, i) => i);
  const r = new Uint32Array(Math.max(n, 1));
  crypto.getRandomValues(r);
  for (let i = n - 1; i > 0; i--) {
    const j = r[i] % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function drawQuestions(){
  const it = ITEM, box = document.getElementById('quiz');
  const qs = Array.isArray(it.questions) ? it.questions : [];
  ORDER = shuffled(qs.length).map(qi => ({
    qi, opts: shuffled(Array.isArray(qs[qi].options) ? qs[qi].options.length : 0) }));
  box.innerHTML = `<h3 style="margin-bottom:6px">The questions</h3>
    <p style="color:var(--muted);margin-bottom:14px">${esc(String(it.pass_mark))}% to pass.
      ${it.attempts_used > 0 ? 'This is your last try.' : 'If you do not pass, you can try once more.'}</p>
    <form id="qform"></form>
    <div id="qmsg" style="margin-top:12px"></div>
    <button class="btn btn-red" type="button" id="qsend" style="margin-top:12px">Send my answers</button>`;
  const form = document.getElementById('qform');
  ORDER.forEach(({ qi, opts }, i) => {
    const q = qs[qi];
    const fs = document.createElement('fieldset');
    fs.className = 'glass-soft learn-q';
    fs.style.cssText = 'padding:14px 18px;margin:0 0 12px;border:0;border-radius:12px';
    const lg = document.createElement('legend');
    lg.style.cssText = 'font-weight:700;padding:0;margin-bottom:8px';
    lg.textContent = (i + 1) + '. ' + String(q.q || '');
    fs.appendChild(lg);
    opts.forEach(j => {
      const o = q.options[j];
      const lab = document.createElement('label');
      lab.style.cssText = 'display:flex;gap:10px;align-items:flex-start;margin:6px 0;cursor:pointer';
      const r = document.createElement('input');
      r.type = 'radio'; r.name = 'q' + i; r.value = String(j);
      const sp = document.createElement('span');
      sp.textContent = String(o);
      lab.append(r, sp);
      fs.appendChild(lab);
    });
    form.appendChild(fs);
  });
  document.getElementById('qsend').onclick = send;
}

async function send(){
  const it = ITEM, msg = document.getElementById('qmsg'), btn = document.getElementById('qsend');
  const qs = Array.isArray(it.questions) ? it.questions : [];
  // Read in the order SHOWN, so "question 2" in a message is the second one on
  // the screen; then put each choice back in the slot of the question it
  // belongs to. The radio's value is already the answer's stored index.
  const shown = ORDER.map((_, i) => {
    const c = document.querySelector(`input[name="q${i}"]:checked`);
    return c ? Number(c.value) : null;
  });
  const missing = shown.findIndex(a => a === null);
  if (missing >= 0) return said(msg, 'err', `Please answer question ${missing + 1}.`);
  const answers = new Array(qs.length);
  ORDER.forEach(({ qi }, i) => { answers[qi] = shown[i]; });

  btn.disabled = true; btn.textContent = 'Marking';
  const { data, error } = await sb.rpc('submit_learning', { p_item: it.id, p_answers: answers });
  btn.disabled = false; btn.textContent = 'Send my answers';
  if (error) {
    const m = String(error.message || '');
    return said(msg, 'err', /already passed|used both attempts|answer every question|not available|current members/i.test(m)
      ? m.replace(/^.*?:\s*/, '') : 'That could not be marked just now. Please try again in a moment.');
  }
  const r = data || {};
  it.attempts_used = Number(it.attempts_used) + 1;
  if (r.passed) {
    it.passed = true;
    document.getElementById('quiz').innerHTML = note('ok', r.already_counted
      ? `You scored ${r.score}%, which is a pass. This already counted on your record, so there are no further points for it.`
      : `You scored ${r.score}%, ${r.correct} of ${r.total}. That is a pass: ${pts(r.points)} ${it.is_core ? 'core' : 'non core'} `
        + `${Number(r.points) === 1 ? 'has' : 'have'} gone onto your record, and an email is on its way.`);
    return;
  }
  if (Number(r.attempts_left) > 0) {
    drawQuestions();
    said(document.getElementById('qmsg'), 'err', `You scored ${r.score}%, ${r.correct} of ${r.total}. `
      + `The pass mark is ${r.pass_mark}%. Have another look and try once more.`);
    return;
  }
  document.getElementById('quiz').innerHTML = note('err', `You scored ${r.score}%, ${r.correct} of ${r.total}. `
    + `The pass mark is ${r.pass_mark}% and that was your last try, so this one cannot earn points now.`);
}
