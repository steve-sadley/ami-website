/* =============================================================================
   A discussion

   The one page on the site that shows other members' words, so it is the one
   place where the escaping matters most. A post is stored as PLAIN TEXT, and
   postBody() in site.js escapes it and splits it into paragraphs. It is never
   passed through safeHtml, which exists for the office's rich text editor and
   would be far too generous here.

   Three states a member can be in on their own post, and all three are shown
   plainly rather than by hiding a button:

     published and unanswered   they may edit or delete it
     published and answered     they may not, and it says why
     held                       only they can see it, and it says what happens next
   ============================================================================= */

const out = document.getElementById('out');
let P = null, T = null, POSTS = [];

(async () => {
  await memberChrome('/forum');
  // Two ways in, and both have to work. /t/<slug> is what a member sees and what
  // gets pasted into an email; the Worker rewrites it onto this file server side,
  // so the browser's address still says /t/<slug> and there is no query string to
  // read. ?t=<slug> is what a link built in JavaScript uses. member.html does
  // exactly this for /m/<slug>, and it is the reason that page works.
  const slug = qs('t')
    || decodeURIComponent(location.pathname.replace(/^\/t\//, '').replace(/\/$/, ''));
  if (!slug) { location.replace('/forum'); return; }

  const [profile, thread] = await Promise.all([
    sb.from('my_profile').select('*').maybeSingle(),
    sb.from('forum_thread_list').select('*').eq('slug', slug).maybeSingle(),
  ]);
  if (profile.error) return failed(out, profile.error, 'This discussion');
  P = profile.data;

  if (!P || !P.is_active) {
    out.innerHTML = `<div class="callout" style="max-width:70ch">
      <b>The forum is open to members with an active membership.</b> Yours is not currently
      active. The office can tell you why.</div>`;
    return;
  }

  T = thread.data;
  if (!T) {
    out.innerHTML = `<section class="pbanner"><h1>That discussion is not here</h1>
      <p>It may have been removed, or the link may be wrong. Nothing is lost: the
         <a href="/forum" style="color:var(--link);font-weight:700">forum</a> has everything
         that is still open.</p></section>`;
    return;
  }

  await load();
})();

async function load(){
  const { data, error } = await sb.from('forum_post_list').select('*')
    .eq('thread_id', T.id).order('seq');
  if (error) return failed(out, error, 'This discussion');
  POSTS = data || [];
  draw();
}

function draw(){
  const replies = Math.max(0, POSTS.filter(p => p.status === 'published').length - 1);
  const people = [...new Map(POSTS.filter(p => p.status === 'published')
    .map(p => [fullName(p), p])).values()];

  out.innerHTML = `
    <section class="pbanner" style="padding:10px 0 20px">
      <div class="crumb"><a href="/forum">Members forum</a> &nbsp;&rsaquo;&nbsp;
        <a href="/forum?c=${encodeURIComponent(T.category_slug)}">${esc(T.category)}</a>
        &nbsp;&rsaquo;&nbsp; <b>${esc(T.title.slice(0, 40))}${T.title.length > 40 ? '…' : ''}</b></div>
      <h1 style="font-size:clamp(26px,3.4vw,38px)">${esc(T.title)}</h1>
      <p style="font-size:15px">${replies} ${replies === 1 ? 'reply' : 'replies'}
        ${T.last_post_at ? '&middot; last one ' + esc(fmtWhen(T.last_post_at)) : ''}
        ${T.locked ? '&middot; closed to new replies' : ''}</p>
    </section>

    <div class="mgrid">
      <div>
        <div id="posts">${POSTS.map((p, i) => postCard(p, i === 0)).join('')}</div>
        <div id="replyslot">${T.locked ? lockedNote() : replyForm()}</div>
      </div>

      <div>
        <div class="aside glass">
          <h3>In this discussion</h3>
          <ul>${people.map(p =>
            `<li>${esc(fullName(p))}${p.post_nominals ? ' ' + esc(p.post_nominals) : ''}${
              p.id === POSTS[0].id ? ', who started it' : ''}</li>`).join('')}</ul>
        </div>
        <div class="callout">
          <b>Every name here is a real member.</b> The grade beside it is the AMI record
          rather than anything the person has typed about themselves.
        </div>
        <div class="callout">
          <b>Something wrong with a post?</b> There is no moderation before publishing, so
          there has to be a way to raise one. It goes to the office rather than to a public
          flag, because a public flag is an argument.
        </div>
      </div>
    </div>`;

  wire();
}

function postCard(p, first){
  const held = p.status === 'held';
  const cls  = held ? 'post glass-soft held' : (first ? 'post glass first' : 'post glass-soft');

  if (held) return `
    <div class="${cls}" data-id="${p.id}">
      <div class="ph-head">
        <div class="pav" style="background:rgba(255,201,120,.16);color:#ffc978">&#9888;</div>
        <div class="pw">
          <b>${p.mine ? 'Your post is being looked at' : 'A post is being looked at'}</b>
          <span>Posted ${esc(fmtWhen(p.created_at))}</span>
        </div>
        <div class="pt">Held</div>
      </div>
      <div class="pbody"><p style="color:var(--muted)">Something in it matched the word list,
        which holds a post rather than publishing it. Nobody else can see it yet. The office
        normally clears these the same working day and you will hear either way.</p></div>
      <div class="pbody" style="margin-top:14px;opacity:.75">${postBody(p.body)}</div>
      ${p.mine ? `<div class="pfoot">
        <button data-act="edit" data-id="${p.id}">Edit it</button>
        <span>&middot;</span>
        <button data-act="delete" data-id="${p.id}">Delete it</button>
      </div>` : ''}
    </div>`;

  return `
    <div class="${cls}" data-id="${p.id}">
      <div class="ph-head">
        ${p.author_slug
          ? `<a href="/m/${encodeURIComponent(p.author_slug)}">${avatar(null, p, 'pav')}</a>`
          : avatar(null, p, 'pav')}
        <div class="pw">
          ${p.author_slug ? `<a href="/m/${encodeURIComponent(p.author_slug)}">` : ''}
            <b>${esc(fullName(p))}</b>
          ${p.author_slug ? '</a>' : ''}
          <span>${esc([p.grade, p.post_nominals, p.employer].filter(Boolean).join(' · '))}</span>
        </div>
        <div class="pt">${esc(fmtWhen(p.created_at))}${
          p.edited_at ? ' &middot; edited' : ''}</div>
      </div>
      <div class="pbody">${postBody(p.body)}</div>
      <div class="pfoot">
        ${T.locked ? '' : '<button data-act="quote" data-id="' + p.id + '">Quote</button>'}
        ${p.mine && p.can_edit ? `<span>&middot;</span>
          <button data-act="edit" data-id="${p.id}">Edit</button>
          <span>&middot;</span>
          <button data-act="delete" data-id="${p.id}">Delete</button>` : ''}
        ${!p.mine ? `<span>&middot;</span>
          <button data-act="report" data-id="${p.id}">Report</button>` : ''}
        ${p.endorsed ? '<span class="badge-t ok" style="margin-left:8px">Endorsed by AMI</span>' : ''}
        ${p.mine && !p.can_edit
          ? '<span class="locked">Editing closed. This post has replies.</span>' : ''}
      </div>
    </div>`;
}

const replyForm = () => `
  <div class="formcard glass" style="max-width:none">
    <h3>Add a reply</h3>
    <div class="fsub">Posting as ${esc(fullName(P))}${P.grade ? ', ' + esc(P.grade) : ''}${
      P.post_nominals ? ', ' + esc(P.post_nominals) : ''}. Your name and grade are shown on
      every post.</div>
    <div class="field">
      <textarea id="rbody" rows="6" maxlength="20000" placeholder="Write your reply"></textarea>
      <div class="hint">Plain words. Addresses beginning http become links on their own.</div>
    </div>
    <div id="rmsg"></div>
    <button class="btn btn-red" type="button" id="rpost">Post reply</button>
  </div>`;

const lockedNote = () => `
  <div class="callout"><b>This discussion is closed to new replies.</b> It stays here to be
  read. If there is more to say, start a new one and link to this from it.</div>`;

/* ---------- the buttons ---------- */
function wire(){
  document.querySelectorAll('.pfoot button').forEach(b => b.onclick = () => {
    const p = POSTS.find(x => x.id === b.dataset.id);
    ({ quote, edit, delete: remove, report })[b.dataset.act](p);
  });
  const rp = document.getElementById('rpost');
  if (rp) rp.onclick = reply;
}

function quote(p){
  const box = document.getElementById('rbody');
  if (!box) return;
  const q = p.body.split('\n').map(l => '> ' + l).join('\n');
  box.value = (box.value ? box.value.trimEnd() + '\n\n' : '')
    + fullName(p) + ' wrote:\n' + q + '\n\n';
  box.focus();
  box.scrollIntoView({ behavior: 'smooth', block: 'center' });
}

async function reply(){
  const btn = document.getElementById('rpost');
  const msg = document.getElementById('rmsg');
  const body = document.getElementById('rbody').value.trim();
  if (!body) return said(msg, 'err', 'Please write something first.');

  btn.disabled = true; btn.textContent = 'Posting';
  const { data, error } = await sb.rpc('reply_to_thread',
    { p_thread_id: T.id, p_body: body });
  btn.disabled = false; btn.textContent = 'Post reply';
  if (error) return said(msg, 'err', 'That could not be posted just now. Please try again.');

  const r = Array.isArray(data) ? data[0] : data;
  document.getElementById('rbody').value = '';
  await load();
  if (r && r.held) {
    const box = document.getElementById('rmsg');
    if (box) said(box, 'ok', 'Posted, and it is being looked at before it appears. Nobody '
      + 'else can see it yet.');
  }
}

/* An edit replaces the body in place. The previous version is kept whatever
   happens, by a trigger, so a post cannot be quietly rewritten even inside the
   window where editing is allowed. */
function edit(p){
  const card = document.querySelector(`.post[data-id="${p.id}"] .pbody:last-of-type`);
  if (!card) return;
  card.innerHTML = `
    <div class="field" style="margin-bottom:12px">
      <textarea id="ebody" rows="6" maxlength="20000">${esc(p.body)}</textarea>
    </div>
    <div id="emsg"></div>
    <div style="display:flex;gap:10px;flex-wrap:wrap">
      <button class="btn btn-red btn-s" type="button" id="esave">Save the change</button>
      <button class="btn btn-g btn-s" type="button" id="ecancel">Cancel</button>
    </div>`;

  document.getElementById('ecancel').onclick = draw;
  document.getElementById('esave').onclick = async () => {
    const body = document.getElementById('ebody').value.trim();
    const msg  = document.getElementById('emsg');
    if (!body) return said(msg, 'err', 'A post cannot be empty. Delete it instead.');

    const { error } = await sb.from('forum_posts').update({ body }).eq('id', p.id);
    if (error) return said(msg, 'err', 'That could not be saved. If somebody has replied '
      + 'since you opened this, the post can no longer be edited.');

    await load();
    // Row level security does not raise when it excludes a row: the update
    // succeeds and changes nothing. So the check is on what came back, not on
    // whether there was an error.
    const now = POSTS.find(x => x.id === p.id);
    if (now && now.body === p.body) {
      const box = document.querySelector(`.post[data-id="${p.id}"] .pfoot`);
      if (box) box.insertAdjacentHTML('beforeend',
        '<span class="locked">That could not be changed. Somebody has replied since.</span>');
    }
  };
}

async function remove(p){
  if (!confirmish(`Delete this post? The words go. If it is the only post in the discussion,
    the discussion goes with it.`)) return;
  const { error } = await sb.from('forum_posts').delete().eq('id', p.id);
  if (error) return;
  await load();
  const still = POSTS.find(x => x.id === p.id);
  if (still) {
    const box = document.querySelector(`.post[data-id="${p.id}"] .pfoot`);
    if (box) box.insertAdjacentHTML('beforeend',
      '<span class="locked">That could not be deleted. Somebody has replied since.</span>');
  }
  if (!POSTS.length) location.href = '/forum';
}

function report(p){
  const card = document.querySelector(`.post[data-id="${p.id}"] .pfoot`);
  if (!card || card.querySelector('.reportbox')) return;
  card.insertAdjacentHTML('afterend', `
    <div class="reportbox" style="padding:0 26px 22px">
      <div class="field">
        <label for="rr">What is wrong with it</label>
        <input type="text" id="rr" maxlength="300"
               placeholder="A sentence is enough. It goes to the office, not to the forum.">
      </div>
      <div id="repmsg"></div>
      <button class="btn btn-g btn-s" type="button" id="rsend">Send it to the office</button>
    </div>`);
  document.getElementById('rsend').onclick = async () => {
    const reason = document.getElementById('rr').value.trim();
    const msg = document.getElementById('repmsg');
    if (reason.length < 3) return said(msg, 'err', 'Please say what is wrong with it.');
    const { error } = await sb.from('forum_reports')
      .insert({ post_id: p.id, reported_by: P.member_id, reason });
    said(msg, error ? 'err' : 'ok', error
      ? 'That could not be sent just now, or you have already reported this post.'
      : 'Sent. Somebody at the office will look at it. Thank you.');
  };
}

/* A browser confirm() blocks everything and looks like a browser rather than like
   the site, but it is honest, it is accessible, and inventing a modal for one
   question is inventing a modal. */
const confirmish = q => window.confirm(q.replace(/\s+/g, ' ').trim());
